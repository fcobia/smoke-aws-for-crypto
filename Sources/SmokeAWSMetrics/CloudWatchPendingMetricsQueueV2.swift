// Copyright 2018-2022 Amazon.com, Inc. or its affiliates. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// You may not use this file except in compliance with the License.
// A copy of the License is located at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// or in the "license" file accompanying this file. This file is distributed
// on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
// express or implied. See the License for the specific language governing
// permissions and limitations under the License.
//
//  CloudWatchPendingMetricsQueueV2.swift
//  SmokeAWSMetrics
//

#if compiler(>=5.7)

import Foundation
import CloudWatchClient
import CloudWatchModel
import AsyncAlgorithms
import Logging

private struct QueueV2Helper {
    
}

@available(macOS 13.0, *)
internal actor CloudWatchPendingMetricsQueueV2: MetricsQueue {
    private let logger: Logger
    private let cloudWatchClient: CloudWatchClientProtocol
    private var shutdownWaitingContinuations: [CheckedContinuation<Void, Error>] = []
    private let chunkedEntryStream: AsyncChunksOfCountOrSignalSequence<AsyncStream<Entry>, [Entry], AsyncTimerSequence<SuspendingClock>>
    private let entryHander: (Entry) -> ()
    private let finishHandler: () -> ()
    
    private let queueConsumingTaskIntervalInSeconds = 2
    // CloudWatch has a limit of 20 Dataums per request
    // https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/cloudwatch_limits.html
    private let maximumDataumsPerRequest = 20
    
    enum State {
        case initialized
        case running
        case shuttingDown
        case shutDown
    }
    private var state: State = .initialized
    
    init(cloudWatchClient: CloudWatchClientProtocol, logger: Logger) {
        self.cloudWatchClient = cloudWatchClient
        self.logger = logger
        
        var newEntryHandler: ((Entry) -> ())?
        var newFinishHandler: (() -> ())?
        let rawEntryStream = AsyncStream { continuation in
            newEntryHandler = { entry in
                continuation.yield(entry)
            }
            
            newFinishHandler = {
                continuation.finish()
            }
        }
        
        guard let newEntryHandler = newEntryHandler, let newFinishHandler = newFinishHandler else {
            fatalError()
        }
        
        // chunk the stream either by count or by time. This will send the metrics to cloudwatch
        // as soon as there is `self.maximumDataumsPerRequest` entries to be sent (these will then be
        // sent in one cloudwatch request per namespace) or after `queueConsumingTaskIntervalInSeconds`
        // time has passed.
        self.chunkedEntryStream = rawEntryStream.chunks(ofCount: self.maximumDataumsPerRequest,
                                                        or: .repeating(every: .seconds(queueConsumingTaskIntervalInSeconds)))
        
        self.entryHander = newEntryHandler
        self.finishHandler = newFinishHandler
    }
    
    /**
     Starts the submission queue.
     */
    func start() {
        guard updateOnStart() else {
            // nothing to do; already started
            return
        }
        
        Task {
            self.logger.info("CloudWatchPendingMetricsQueue started.")
            
            for await entryChunk in self.chunkedEntryStream {
                Task {
                    await handleEntryChunk(currentPendingEntries: entryChunk)
                }
            }
            
            // shutdown the queue if required
            if let queueShutdownDetails = self.isShuttingDown() {
                // resume any continuations
                queueShutdownDetails.awaitingContinuations.forEach { $0.resume(returning: ()) }
                
                self.updateStateOnShutdownComplete()
            }
        }
    }
    
    /**
     Initiates the process of shutting down the queue.
     */
    func shutdown() throws {
        _ = try updateOnShutdownStart()
    }
    
    public func untilShutdown() async throws {
        return try await withCheckedThrowingContinuation { cont in
            if !isShutdownOtherwiseAddContinuation(newContinuation: cont) {
                // continuation will be resumed when the server shuts down
            } else {
                // server is already shutdown
                cont.resume(returning: ())
            }
        }
    }
    
    nonisolated func submit(namespace: String, data: MetricDatum) {
        let entry = Entry(namespace: namespace, data: data)
        self.entryHander(entry)
    }
    
    private func handleEntryChunk(currentPendingEntries: [Entry]) async {
        self.logger.trace("Handling Cloudwatch entries chunk of size \(currentPendingEntries.count)")
        
        if !currentPendingEntries.isEmpty {
            // transform the list of pending entries into a map keyed by namespace
            var namespacedEntryMap: [String: [MetricDatum]] = [:]
            currentPendingEntries.forEach { entry in
                if var dataList = namespacedEntryMap[entry.namespace] {
                    dataList.append(entry.data)
                    namespacedEntryMap[entry.namespace] = dataList
                } else {
                    namespacedEntryMap[entry.namespace] = [entry.data]
                }
            }
            
            // for each namespace, kick off calls to CloudWatch
            for (namespace, dataList) in namespacedEntryMap {
                let chunkedList = dataList.chunked(by: self.maximumDataumsPerRequest)
                
                for dataListChunk in chunkedList {
                    let input = PutMetricDataInput(metricData: dataListChunk, namespace: namespace)
                    self.logger.trace("Handling Cloudwatch entries to namespace \(namespace): \(input)")
                    
                    do {
                        try await self.cloudWatchClient.putMetricData(input: input)
                    } catch {
                        self.logger.error("Unable to submit metrics to CloudWatch: \(String(describing: error))")
                    }
                }
            }
        }
    }
    
    
    
    /**
     Updates the Lifecycle state on a start request.

     - Returns: if the start request should be acted upon (and the queue started).
                Will be false if the queue is already running, shutting down or has completed shutting down.
     */
    private func updateOnStart() -> Bool {
        if case .initialized = state {
            state = .running
            
            return true
        }
        
        return false
    }
    
    /**
     Updates the Lifecycle state on a shutdown request.

     - Returns: if the shutdown request should be acted upon (and the queue shutdown).
                Will be false if the queue is already shutting down or has completed shutting down.
     - Throws: if the queue has never been started.
     */
    private func updateOnShutdownStart() throws -> Bool {
        let doShutdownServer: Bool
        switch state {
        case .initialized:
            throw CloudWatchPendingMetricsQueueError.shutdownAttemptOnUnstartedQueue
        case .running:
            state = .shuttingDown
            
            self.finishHandler()
            
            doShutdownServer = true
        case .shuttingDown, .shutDown:
            // nothing to do; already shutting down or shutdown
            doShutdownServer = false
        }
        
        return doShutdownServer
    }
    
    /**
     Updates the Lifecycle state on shutdown completion.
     */
    private func updateStateOnShutdownComplete() {

        guard case .shuttingDown = state else {
            fatalError("CloudWatchPendingMetricsQueue shutdown completed when in unexpected state: \(state)")
        }
        state = .shutDown
    }
    
    /**
     Indicates if the queue is currently shutdown.

     - Returns: if the queue is currently shutdown.
     */
    private func isShutdown() -> Bool {
        if case .shutDown = state {
            return true
        }
        
        return false
    }
    
    public func isShutdownOtherwiseAddContinuation(newContinuation: CheckedContinuation<Void, Error>) -> Bool {
        if case .shutDown = state {
            return true
        }
        
        self.shutdownWaitingContinuations.append(newContinuation)
        
        return false
    }
    
    /**
     Indicates if the queue is currently shutting down.

     - Returns: if the queue is currently shutting down.
     */
    private func isShuttingDown() -> QueueShutdownDetails? {
        if case .shuttingDown = state {
            let waitingContinuations = self.shutdownWaitingContinuations
            self.shutdownWaitingContinuations = []
        
            return QueueShutdownDetails(awaitingContinuations: waitingContinuations)
        }
        
        return nil
    }
}
#endif
