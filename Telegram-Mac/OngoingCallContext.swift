//
//  OngoingCallContext.swift
//  Telegram
//
//  Created by Mikhail Filimonov on 23/06/2020.
//  Copyright © 2020 Telegram. All rights reserved.
//

import Cocoa
import Foundation
import SwiftSignalKit
import TelegramCore
import SyncCore
import Postbox
import TgVoipWebrtc
import TGUIKit

public enum OngoingCallVideoOrientation {
    case rotation0
    case rotation90
    case rotation180
    case rotation270
}

private extension OngoingCallVideoOrientation {
    init(_ orientation: OngoingCallVideoOrientationWebrtc) {
        switch orientation {
        case .orientation0:
            self = .rotation0
        case .orientation90:
            self = .rotation90
        case .orientation180:
            self = .rotation180
        case .orientation270:
            self = .rotation270
        @unknown default:
            self = .rotation0
        }
    }
}



public final class OngoingCallContextVideoView {
    public let view: NSView
    public let setOnFirstFrameReceived: (((Float) -> Void)?) -> Void
    public let getOrientation: () -> OngoingCallVideoOrientation
    public let setOnOrientationUpdated: (((OngoingCallVideoOrientation) -> Void)?) -> Void
    public let setVideoContentMode: (CALayerContentsGravity) -> Void
    public init(
        view: NSView,
        setOnFirstFrameReceived: @escaping (((Float) -> Void)?) -> Void,
        getOrientation: @escaping () -> OngoingCallVideoOrientation,
        setOnOrientationUpdated: @escaping (((OngoingCallVideoOrientation) -> Void)?) -> Void,
        setVideoContentMode: @escaping(CALayerContentsGravity) -> Void
        ) {
        self.view = view
        self.setOnFirstFrameReceived = setOnFirstFrameReceived
        self.getOrientation = getOrientation
        self.setOnOrientationUpdated = setOnOrientationUpdated
        self.setVideoContentMode = setVideoContentMode
    }
}



final class OngoingCallVideoCapturer {
    fileprivate let impl: OngoingCallThreadLocalContextVideoCapturer
    
    public init() {
        self.impl = OngoingCallThreadLocalContextVideoCapturer()
    }
    
    public func switchCamera() {
        self.impl.switchVideoCamera()
    }
    
    public func makeOutgoingVideoView(completion: @escaping (OngoingCallContextVideoView?) -> Void) {
        self.impl.makeOutgoingVideoView { view in
            if let view = view {
                completion(OngoingCallContextVideoView(
                    view: view, setOnFirstFrameReceived: { [weak view] f in
                        view?.setOnFirstFrameReceived(f)
                    }, getOrientation: {
                        return .rotation90
                    }, setOnOrientationUpdated: { _ in
                    }, setVideoContentMode: { [weak view] mode in
                        view?.setVideoContentMode(mode)
                    }
                ))
            } else {
                completion(nil)
            }
        }
    }
    
    public func setIsVideoEnabled(_ value: Bool) {
        self.impl.setIsVideoEnabled(value)
    }


}


private func callConnectionDescription(_ connection: CallSessionConnection) -> OngoingCallConnectionDescription? {
    switch connection {
    case let .reflector(reflector):
        return OngoingCallConnectionDescription(connectionId: reflector.id, ip: reflector.ip, ipv6: reflector.ipv6, port: reflector.port, peerTag: reflector.peerTag)
    case .webRtcReflector:
        return nil
    }
}

private func callConnectionDescriptionWebrtc(_ connection: CallSessionConnection) -> OngoingCallConnectionDescriptionWebrtc? {
    switch connection {
    case .reflector:
        return nil
    case let .webRtcReflector(reflector):
        return OngoingCallConnectionDescriptionWebrtc(connectionId: reflector.id, hasStun: reflector.hasStun, hasTurn: reflector.hasTurn, ip: reflector.ip.isEmpty ? reflector.ipv6 : reflector.ip, port: reflector.port, username: reflector.username, password: reflector.password)
    }
}


/*private func callConnectionDescriptionWebrtcCustom(_ connection: CallSessionConnection) -> OngoingCallConnectionDescriptionWebrtcCustom {
 return OngoingCallConnectionDescriptionWebrtcCustom(connectionId: connection.id, ip: connection.ip, ipv6: connection.ipv6, port: connection.port, peerTag: connection.peerTag)
 }*/

private let callLogsLimit = 20

func callLogNameForId(id: Int64, account: Account) -> String? {
    let path = callLogsPath(account: account)
    let namePrefix = "\(id)_"
    
    if let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants], errorHandler: nil) {
        for url in enumerator {
            if let url = url as? URL {
                if url.lastPathComponent.hasPrefix(namePrefix) {
                    return url.lastPathComponent
                }
            }
        }
    }
    return nil
}

func callLogsPath(account: Account) -> String {
    return account.basePath + "/calls"
}

private func cleanupCallLogs(account: Account) {
    let path = callLogsPath(account: account)
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: path, isDirectory: nil) {
        try? fileManager.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
    }
    
    var oldest: (URL, Date)? = nil
    var count = 0
    if let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants], errorHandler: nil) {
        for url in enumerator {
            if let url = url as? URL {
                if let date = (try? url.resourceValues(forKeys: Set([.contentModificationDateKey])))?.contentModificationDate {
                    if let currentOldest = oldest {
                        if date < currentOldest.1 {
                            oldest = (url, date)
                        }
                    } else {
                        oldest = (url, date)
                    }
                    count += 1
                }
            }
        }
    }
    if count > callLogsLimit, let oldest = oldest {
        try? fileManager.removeItem(atPath: oldest.0.path)
    }
}

private let setupLogs: Bool = {
    OngoingCallThreadLocalContext.setupLoggingFunction({ value in
        if let value = value {
            Logger.shared.log("TGVOIP", value)
        }
    })
    OngoingCallThreadLocalContextWebrtc.setupLoggingFunction({ value in
        if let value = value {
            Logger.shared.log("TGVOIP", value)
        }
    })
    /*OngoingCallThreadLocalContextWebrtcCustom.setupLoggingFunction({ value in
     if let value = value {
     Logger.shared.log("TGVOIP", value)
     }
     })*/
    return true
}()

public struct OngoingCallContextState: Equatable {
    public enum State {
        case initializing
        case connected
        case reconnecting
        case failed
    }
    
    public enum VideoState: Equatable {
        case notAvailable
        case inactive
        case active
        case paused
    }
    
    public enum RemoteVideoState: Equatable {
        case inactive
        case active
        case paused
    }
    
    public enum RemoteAudioState: Equatable {
        case active
        case muted
    }
    
    public enum RemoteBatteryLevel: Equatable {
        case normal
        case low
    }
    
    public let state: State
    public let videoState: VideoState
    public let remoteVideoState: RemoteVideoState
    public let remoteAudioState: RemoteAudioState
    public let remoteBatteryLevel: RemoteBatteryLevel
    public let remoteAspectRatio: Float
}


private final class OngoingCallThreadLocalContextQueueImpl: NSObject, OngoingCallThreadLocalContextQueue, OngoingCallThreadLocalContextQueueWebrtc /*, OngoingCallThreadLocalContextQueueWebrtcCustom*/ {
    private let queue: Queue
    
    init(queue: Queue) {
        self.queue = queue
        
        super.init()
    }
    
    func dispatch(_ f: @escaping () -> Void) {
        self.queue.async {
            f()
        }
    }
    
    func dispatch(after seconds: Double, block f: @escaping () -> Void) {
        self.queue.after(seconds, f)
    }
    
    func isCurrent() -> Bool {
        return self.queue.isCurrent()
    }
}

private func ongoingNetworkTypeForType(_ type: NetworkType) -> OngoingCallNetworkType {
    switch type {
    case .none:
        return .wifi
    case .wifi:
        return .wifi
    }
}

private func ongoingNetworkTypeForTypeWebrtc(_ type: NetworkType) -> OngoingCallNetworkTypeWebrtc {
    switch type {
    case .none:
        return .wifi
    case .wifi:
        return .wifi
    }
}

/*private func ongoingNetworkTypeForTypeWebrtcCustom(_ type: NetworkType) -> OngoingCallNetworkTypeWebrtcCustom {
 switch type {
 case .none:
 return .wifi
 case .wifi:
 return .wifi
 case let .cellular(cellular):
 switch cellular {
 case .edge:
 return .cellularEdge
 case .gprs:
 return .cellularGprs
 case .thirdG, .unknown:
 return .cellular3g
 case .lte:
 return .cellularLte
 }
 }
 }*/

private func ongoingDataSavingForType(_ type: VoiceCallDataSaving) -> OngoingCallDataSaving {
    switch type {
    case .never:
        return .never
    case .cellular:
        return .cellular
    case .always:
        return .always
    default:
        return .never
    }
}

private func ongoingDataSavingForTypeWebrtc(_ type: VoiceCallDataSaving) -> OngoingCallDataSavingWebrtc {
    switch type {
    case .never:
        return .never
    case .cellular:
        return .cellular
    case .always:
        return .always
    default:
        return .never
    }
}


private protocol OngoingCallThreadLocalContextProtocol: class {
    func nativeSetNetworkType(_ type: NetworkType)
    func nativeSetIsMuted(_ value: Bool)
    func nativeSetIsLowBatteryLevel(_ value: Bool)
    func nativeRequestVideo(_ capturer: OngoingCallVideoCapturer)
    func nativeDisableVideo()
    func nativeStop(_ completion: @escaping (String?, Int64, Int64, Int64, Int64) -> Void)
    func nativeBeginTermination()
    func nativeDebugInfo() -> String
    func nativeVersion() -> String
    func nativeGetDerivedState() -> Data

}

private final class OngoingCallThreadLocalContextHolder {
    let context: OngoingCallThreadLocalContextProtocol
    
    init(_ context: OngoingCallThreadLocalContextProtocol) {
        self.context = context
    }
}

extension OngoingCallThreadLocalContext: OngoingCallThreadLocalContextProtocol {
    
    
    func nativeSetNetworkType(_ type: NetworkType) {
        self.setNetworkType(ongoingNetworkTypeForType(type))
    }
    
    func nativeStop(_ completion: @escaping (String?, Int64, Int64, Int64, Int64) -> Void) {
        self.stop(completion)
    }
    
    func nativeBeginTermination() {
    }
    
    func nativeSetIsMuted(_ value: Bool) {
        self.setIsMuted(value)
    }
    
    func nativeRequestVideo(_ capturer: OngoingCallVideoCapturer) {
    }
    
    func nativeAcceptVideo(_ capturer: OngoingCallVideoCapturer) {
    }
    
    func nativeSetIsLowBatteryLevel(_ value: Bool) {
    }
    
    func nativeDisableVideo() {
    }
    
    func nativeSwitchVideoCamera() {
    }
    
    func nativeDebugInfo() -> String {
        return self.debugInfo() ?? ""
    }
    
    func nativeVersion() -> String {
        return self.version() ?? ""
    }
    
    func nativeGetDerivedState() -> Data {
        return self.getDerivedState()
    }
}

extension OngoingCallThreadLocalContextWebrtc: OngoingCallThreadLocalContextProtocol {
    func nativeSetNetworkType(_ type: NetworkType) {
        self.setNetworkType(ongoingNetworkTypeForTypeWebrtc(type))
    }
    
    func nativeStop(_ completion: @escaping (String?, Int64, Int64, Int64, Int64) -> Void) {
        self.stop(completion)
    }
    
    func nativeBeginTermination() {
        self.beginTermination()
    }
    
    func nativeSetIsMuted(_ value: Bool) {
        self.setIsMuted(value)
    }
    
    func nativeSetIsLowBatteryLevel(_ value: Bool) {
        self.setIsLowBatteryLevel(value)
    }
    
    func nativeRequestVideo(_ capturer: OngoingCallVideoCapturer) {
        self.requestVideo(capturer.impl)
    }
    
    func nativeDisableVideo() {
        self.disableVideo()
    }
    
    func nativeDebugInfo() -> String {
        return self.debugInfo() ?? ""
    }
    
    func nativeVersion() -> String {
        return self.version() ?? ""
    }
    
    func nativeGetDerivedState() -> Data {
        return self.getDerivedState()
    }
}


private extension OngoingCallContextState.State {
    init(_ state: OngoingCallState) {
        switch state {
        case .initializing:
            self = .initializing
        case .connected:
            self = .connected
        case .failed:
            self = .failed
        case .reconnecting:
            self = .reconnecting
        default:
            self = .failed
        }
    }
}

private extension OngoingCallContextState.State {
    init(_ state: OngoingCallStateWebrtc) {
        switch state {
        case .initializing:
            self = .initializing
        case .connected:
            self = .connected
        case .failed:
            self = .failed
        case .reconnecting:
            self = .reconnecting
        default:
            self = .failed
        }
    }
}

/*private extension OngoingCallContextState {
 init(_ state: OngoingCallStateWebrtcCustom) {
 switch state {
 case .initializing:
 self = .initializing
 case .connected:
 self = .connected
 case .failed:
 self = .failed
 case .reconnecting:
 self = .reconnecting
 default:
 self = .failed
 }
 }
 }*/

final class OngoingCallContext {
    struct AuxiliaryServer {
        enum Connection {
            case stun
            case turn(username: String, password: String)
        }
        
        let host: String
        let port: Int
        let connection: Connection
        
        init(
            host: String,
            port: Int,
            connection: Connection
            ) {
            self.host = host
            self.port = port
            self.connection = connection
        }
    }
    
    let internalId: CallSessionInternalId
    
    private let queue = Queue()
    private let account: Account
    private let callSessionManager: CallSessionManager
    private let logPath: String
    
    private var contextRef: Unmanaged<OngoingCallThreadLocalContextHolder>?
    
    private let contextState = Promise<OngoingCallContextState?>(nil)
    var state: Signal<OngoingCallContextState?, NoError> {
        return self.contextState.get()
    }
    
    private var didReportCallAsVideo: Bool = false
    
    
    private var signalingDataDisposable: Disposable?
    
    private let receptionPromise = Promise<Int32?>(nil)
    var reception: Signal<Int32?, NoError> {
        return self.receptionPromise.get()
    }
    
    private let audioSessionDisposable = MetaDisposable()
    private var networkTypeDisposable: Disposable?
    
    static var maxLayer: Int32 {
        return max(OngoingCallThreadLocalContext.maxLayer(), OngoingCallThreadLocalContextWebrtc.maxLayer())
    }
    
    static func versions(includeExperimental: Bool, includeReference: Bool) -> [(version: String, supportsVideo: Bool)] {
        var result: [(version: String, supportsVideo: Bool)] = [(OngoingCallThreadLocalContext.version(), false)]
        if includeExperimental {
            result.append(contentsOf: OngoingCallThreadLocalContextWebrtc.versions(withIncludeReference: includeReference).map { version -> (version: String, supportsVideo: Bool) in
                return (version, true)
            })
        }
        return result
    }

    
    init(account: Account, callSessionManager: CallSessionManager, internalId: CallSessionInternalId, proxyServer: ProxyServerSettings?, auxiliaryServers: [AuxiliaryServer], initialNetworkType: NetworkType, updatedNetworkType: Signal<NetworkType, NoError>, serializedData: String?, dataSaving: VoiceCallDataSaving, derivedState: VoipDerivedState, key: Data, isOutgoing: Bool, video: OngoingCallVideoCapturer?, connections: CallSessionConnectionSet, maxLayer: Int32, version: String, allowP2P: Bool, enableHighBitrateVideoCalls: Bool, logName: String) {
        let _ = setupLogs
        OngoingCallThreadLocalContext.applyServerConfig(serializedData)
        OngoingCallThreadLocalContextWebrtc.applyServerConfig(serializedData)
        
        self.internalId = internalId
        self.account = account
        self.callSessionManager = callSessionManager
        self.logPath = logName.isEmpty ? "" : callLogsPath(account: self.account) + "/" + logName + ".log"
        let logPath = self.logPath
        
        let queue = self.queue
        
        cleanupCallLogs(account: account)
        queue.sync {
            if OngoingCallThreadLocalContextWebrtc.versions(withIncludeReference: true).contains(version) {
                var voipProxyServer: VoipProxyServerWebrtc?
                if let proxyServer = proxyServer {
                    switch proxyServer.connection {
                    case let .socks5(username, password):
                        voipProxyServer = VoipProxyServerWebrtc(host: proxyServer.host, port: proxyServer.port, username: username, password: password)
                    case .mtp:
                        break
                    }
                }
                
                
                let unfilteredConnections = [connections.primary] + connections.alternatives
                var processedConnections: [CallSessionConnection] = []
                var filteredConnections: [OngoingCallConnectionDescriptionWebrtc] = []
                for connection in unfilteredConnections {
                    if processedConnections.contains(connection) {
                        continue
                    }
                    processedConnections.append(connection)
                    if let mapped = callConnectionDescriptionWebrtc(connection) {
                        if mapped.ip.isEmpty {
                            continue
                        }
                        filteredConnections.append(mapped)
                    }
                }
                
                let context = OngoingCallThreadLocalContextWebrtc(version: version, queue: OngoingCallThreadLocalContextQueueImpl(queue: queue), proxy: voipProxyServer, networkType: ongoingNetworkTypeForTypeWebrtc(initialNetworkType), dataSaving: ongoingDataSavingForTypeWebrtc(dataSaving), derivedState: derivedState.data, key: key, isOutgoing: isOutgoing, connections: filteredConnections, maxLayer: maxLayer, allowP2P: allowP2P, logPath: logPath, sendSignalingData: { [weak callSessionManager] data in
                    callSessionManager?.sendSignalingData(internalId: internalId, data: data)
                    }, videoCapturer: video?.impl, preferredAspectRatio: Float(System.aspectRatio), enableHighBitrateVideoCalls: enableHighBitrateVideoCalls)
                
                self.contextRef = Unmanaged.passRetained(OngoingCallThreadLocalContextHolder(context))
                context.stateChanged = { [weak self, weak callSessionManager] state, videoState, remoteVideoState, remoteAudioState, remoteBatteryLevel, remotePreferredAspectRatio in
                    queue.async {
                        guard let strongSelf = self else {
                            return
                        }
                        
                        let mappedState = OngoingCallContextState.State(state)
                        let mappedVideoState: OngoingCallContextState.VideoState
                        switch videoState {
                        case .inactive:
                            mappedVideoState = .inactive
                        case .active:
                            mappedVideoState = .active
                        case .paused:
                            mappedVideoState = .paused
                        @unknown default:
                            mappedVideoState = .notAvailable
                        }
                        let mappedRemoteVideoState: OngoingCallContextState.RemoteVideoState
                        switch remoteVideoState {
                        case .inactive:
                            mappedRemoteVideoState = .inactive
                        case .active:
                            mappedRemoteVideoState = .active
                        case .paused:
                            mappedRemoteVideoState = .paused
                        @unknown default:
                            mappedRemoteVideoState = .inactive
                        }
                        let mappedRemoteAudioState: OngoingCallContextState.RemoteAudioState
                        switch remoteAudioState {
                        case .active:
                            mappedRemoteAudioState = .active
                        case .muted:
                            mappedRemoteAudioState = .muted
                        @unknown default:
                            mappedRemoteAudioState = .active
                        }
                        let mappedRemoteBatteryLevel: OngoingCallContextState.RemoteBatteryLevel
                        switch remoteBatteryLevel {
                        case .normal:
                            mappedRemoteBatteryLevel = .normal
                        case .low:
                            mappedRemoteBatteryLevel = .low
                        @unknown default:
                            mappedRemoteBatteryLevel = .normal
                        }
                        if case .active = mappedVideoState, !strongSelf.didReportCallAsVideo {
                            strongSelf.didReportCallAsVideo = true
                            callSessionManager?.updateCallType(internalId: internalId, type: .video)
                        }
                        strongSelf.contextState.set(.single(OngoingCallContextState(state: mappedState, videoState: mappedVideoState, remoteVideoState: mappedRemoteVideoState, remoteAudioState: mappedRemoteAudioState, remoteBatteryLevel: mappedRemoteBatteryLevel, remoteAspectRatio: remotePreferredAspectRatio)))

                    }
                }
                context.signalBarsChanged = { [weak self] signalBars in
                    self?.receptionPromise.set(.single(signalBars))
                }
                
                self.networkTypeDisposable = (updatedNetworkType
                    |> deliverOn(queue)).start(next: { [weak self] networkType in
                        self?.withContext { context in
                            context.nativeSetNetworkType(networkType)
                        }
                    })
            } else {
                var voipProxyServer: VoipProxyServer?
                if let proxyServer = proxyServer {
                    switch proxyServer.connection {
                    case let .socks5(username, password):
                        voipProxyServer = VoipProxyServer(host: proxyServer.host, port: proxyServer.port, username: username, password: password)
                    case .mtp:
                        break
                    }
                }
                let context = OngoingCallThreadLocalContext(queue: OngoingCallThreadLocalContextQueueImpl(queue: queue), proxy: voipProxyServer, networkType: ongoingNetworkTypeForType(initialNetworkType), dataSaving: ongoingDataSavingForType(dataSaving), derivedState: derivedState.data, key: key, isOutgoing: isOutgoing, primaryConnection: callConnectionDescription(connections.primary)!, alternativeConnections: connections.alternatives.compactMap(callConnectionDescription), maxLayer: maxLayer, allowP2P: allowP2P, logPath: logPath)
                
                
                self.contextRef = Unmanaged.passRetained(OngoingCallThreadLocalContextHolder(context))
                context.stateChanged = { [weak self] state in
                    self?.contextState.set(.single(OngoingCallContextState(state: OngoingCallContextState.State(state), videoState: .notAvailable, remoteVideoState: .inactive, remoteAudioState: .active, remoteBatteryLevel: .normal, remoteAspectRatio: 0)))
                }
                context.signalBarsChanged = { [weak self] signalBars in
                    self?.receptionPromise.set(.single(signalBars))
                }
                
                self.networkTypeDisposable = (updatedNetworkType
                |> deliverOn(queue)).start(next: { [weak self] networkType in
                    self?.withContext { context in
                        context.nativeSetNetworkType(networkType)
                    }
                })
            }
        }
        
        
        self.signalingDataDisposable = (callSessionManager.callSignalingData(internalId: internalId)).start(next: { [weak self] data in
            print("data received")
            queue.async {
                self?.withContext { context in
                    if let context = context as? OngoingCallThreadLocalContextWebrtc {
                        context.addSignaling(data)
                    }
                }
            }
        })
    }
    
    deinit {
        let contextRef = self.contextRef
        self.queue.async {
            contextRef?.release()
        }
        
        self.audioSessionDisposable.dispose()
        self.networkTypeDisposable?.dispose()
    }
    
    private func withContext(_ f: @escaping (OngoingCallThreadLocalContextProtocol) -> Void) {
        self.queue.async {
            if let contextRef = self.contextRef {
                let context = contextRef.takeUnretainedValue()
                f(context.context)
            }
        }
    }
    
    func stop(callId: CallId? = nil, sendDebugLogs: Bool = false, debugLogValue: Promise<String?>) {
        let account = self.account
        let logPath = self.logPath
        
        self.withContext { context in
            context.nativeStop { debugLog, bytesSentWifi, bytesReceivedWifi, bytesSentMobile, bytesReceivedMobile in
                debugLogValue.set(.single(debugLog))
                let delta = NetworkUsageStatsConnectionsEntry(
                    cellular: NetworkUsageStatsDirectionsEntry(
                        incoming: bytesReceivedMobile,
                        outgoing: bytesSentMobile),
                    wifi: NetworkUsageStatsDirectionsEntry(
                        incoming: bytesReceivedWifi,
                        outgoing: bytesSentWifi))
                updateAccountNetworkUsageStats(account: self.account, category: .call, delta: delta)
                
                if !logPath.isEmpty, let debugLog = debugLog {
                    let logsPath = callLogsPath(account: account)
                    let _ = try? FileManager.default.createDirectory(atPath: logsPath, withIntermediateDirectories: true, attributes: nil)
                    if let data = debugLog.data(using: .utf8) {
                        let _ = try? data.write(to: URL(fileURLWithPath: logPath))
                    }
                }
                
                if let callId = callId, let debugLog = debugLog {
                    if sendDebugLogs {
                        let _ = saveCallDebugLog(network: self.account.network, callId: callId, log: debugLog).start()
                    }
                }
            }
            let derivedState = context.nativeGetDerivedState()
            let _ = updateVoipDerivedStateInteractively(postbox: self.account.postbox, { _ in
                return VoipDerivedState(data: derivedState)
            }).start()
        }
    }
    
    func setIsMuted(_ value: Bool) {
        self.withContext { context in
            context.nativeSetIsMuted(value)
        }
    }
    
    public func setIsLowBatteryLevel(_ value: Bool) {
        self.withContext { context in
            context.nativeSetIsLowBatteryLevel(value)
        }
    }
    
    public func requestVideo(_ capturer: OngoingCallVideoCapturer) {
        self.withContext { context in
            context.nativeRequestVideo(capturer)
        }
    }
    
    public func disableVideo() {
        self.withContext { context in
            context.nativeDisableVideo()
        }
    }
    
    func debugInfo() -> Signal<(String, String), NoError> {
        let poll = Signal<(String, String), NoError> { subscriber in
            self.withContext { context in
                let version = context.nativeVersion()
                let debugInfo = context.nativeDebugInfo()
                subscriber.putNext((version, debugInfo))
                subscriber.putCompletion()
            }
            
            return EmptyDisposable
        }
        return (poll |> then(.complete() |> delay(0.5, queue: Queue.concurrentDefaultQueue()))) |> restart
    }
    
    func makeIncomingVideoView(completion: @escaping (OngoingCallContextVideoView?) -> Void) {
        self.withContext { context in
            if let context = context as? OngoingCallThreadLocalContextWebrtc {
                context.makeIncomingVideoView { view in
                    if let view = view {
                        completion(OngoingCallContextVideoView(
                            view: view,
                            setOnFirstFrameReceived: { [weak view] f in
                                view?.setOnFirstFrameReceived(f)
                            },
                            getOrientation: { [weak view] in
                                if let view = view {
                                    return OngoingCallVideoOrientation(view.orientation)
                                } else {
                                    return .rotation0
                                }
                            },
                            setOnOrientationUpdated: { [weak view] f in
                                view?.setOnOrientationUpdated { value in
                                    f?(OngoingCallVideoOrientation(value))
                                }
                            }, setVideoContentMode: { [weak view] mode in
                                view?.setVideoContentMode(mode)
                            }
                        ))
                    } else {
                        completion(nil)
                    }
                }
            } else {
                completion(nil)
            }
        }
    }

}