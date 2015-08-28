﻿module kafkad.consumer;

import kafkad.client;
import kafkad.connection;
import kafkad.exception;
import kafkad.protocol.fetch;
import vibe.core.sync;
import std.container.dlist;
import std.container.rbtree;
import std.algorithm;
import std.exception;
import core.memory;

struct Message {
    long offset;
    ubyte[] key;
    ubyte[] value;
}

struct QueueBuffer {
    ubyte* buffer, p;
    size_t messageSetSize;

    this(size_t size) {
        buffer = cast(ubyte*)enforce(GC.malloc(size, GC.BlkAttr.NO_SCAN));
    }
}

// queues must be always sorted by the topic
//alias QueueList = RedBlackTree!(Queue, "a.topic < b.topic");

alias QueuePartitions = RedBlackTree!(Queue, "a.partition < b.partition");
alias QueueTopics = RedBlackTree!(QueueTopic, "a.topic < b.topic");

class QueueTopic {
    string topic;
    size_t readyPartitions;
    QueuePartitions queues;

    auto findQueue(int partition) {
        auto r = queues[].find!((a, b) => a.partition == b)(partition);
        assert(!r.empty);
        return r.front;
    }
}

class QueueGroup {
    private {
        QueueTopics m_queueTopics;
        TaskMutex m_mutex;
        TaskCondition m_freeCondition; // notified when there are queues with free buffers
        size_t m_freeQueues;
    }

    this() {
        m_queueTopics = new QueueTopics();
        m_mutex = new TaskMutex();
        m_freeCondition = new TaskCondition(m_mutex);
    }

    @property auto queueTopics() { return m_queueTopics; }
    @property auto mutex() { return m_mutex; }
    @property auto freeCondition() { return m_freeCondition; }

    auto findTopic(string topic) {
        auto r = m_queueTopics[].find!((a, b) => a.topic == b)(topic);
        assert(!r.empty);
        return r.front;
    }

    void notifyQueuesHaveFreeBuffers() {
        m_freeCondition.notify;
    }
}

class Queue {
    private {
        DList!(QueueBuffer*) m_freeBuffers, m_filledBuffers;
        QueueBuffer* m_lastBuffer;
        TaskMutex m_mutex;
        TaskCondition m_filledCondition;
        QueueGroup m_group;
        bool m_fetchPending;
    }

    int partition;

    // this is updated also in the fetch task
    bool fetchPending() { return m_fetchPending; }
    bool fetchPending(bool v) { return m_fetchPending = v; }

    this(in Configuration config, QueueGroup group) {
        import std.algorithm : max;
        auto nbufs = max(2, config.consumerQueueBuffers); // at least 2
        foreach (n; 0 .. nbufs) {
            auto qbuf = new QueueBuffer(config.consumerMaxBytes);
            m_freeBuffers.insertBack(qbuf);
        }
        m_lastBuffer = null;
        m_mutex = new TaskMutex();
        m_filledCondition = new TaskCondition(m_mutex);
        m_group = group;
        m_fetchPending = false;
    }

    @property auto mutex() { return m_mutex; }
    @property auto filledCondition() { return m_filledCondition; }

    bool hasFreeBuffer() {
        return !m_fetchPending && !m_freeBuffers.empty;
    }

    auto getBufferToFill() {
        auto qbuf = m_freeBuffers.front();
        m_freeBuffers.removeFront();
        return qbuf;
    }

    void returnFilledBuffer(QueueBuffer* buf) {
        synchronized (m_mutex) {
            m_filledBuffers.insertBack(buf);
            m_filledCondition.notify();
        }
    }

    QueueBuffer* waitForFilledBuffer() {
        synchronized (m_mutex) {
            if (m_lastBuffer) {
                // return the last used buffer to the free buffer list
                m_freeBuffers.insertBack(m_lastBuffer);
                // notify the fetch task that there are buffer to be filled in
                // the fetch task will then make a batch request for all queues with free buffers
                // do not notify the task if there is a pending request for this queue (e.g. without a response yet)
                if (!m_fetchPending)
                    m_group.notifyQueuesHaveFreeBuffers();
            }

            while (m_filledBuffers.empty)
                m_filledCondition.wait();
            m_lastBuffer = m_filledBuffers.front;
            m_filledBuffers.removeFront();
            return m_lastBuffer;
        }
    }

    /*
    void returnProcessedBuffer(QueueBuffer* buf) {
        synchronized (m_mutex) {
            m_freeBuffers.insertBack(buf);
        }
    }*/
}

class Consumer {
    package {
        Client m_client;
        string m_topic;
        int m_partition;
        int m_offset;
        ubyte[] m_msgBuffer;
        size_t m_filled;
        TaskCondition m_cond;
        Queue m_queue;
        QueueBuffer* m_currentBuffer;
    }

    package {
        // cached connection to the leader holding selected topic-partition, this is updated on metadata refresh
        BrokerConnection m_conn;
    }

    this(Client client, string topic, int partition, int offset) {
        m_client = client;
        m_topic = topic;
        m_partition = partition;
        m_offset = offset;
        m_queue = new Queue(client.config);
//        m_cond = new TaskCondition(new TaskMutex);
        m_currentBuffer = null;
    }

    /// Consumes message from the selected topics and partitions
    /// Returns: Ranges of ranges for topics, partitions, messages and message chunks
    /+TopicRange consume() {
        // TEMP HACK
        auto conn = m_client.m_conns.values[0]; // FIXME
        return conn.getTopicRange(m_topics);
    }+/

    Message getMessage() {
        if (!m_currentBuffer)
            m_currentBuffer = m_queue.waitForFilledBuffer();
        if (m_currentBuffer.messageSetSize > 12 /* Offset + Message Size */) {
            import std.bitmanip, std.digest.crc;

            long offset = bigEndianToNative!long(m_currentBuffer.p[0 .. 8]);
            int messageSize = bigEndianToNative!int(m_currentBuffer.p[8 .. 12]);
            m_currentBuffer.p += 12;
            m_currentBuffer.messageSetSize -= 12;
            if (m_currentBuffer.messageSetSize >= messageSize) {
                scope (exit) {
                    m_currentBuffer.p += messageSize;
                    m_currentBuffer.messageSetSize -= messageSize;
                }
                // we got full message here
                ubyte[4] messageCrc = m_currentBuffer.p[0 .. 4];
                // check remainder bytes with CRC32 and compare
                ubyte[4] computedCrc = crc32Of(m_currentBuffer.p[4 .. messageSize]);
                if (computedCrc != messageCrc) {
                    // handle CRC error
                    throw new CrcException("Invalid message checksum");
                }
                byte magicByte = m_currentBuffer.p[4];
                enforce(magicByte == 0);
                byte attributes = m_currentBuffer.p[5];
                int keyLen = bigEndianToNative!int(m_currentBuffer.p[6 .. 10]);
                ubyte[] key = null;
                if (keyLen >= 0) {
                    // 14 = crc(4) + magicByte(1) + attributes(1) + keyLen(4) + valueLen(4)
                    enforce(keyLen <= messageSize - 14);
                    key = m_currentBuffer.p[10 .. 10 + keyLen];
                }
                auto pValue = m_currentBuffer.p + 10 + keyLen;
                int valueLen = bigEndianToNative!int(pValue[0 .. 4]);
                ubyte[] value = null;
                if (valueLen >= 0) {
                    enforce(valueLen <= messageSize - 14 - key.length);
                    pValue += 4;
                    value = pValue[0 .. valueLen];
                }

                byte compression = attributes & 3;
                if (compression != 0) {
                    // handle compression, this must be the only message in a message set
                } else {
                    // no compression, just return the message
                    return Message(offset, key, value);
                }
            } else {
                // this is partial message, skip it
            }
        } else {
            // no more messages
        }

        // TODO: parse qbuf data, check crc, and setup key and value slices FOR EACH MESSAGE, also handle last partial msg
        return Message();
    }
}
