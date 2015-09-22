﻿module kafkad.connection;

import kafkad.client;
import kafkad.protocol;
import kafkad.exception;
import kafkad.bundler;
import kafkad.queue;
import kafkad.utils.lists;
import vibe.core.core;
import vibe.core.net;
import vibe.core.task;
import vibe.core.sync;
import vibe.core.concurrency;
import std.format;
import core.time;

package:

enum RequestType { Metadata, Fetch, Produce, Offset };

struct Request {
    RequestType type;
    Tid tid;

    Request* next;
}

class BrokerConnection {
    private {
        Client m_client;
        TCPConnection m_conn;
        Serializer m_ser;
        Deserializer m_des;
        TaskMutex m_mutex;
        RequestBundler m_consumerRequestBundler;
        RequestBundler m_producerRequestBundler;
        FreeList!Request m_requests;
        Task m_fetcherTask, m_pusherTask, m_receiverTask;
        ubyte[] m_topicNameBuffer;
    }

    int id = -1;

    @property NetworkAddress addr() {
        return m_conn.remoteAddress.rethrow!ConnectionException("Could not get connection's remote address");
    }

    @property RequestBundler consumerRequestBundler() { return m_consumerRequestBundler; }
    @property RequestBundler producerRequestBundler() { return m_producerRequestBundler; }

    this(Client client, TCPConnection conn) {
        m_client = client;
        m_conn = conn;
        m_ser = Serializer(conn, client.config.serializerChunkSize);
        m_des = Deserializer(conn, client.config.deserializerChunkSize);
        m_mutex = new TaskMutex();
        m_consumerRequestBundler = new RequestBundler();
        m_producerRequestBundler = new RequestBundler();
        m_fetcherTask = runTask(&fetcherMain);
        m_pusherTask = runTask(&pusherMain);
        m_receiverTask = runTask(&receiverMain);
        m_topicNameBuffer = new ubyte[short.max];
    }

    void fetcherMain() {
        int size, correlationId;
        bool gotFirstRequest = false;
        MonoTime startTime;
        for (;;) {
            // send requests
            synchronized (m_consumerRequestBundler.mutex) {
                if (!gotFirstRequest) {
                    // wait for the first fetch request
                    while (!m_consumerRequestBundler.requestTopicsFront) {
                        m_consumerRequestBundler.readyCondition.wait();
                    }
                    if (m_consumerRequestBundler.requestsCollected < m_client.config.fetcherBundleMinRequests) {
                        gotFirstRequest = true;
                        // start the timer
                        startTime = MonoTime.currTime;
                        // wait for more requests
                        continue;
                    }
                } else {
                    // wait up to configured wait time or up to configured request count
                    while (m_consumerRequestBundler.requestsCollected < m_client.config.fetcherBundleMinRequests) {
                        Duration elapsedTime = MonoTime.currTime - startTime;
                        if (elapsedTime >= m_client.config.fetcherBundleMaxWaitTime.msecs)
                            break; // timeout reached
                        Duration remaining = m_client.config.fetcherBundleMaxWaitTime.msecs - elapsedTime;
                        if (!m_consumerRequestBundler.readyCondition.wait(remaining))
                            break; // timeout reached
                    }
                    gotFirstRequest = false;
                }

                synchronized (m_mutex) {
                    m_ser.fetchRequest_v0(0, m_client.clientId, m_client.config, m_consumerRequestBundler);
                    m_ser.flush();

                    // add request for each fetch
                    auto req = m_requests.getNodeToFill();
                    req.type = RequestType.Fetch;
                    m_requests.pushFilledNode(req);
                }

                m_consumerRequestBundler.clearRequestLists();
            }
        }
    }

    void pusherMain() {
        int size, correlationId;
        bool gotFirstRequest = false;
        MonoTime startTime;
        for (;;) {
            import vibe.core.log;
            // send requests
            synchronized (m_producerRequestBundler.mutex) {
                if (!gotFirstRequest) {
                    // wait for the first produce request
                    while (!m_producerRequestBundler.requestTopicsFront) {
                        m_producerRequestBundler.readyCondition.wait();
                    }
                    if (m_producerRequestBundler.requestsCollected < m_client.config.pusherBundleMinRequests) {
                        gotFirstRequest = true;
                        // start the timer
                        startTime = MonoTime.currTime;
                        // wait for more requests
                        continue;
                    }
                } else {
                    // wait up to configured wait time or up to configured request count
                    while (m_producerRequestBundler.requestsCollected < m_client.config.pusherBundleMinRequests) {
                        Duration elapsedTime = MonoTime.currTime - startTime;
                        if (elapsedTime >= m_client.config.pusherBundleMaxWaitTime.msecs)
                            break; // timeout reached
                        Duration remaining = m_client.config.pusherBundleMaxWaitTime.msecs - elapsedTime;
                        if (!m_producerRequestBundler.readyCondition.wait(remaining))
                            break; // timeout reached
                    }
                    gotFirstRequest = false;
                }
                
                synchronized (m_mutex) {
                    m_ser.produceRequest_v0(0, m_client.clientId, m_client.config, m_producerRequestBundler);
                    m_ser.flush();
                    
                    // add request for each fetch
                    auto req = m_requests.getNodeToFill();
                    req.type = RequestType.Produce;
                    m_requests.pushFilledNode(req);
                }
                
                m_producerRequestBundler.clearRequestLists();
            }
        }
    }

    void receiverMain() {
        try {
            int size, correlationId;
            for (;;) {
                m_des.getMessage(size, correlationId);
                m_des.beginMessage(size);
                scope (success)
                    m_des.endMessage();

                // requests are always processed in order on a single TCP connection,
                // and we rely on that order rather than on the correlationId
                // requests are pushed to the request queue by the consumer and producer
                // and they are popped here in the order they were sent
                Request req = void;
                synchronized (m_mutex) {
                    assert(!m_requests.empty);
                    auto node = m_requests.getNodeToProcess();
                    req = *node;
                    m_requests.returnProcessedNode(node);
                }

                switch (req.type) {
                    case RequestType.Metadata:
                        Metadata metadata = m_des.metadataResponse_v0();
                        send(req.tid, cast(shared)metadata);
                        break;
                    case RequestType.Offset:
                        OffsetResponse_v0 resp = m_des.offsetResponse_v0();
                        send(req.tid, cast(shared)resp);
                        break;
                    case RequestType.Fetch:
                        // parse the fetch response, move returned messages to the correct queues,
                        // and handle partition errors if needed
                        int numtopics;
                        m_des.deserialize(numtopics);
                        assert(numtopics > 0);
                        foreach (nt; 0 .. numtopics) {
                            string topic;
                            int numpartitions;
                            short topicNameLen;
                            m_des.deserialize(topicNameLen);

                            ubyte[] topicSlice = m_topicNameBuffer[0 .. topicNameLen];
                            m_des.deserializeSlice(topicSlice);
                            topic = cast(string)topicSlice;
                            m_des.deserialize(numpartitions);
                            assert(numpartitions > 0);

                            synchronized (m_consumerRequestBundler.mutex) {
                                Topic* queueTopic = m_consumerRequestBundler.findTopic(topic);

                                foreach (np; 0 .. numpartitions) {
                                    static struct FetchPartitionInfo {
                                        int partition;
                                        short errorCode;
                                        long endOffset;
                                        int messageSetSize;
                                    }
                                    FetchPartitionInfo fpi;
                                    m_des.deserialize(fpi);

                                    Partition* queuePartition = null;
                                    if (queueTopic)
                                        queuePartition = queueTopic.findPartition(fpi.partition);

                                    if (!queuePartition) {
                                        // skip the partition
                                        m_des.skipBytes(fpi.messageSetSize);
                                        continue;
                                    }

                                    Queue queue = queuePartition.queue;

                                    // TODO: handle errorCode
                                    switch (cast(ApiError)fpi.errorCode) {
                                        case ApiError.NoError: break;
                                        case ApiError.UnknownTopicOrPartition:
                                        case ApiError.LeaderNotAvailable:
                                        case ApiError.NotLeaderForPartition:
                                            // We need to refresh the metadata, get the new connection and
                                            // retry the request. To do so, we remove the consumer from this
                                            // connection and add it to the client brokerlessConsumers list.
                                            // The client will do the rest.
                                            m_consumerRequestBundler.removeQueue(queueTopic, queuePartition);
                                            m_des.skipBytes(fpi.messageSetSize);
                                            continue;
                                        case ApiError.OffsetOutOfRange:
                                            m_consumerRequestBundler.removeQueue(queueTopic, queuePartition);
                                            queue.worker.throwException(new Exception(format(
                                                        "Offset %d is out of range for topic %s, partition %d",
                                                        queue.offset, queueTopic.topic, queuePartition.partition)));
                                            m_des.skipBytes(fpi.messageSetSize);
                                            continue;
                                        default: throw new ProtocolException(format("Unexpected fetch response error: %d", fpi.errorCode));
                                    }

                                    if (fpi.messageSetSize > m_client.config.consumerMaxBytes) {
                                        m_consumerRequestBundler.removeQueue(queueTopic, queuePartition);
                                        queue.worker.throwException(new ProtocolException("MessageSet is too big to fit into a buffer"));
                                        m_des.skipBytes(fpi.messageSetSize);
                                        continue;
                                    }

                                    QueueBuffer* qbuf;

                                    synchronized (queue.mutex)
                                        qbuf = queue.getBuffer(BufferType.Free);

                                    // copy message set to the buffer
                                    m_des.deserializeSlice(qbuf.buffer[0 .. fpi.messageSetSize]);
                                    qbuf.p = qbuf.buffer;
                                    qbuf.messageSetSize = fpi.messageSetSize;

                                    // find the next offset to fetch
                                    long nextOffset = qbuf.findNextOffset();

                                    synchronized (queue.mutex) {
                                        if (nextOffset != -1)
                                            queue.offset = nextOffset;
                                        queue.returnBuffer(BufferType.Filled, qbuf);
                                        queue.condition.notify();
                                        // queue.fetchPending is always true here
                                        if (queue.hasBuffer(BufferType.Free))
                                            m_consumerRequestBundler.queueHasReadyBuffers(queueTopic, queuePartition);
                                        else
                                            queue.requestPending = false;
                                    }
                                }
                            }
                        }
                        break;
                    case RequestType.Produce:
                        int numtopics;
                        m_des.deserialize(numtopics);
                        assert(numtopics > 0);
                        foreach (nt; 0 .. numtopics) {
                            string topic;
                            int numpartitions;
                            short topicNameLen;
                            m_des.deserialize(topicNameLen);
                            
                            ubyte[] topicSlice = m_topicNameBuffer[0 .. topicNameLen];
                            m_des.deserializeSlice(topicSlice);
                            topic = cast(string)topicSlice;
                            m_des.deserialize(numpartitions);
                            assert(numpartitions > 0);
                            
                            synchronized (m_producerRequestBundler.mutex) {
                                Topic* queueTopic = m_producerRequestBundler.findTopic(topic);

                                foreach (np; 0 .. numpartitions) {
                                    static struct ProducePartitionInfo {
                                        int partition;
                                        short errorCode;
                                        long offset;
                                    }
                                    ProducePartitionInfo ppi;
                                    m_des.deserialize(ppi);
                                    
                                    Partition* queuePartition = null;
                                    if (queueTopic)
                                        queuePartition = queueTopic.findPartition(ppi.partition);

                                    assert(queuePartition);
                                    if (!queuePartition) {
                                        // skip the partition
                                        continue;
                                    }
                                    
                                    // TODO: handle errorCode
                                    switch (cast(ApiError)ppi.errorCode) {
                                        case ApiError.NoError: break;
                                        case ApiError.UnknownTopicOrPartition:
                                        case ApiError.LeaderNotAvailable:
                                        case ApiError.NotLeaderForPartition:
                                            // We need to refresh the metadata, get the new connection and
                                            // retry the request. To do so, we remove the producer from this
                                            // connection and add it to the client brokerlessWorkers list.
                                            // The client will do the rest.
                                            m_producerRequestBundler.removeQueue(queueTopic, queuePartition);
                                            continue;
                                        default: throw new ProtocolException(format("Unexpected produce response error: %d", ppi.errorCode));
                                    }

                                    Queue queue = queuePartition.queue;

                                    synchronized (queue.mutex) {
                                        //queue.returnBuffer(BufferType.Filled);
                                        // queue.requestPending is always true here
                                        if (queue.hasBuffer(BufferType.Filled))
                                            m_producerRequestBundler.queueHasReadyBuffers(queueTopic, queuePartition);
                                        else
                                            queue.requestPending = false;
                                    }
                                }
                            }
                        }
                        break;
                    default: assert(0); // FIXME
                }
            }
        }
        catch (StreamException ex) {
            // stream error, typically connection loss
            m_client.connectionLost(this);
        }
    }

    Metadata getMetadata(string[] topics) {
        synchronized (m_mutex) {
            m_ser.metadataRequest_v0(0, m_client.clientId, topics);
            m_ser.flush();

            auto req = m_requests.getNodeToFill();
            req.type = RequestType.Metadata;
            req.tid = thisTid;
            m_requests.pushFilledNode(req);
        }
        Metadata ret;
        receive((shared Metadata v) { ret = cast()v; });
        return ret;
    }

    long getStartingOffset(string topic, int partition, long offset) {
        assert(offset == -1 || offset == -2);
        OffsetRequestParams_v0.PartTimeMax[1] p;
        p[0].partition = partition;
        p[0].time = offset;
        p[0].maxOffsets = 1;
        OffsetRequestParams_v0.Topic[1] t;
        t[0].topic = topic;
        t[0].partitions = p;
        OffsetRequestParams_v0 params;
        params.replicaId = id;
        params.topics = t;
        synchronized (m_mutex) {
            m_ser.offsetRequest_v0(0, m_client.clientId, params);
            m_ser.flush();

            auto req = m_requests.getNodeToFill();
            req.type = RequestType.Offset;
            req.tid = thisTid;
            m_requests.pushFilledNode(req);
        }
        shared OffsetResponse_v0 resp;
        receive((shared OffsetResponse_v0 v) { resp = v; });
        enforce(resp.topics.length == 1);
        enforce(resp.topics[0].partitions.length == 1);
        import std.format;
        enforce(resp.topics[0].partitions[0].errorCode == 0,
            format("Could not get starting offset for topic %s and partition %d", topic, partition));
        enforce(resp.topics[0].partitions[0].offsets.length == 1);
        return resp.topics[0].partitions[0].offsets[0];
    }
}
