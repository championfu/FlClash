import Flutter
import NetworkExtension
import UIKit
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

        if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FlClashServicePlugin") {
            ServicePlugin.register(with: registrar)
        }
        if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FlClashAppPlugin") {
            IOSAppPlugin.register(with: registrar)
        }
    }
}

private enum IOSConstants {
    static let appGroup = "group.com.champion.flClash"
    static let providerBundleIdentifier = "com.champion.flClash.PacketTunnel"
    static let sharedStateKey = "sharedState"
    static let startTimeKey = "startTime"
}

final class IOSAppPlugin: NSObject, FlutterPlugin {
    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.follow.clash/app",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(IOSAppPlugin(), channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getSharedContainerPath":
            guard let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: IOSConstants.appGroup
            ) else {
                result(FlutterError(
                    code: "APP_GROUP_UNAVAILABLE",
                    message: "The FlClash App Group is not available. Check signing entitlements.",
                    details: IOSConstants.appGroup
                ))
                return
            }
            let support = container.appendingPathComponent("Library/Application Support", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                result(support.path)
            } catch {
                result(FlutterError(
                    code: "APP_GROUP_DIRECTORY_ERROR",
                    message: error.localizedDescription,
                    details: support.path
                ))
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

final class ServicePlugin: NSObject, FlutterPlugin, IOSServiceDelegate {
    private var channel: FlutterMethodChannel?
    private let service = IOSService.shared

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = ServicePlugin()
        let channel = FlutterMethodChannel(
            name: "com.follow.clash/service",
            binaryMessenger: registrar.messenger()
        )
        instance.channel = channel
        instance.service.delegate = instance
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "init":
            service.initialize { error in result(error?.localizedDescription ?? "") }
        case "shutdown":
            service.shutdown()
            result(true)
        case "invokeAction":
            guard let action = call.arguments as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected an action string", details: nil))
                return
            }
            service.invokeAction(action) { response in result(response) }
        case "getRunTime":
            result(service.runTime)
        case "syncState":
            guard let state = call.arguments as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected a state string", details: nil))
                return
            }
            service.syncState(state) { error in result(error?.localizedDescription ?? "") }
        case "start":
            service.start { error in
                if let error {
                    result(FlutterError(code: "START_ERROR", message: error.localizedDescription, details: nil))
                } else {
                    result(true)
                }
            }
        case "stop":
            service.stop()
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    func serviceDidEmit(event: String) {
        channel?.invokeMethod("event", arguments: event)
    }

    func serviceDidCrash(message: String) {
        channel?.invokeMethod("crash", arguments: message)
    }
}

protocol IOSServiceDelegate: AnyObject {
    func serviceDidEmit(event: String)
    func serviceDidCrash(message: String)
}

final class IOSService {
    static let shared = IOSService()

    weak var delegate: IOSServiceDelegate?
    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var eventTimer: Timer?
    private var isPollingEvent = false
    private var lastActionRoute: String?
    private var lastLoggedStatus: NEVPNStatus?
    private let defaults = UserDefaults(suiteName: IOSConstants.appGroup)

    private init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.handleStatusChange() }
        eventTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.pollEvent()
        }
    }

    deinit {
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
        eventTimer?.invalidate()
    }

    var runTime: Int64 {
        guard isTunnelActive,
              let startTime = defaults?.object(forKey: IOSConstants.startTimeKey) as? Date else {
            return 0
        }
        return Int64(startTime.timeIntervalSince1970 * 1000)
    }

    func initialize(completion: @escaping (Error?) -> Void) {
        loadManager(completion: completion)
    }

    func shutdown() {
        TunnelDiagnostics.log("Service", "shutdown requested (no native teardown implemented)")
    }

    func syncState(_ state: String, completion: @escaping (Error?) -> Void) {
        if let object = try? JSONSerialization.jsonObject(with: Data(state.utf8)) as? [String: Any] {
            TunnelDiagnostics.log("Service", "syncState active=\(isTunnelActive) " + TunnelDiagnostics.stateSummary(object))
        } else {
            TunnelDiagnostics.log("Service", "syncState invalidJSON")
        }
        defaults?.set(state, forKey: IOSConstants.sharedStateKey)
        guard isTunnelActive else {
            completion(nil)
            return
        }
        sendProviderMessage(type: "syncState", payload: state) { _, error in completion(error) }
    }

    func invokeAction(_ action: String, completion: @escaping (String?) -> Void) {
        let route = isTunnelActive ? "extension" : "appCore"
        if lastActionRoute != route {
            TunnelDiagnostics.log("Service", "actionRoute=\(route) vpnStatus=\(statusName)")
            lastActionRoute = route
        }
        if isTunnelActive {
            sendProviderMessage(type: "invokeAction", payload: action) { response, error in
                if let error { self.delegate?.serviceDidCrash(message: error.localizedDescription) }
                completion(response)
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let response = FlClashCore.invoke(action)
            DispatchQueue.main.async { completion(response) }
        }
    }

    func start(completion: @escaping (Error?) -> Void) {
        let trace = TunnelDiagnostics.Span("Service", "startVPN status=\(statusName)")
        // Dart starts the local listener first. Release its ports before the
        // Packet Tunnel extension starts an independent core instance.
        _ = FlClashCore.invoke(
            "{\"id\":\"stopListener#ios\",\"method\":\"stopListener\",\"data\":null}"
        )
        trace.checkpoint("localListener.stopped")
        let start: () -> Void = { [weak self] in
            guard let self, let manager = self.manager else {
                trace.finish("managerUnavailable", failed: true)
                return
            }
            manager.isEnabled = true
            trace.checkpoint("saveToPreferences.begin")
            manager.saveToPreferences { error in
                if let error {
                    TunnelDiagnostics.error("Service", "saveToPreferences", error)
                    trace.finish("saveFailed", failed: true)
                    completion(error)
                    return
                }
                trace.checkpoint("saveToPreferences.end loadFromPreferences.begin")
                manager.loadFromPreferences { error in
                    if let error {
                        TunnelDiagnostics.error("Service", "loadFromPreferences", error)
                        trace.finish("reloadFailed", failed: true)
                        completion(error)
                        return
                    }
                    trace.checkpoint("loadFromPreferences.end startVPNTunnel.begin")
                    do {
                        try manager.connection.startVPNTunnel()
                        trace.finish("requestAccepted (await VPN status notification)")
                        self.defaults?.set(Date(), forKey: IOSConstants.startTimeKey)
                        self.updateSharedVPNState()
                        completion(nil)
                    } catch {
                        TunnelDiagnostics.error("Service", "startVPNTunnel", error)
                        trace.finish("requestRejected", failed: true)
                        completion(error)
                    }
                }
            }
        }

        if manager == nil {
            loadManager { error in
                if let error {
                    trace.finish("loadManagerFailed", failed: true)
                    completion(error)
                } else { start() }
            }
        } else {
            start()
        }
    }

    func stop() {
        TunnelDiagnostics.log("Service", "stopVPN requested status=\(statusName)")
        manager?.connection.stopVPNTunnel()
        defaults?.removeObject(forKey: IOSConstants.startTimeKey)
        defaults?.set(false, forKey: FlClashControlShared.vpnStateKey)
        reloadControls()
    }

    /// Entry point used by the Control Center control (ToggleVPNIntent).
    func setEnabled(_ enabled: Bool, completion: @escaping (Error?) -> Void) {
        defaults?.set(enabled, forKey: FlClashControlShared.vpnStateKey)
        reloadControls()
        if manager == nil {
            loadManager { [weak self] error in
                guard let self else {
                    completion(nil)
                    return
                }
                if let error {
                    completion(error)
                    return
                }
                self.setEnabled(enabled, completion: completion)
            }
            return
        }
        if enabled {
            start(completion: completion)
        } else {
            stop()
            completion(nil)
        }
    }

    func updateSharedVPNState() {
        let on = isTunnelActive || manager?.connection.status == .connecting
        defaults?.set(on, forKey: FlClashControlShared.vpnStateKey)
        reloadControls()
    }

    private func reloadControls() {
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: FlClashControlShared.controlKind)
        }
    }

    private var isTunnelActive: Bool {
        guard let status = manager?.connection.status else { return false }
        return status == .connected || status == .reasserting
    }

    private var statusName: String {
        guard let status = manager?.connection.status else { return "noManager" }
        switch status {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown"
        }
    }

    private func loadManager(completion: @escaping (Error?) -> Void) {
        let trace = TunnelDiagnostics.Span("Service", "loadManager")
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self else {
                trace.finish("serviceReleased", failed: true)
                return
            }
            if let error {
                TunnelDiagnostics.error("Service", "loadManager", error)
                trace.finish("failed", failed: true)
                completion(error)
                return
            }
            self.manager = managers?.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                    == IOSConstants.providerBundleIdentifier
            }) ?? self.makeManager()
            self.updateSharedVPNState()
            trace.finish("status=\(self.statusName)")
            completion(nil)
        }
    }

    private func makeManager() -> NETunnelProviderManager {
        let manager = NETunnelProviderManager()
        let configuration = NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = IOSConstants.providerBundleIdentifier
        configuration.serverAddress = "FlClash"
        manager.protocolConfiguration = configuration
        manager.localizedDescription = "FlClash"
        manager.isEnabled = true
        return manager
    }

    private func sendProviderMessage(
        type: String,
        payload: String,
        completion: @escaping (String?, Error?) -> Void
    ) {
        let method = type == "invokeAction" ? TunnelDiagnostics.actionName(payload) : type
        let trace = TunnelDiagnostics.Span("IPC", "send \(method)", quiet: TunnelDiagnostics.isFrequent(method))
        guard let session = manager?.connection as? NETunnelProviderSession else {
            trace.finish("sessionUnavailable", failed: true)
            completion(nil, NSError(
                domain: "FlClash.IOSService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Packet tunnel session is unavailable"]
            ))
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload])
            try session.sendProviderMessage(data) { response in
                trace.finish("responseBytes=\(response?.count ?? 0) nilResponse=\(response == nil)", failed: response == nil)
                let value = response.flatMap { String(data: $0, encoding: .utf8) }
                DispatchQueue.main.async { completion(value, nil) }
            }
        } catch {
            TunnelDiagnostics.error("IPC", "sendProviderMessage", error)
            trace.finish("sendFailed", failed: true)
            completion(nil, error)
        }
    }

    private func handleStatusChange() {
        let status = manager?.connection.status
        if lastLoggedStatus != status {
            TunnelDiagnostics.log("Service", "vpnStatus=\(statusName)")
            lastLoggedStatus = status
            if status == .disconnected, #available(iOS 16.0, *) {
                manager?.connection.fetchLastDisconnectError { error in
                    if let error {
                        TunnelDiagnostics.error("Service", "lastDisconnectError", error)
                    } else {
                        TunnelDiagnostics.log("Service", "lastDisconnectError=none")
                    }
                }
            }
        }
        updateSharedVPNState()
        guard manager?.connection.status == .disconnected else { return }
        defaults?.removeObject(forKey: IOSConstants.startTimeKey)
    }

    private func pollEvent() {
        guard !isPollingEvent else { return }
        if isTunnelActive {
            isPollingEvent = true
            sendProviderMessage(type: "pollEvent", payload: "") { [weak self] event, _ in
                guard let self else { return }
                self.isPollingEvent = false
                if let event, !event.isEmpty {
                    self.delegate?.serviceDidEmit(event: event)
                }
            }
        } else if let event = FlClashCore.pollEvent() {
            delegate?.serviceDidEmit(event: event)
        }
    }
}
