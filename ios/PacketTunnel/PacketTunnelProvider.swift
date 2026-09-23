import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let appGroup = "group.com.champion.flClash"
    private static let sharedStateKey = "sharedState"
    private static let ipv4Address = "172.19.0.1"
    private static let ipv4Prefix = "172.19.0.1/30"
    private static let dns4 = "172.19.0.2"
    private static let ipv6Address = "fdfe:dcba:9876::1"
    private static let ipv6Prefix = "fdfe:dcba:9876::1/126"
    private static let dns6 = "fdfe:dcba:9876::2"

    /// 并发队列：只读动作（测速/查询/事件）彼此并发，生命周期与配置动作以 barrier 独占。
    /// 核本身支持并发动作（Android 侧就是每个 action 一个 goroutine），串行只是平台侧的限制。
    private let coreQueue = DispatchQueue(
        label: "com.follow.flclash.packet-tunnel.core",
        attributes: .concurrent
    )
    /// 并发动作在白名单内，可与彼此并发，但仍会被 barrier 动作挡住。
    private static let readOnlyMethods: Set<String> = [
        "asyncTestDelay", "getProxies", "getTraffic", "getTotalTraffic",
        "getConnections", "getExternalProvider", "getExternalProviders",
        "getConfig", "validateConfig", "getMemory",
    ]
    /// 测速并发上限：扩展进程内存有限，避免一次性开出几十条连接。
    private static let testDelayGate = DispatchSemaphore(value: 8)
    private var sharedState: [String: Any] = [:]

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let trace = TunnelDiagnostics.Span("PacketTunnel", "startTunnel")
        do {
            sharedState = try loadSharedState()
            trace.checkpoint("sharedStateLoaded " + TunnelDiagnostics.stateSummary(sharedState))
            let vpnOptions = sharedState["vpnOptions"] as? [String: Any] ?? [:]
            trace.checkpoint("setNetworkSettings.begin mtu=9000 ipv4DefaultRoute=true")
            setTunnelNetworkSettings(makeNetworkSettings(vpnOptions: vpnOptions)) { [weak self] error in
                guard let self else {
                    trace.finish("providerReleased", failed: true)
                    return
                }
                if let error {
                    TunnelDiagnostics.error("PacketTunnel", "setNetworkSettings", error)
                    trace.finish("networkSettingsFailed", failed: true)
                    completionHandler(error)
                    return
                }
                trace.checkpoint("networkSettings.applied coreQueue.enqueue")
                self.coreQueue.async(flags: .barrier) {
                    trace.checkpoint("coreQueue.enter")
                    do {
                        try self.startCore(vpnOptions: vpnOptions)
                        trace.finish("ready")
                        completionHandler(nil)
                    } catch {
                        TunnelDiagnostics.error("PacketTunnel", "startCore", error)
                        trace.finish("coreFailed", failed: true)
                        completionHandler(error)
                    }
                }
            }
        } catch {
            TunnelDiagnostics.error("PacketTunnel", "loadSharedState", error)
            trace.finish("sharedStateFailed", failed: true)
            completionHandler(error)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        let trace = TunnelDiagnostics.Span("PacketTunnel", "stopTunnel reason=\(reason.rawValue)")
        coreQueue.async(flags: .barrier) {
            trace.checkpoint("coreQueue.enter")
            FlClashCore.stopTunnel()
            trace.finish()
            completionHandler()
        }
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        let receivedAt = ProcessInfo.processInfo.systemUptime
        // 先分流：只读动作并发执行，生命周期与配置动作以 barrier 互斥。
        // 这里只做一次便宜的解析用于选队列，真正的处理仍在队列内执行（保留 queueWait 埋点语义）。
        let probe = (try? JSONSerialization.jsonObject(with: messageData)) as? [String: Any]
        let incomingType = probe?["type"] as? String
        let incomingPayload = probe?["payload"] as? String
        let incomingMethod = incomingType == "invokeAction"
            ? TunnelDiagnostics.actionName(incomingPayload ?? "")
            : (incomingType ?? "invalid")
        let isReadOnly = incomingType == "pollEvent"
            || (incomingType == "invokeAction" && Self.readOnlyMethods.contains(incomingMethod))

        let task: () -> Void = { [weak self] in
            guard let self else {
                completionHandler?(nil)
                return
            }
            let waitMs = Int((ProcessInfo.processInfo.systemUptime - receivedAt) * 1000)
            if waitMs >= 1000 {
                TunnelDiagnostics.log("PacketTunnel", "handleAppMessage queueWaitMs=\(waitMs)")
            }
            do {
                guard let envelope = try JSONSerialization.jsonObject(with: messageData) as? [String: Any],
                      let type = envelope["type"] as? String,
                      let payload = envelope["payload"] as? String else {
                    throw TunnelError.invalidMessage
                }
                switch type {
                case "invokeAction":
                    completionHandler?(FlClashCore.invoke(payload)?.data(using: .utf8))
                case "syncState":
                    self.sharedState = try self.decodeObject(payload)
                    TunnelDiagnostics.log("PacketTunnel", "syncState " + TunnelDiagnostics.stateSummary(self.sharedState))
                    UserDefaults(suiteName: Self.appGroup)?.set(payload, forKey: Self.sharedStateKey)
                    completionHandler?(Data())
                case "pollEvent":
                    completionHandler?(FlClashCore.pollEvent()?.data(using: .utf8) ?? Data())
                default:
                    throw TunnelError.invalidMessage
                }
            } catch {
                TunnelDiagnostics.error("PacketTunnel", "handleAppMessage.cancelTunnel", error)
                completionHandler?(nil)
                self.cancelTunnelWithError(error)
            }
        }

        guard isReadOnly else {
            coreQueue.async(flags: .barrier, execute: task)
            return
        }
        coreQueue.async {
            if incomingMethod == "asyncTestDelay" {
                Self.testDelayGate.wait()
                defer { Self.testDelayGate.signal() }
            }
            task()
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        TunnelDiagnostics.log("PacketTunnel", "sleep")
        completionHandler()
    }

    override func wake() {
        TunnelDiagnostics.log("PacketTunnel", "wake")
    }

    private func startCore(vpnOptions: [String: Any]) throws {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroup
        ) else {
            TunnelDiagnostics.log("PacketTunnel", "appGroup.unavailable")
            throw TunnelError.appGroupUnavailable
        }
        let home = container.appendingPathComponent("Library/Application Support", isDirectory: true)
        let configURL = home.appendingPathComponent("config.yaml")
        let attributes = try? FileManager.default.attributesOfItem(atPath: configURL.path)
        let configBytes = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        TunnelDiagnostics.log("PacketTunnel", "appGroup.available configReadable=\(FileManager.default.isReadableFile(atPath: configURL.path)) configBytes=\(configBytes)")
        let initData = try encodeObject([
            "home-dir": home.path,
            "version": ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        ])
        try requireSuccessfulAction(method: "initClash", data: initData)

        guard let setupParams = sharedState["setupParams"] as? [String: Any] else {
            TunnelDiagnostics.log("PacketTunnel", "setupParams.missing")
            throw TunnelError.missingSetupState
        }
        try requireSuccessfulAction(method: "setupConfig", data: try encodeObject(setupParams))

        TunnelDiagnostics.log("PacketTunnel", "packetFlow.lookupFD.begin")
        guard let fileDescriptor = tunnelFileDescriptor() else {
            TunnelDiagnostics.log("PacketTunnel", "packetFlow.lookupFD.unavailable")
            throw TunnelError.fileDescriptorUnavailable
        }
        TunnelDiagnostics.log("PacketTunnel", "packetFlow.lookupFD.end fd=\(fileDescriptor)")
        let ipv6 = vpnOptions["ipv6"] as? Bool == true
        let address = ipv6 ? "\(Self.ipv4Prefix),\(Self.ipv6Prefix)" : Self.ipv4Prefix
        let dnsHijacking = vpnOptions["dnsHijacking"] as? Bool != false
        let dns = dnsHijacking
            ? "0.0.0.0\(ipv6 ? ",::" : "")"
            : "\(Self.dns4)\(ipv6 ? ",\(Self.dns6)" : "")"
        let configuredStack = vpnOptions["stack"] as? String ?? "mixed"
        let stackLabel = ["mixed", "system", "gvisor"].contains(configuredStack) ? configuredStack : "unknown"
        TunnelDiagnostics.log("PacketTunnel", "attachTUN stack=\(stackLabel) ipv6=\(ipv6) dnsHijacking=\(dnsHijacking)")

        guard FlClashCore.startTunnel(
            fileDescriptor: fileDescriptor,
            stack: vpnOptions["stack"] as? String ?? "mixed",
            address: address,
            dns: dns
        ) else {
            throw TunnelError.coreStartFailed
        }
    }

    /// `NEPacketTunnelFlow` does not expose its utun descriptor as public API.
    /// Older iOS releases happened to expose it through KVC, while newer
    /// releases frequently return nil. Locate the utun control socket in this
    /// extension process first, then keep the KVC lookup as a legacy fallback.
    private func tunnelFileDescriptor() -> Int32? {
        if let descriptor = scanForUtunFileDescriptor() {
            TunnelDiagnostics.log("PacketTunnel", "packetFlow.lookupFD source=utunScan")
            return descriptor
        }

        if let descriptor = packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32,
           descriptor >= 0 {
            TunnelDiagnostics.log("PacketTunnel", "packetFlow.lookupFD source=legacyKVC")
            return descriptor
        }
        if let number = packetFlow.value(forKeyPath: "socket.fileDescriptor") as? NSNumber {
            let descriptor = number.int32Value
            if descriptor >= 0 {
                TunnelDiagnostics.log("PacketTunnel", "packetFlow.lookupFD source=legacyNSNumber")
                return descriptor
            }
        }
        return nil
    }

    private func scanForUtunFileDescriptor() -> Int32? {
        let descriptor = FlClashFindUtunFileDescriptor()
        return descriptor >= 0 ? descriptor : nil
    }

    private func requireSuccessfulAction(method: String, data: Any) throws {
        let action = try encodeObject(["id": "\(method)#ios", "method": method, "data": data])
        guard let response = FlClashCore.invoke(action),
              let result = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
              (result["code"] as? Int) == 0 else {
            TunnelDiagnostics.log("PacketTunnel", "coreAction.failed method=\(method)")
            throw TunnelError.coreActionFailed(method)
        }
        if let message = result["data"] as? String, !message.isEmpty {
            TunnelDiagnostics.log("PacketTunnel", "coreAction.errorMessage method=\(method) messageBytes=\(message.utf8.count)")
            throw TunnelError.coreMessage(message)
        }
    }

    private func makeNetworkSettings(vpnOptions: [String: Any]) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: Self.ipv4Address)
        settings.mtu = 9000

        let ipv4 = NEIPv4Settings(addresses: [Self.ipv4Address], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        let ipv6Enabled = vpnOptions["ipv6"] as? Bool == true
        if ipv6Enabled {
            let ipv6 = NEIPv6Settings(addresses: [Self.ipv6Address], networkPrefixLengths: [126])
            ipv6.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = ipv6
        }

        let dns = NEDNSSettings(servers: ipv6Enabled ? [Self.dns4, Self.dns6] : [Self.dns4])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        if vpnOptions["systemProxy"] as? Bool == true,
           let port = vpnOptions["port"] as? Int {
            let proxy = NEProxySettings()
            proxy.httpEnabled = true
            proxy.httpsEnabled = true
            proxy.httpServer = NEProxyServer(address: "127.0.0.1", port: port)
            proxy.httpsServer = NEProxyServer(address: "127.0.0.1", port: port)
            proxy.excludeSimpleHostnames = true
            proxy.exceptionList = vpnOptions["bypassDomain"] as? [String]
            settings.proxySettings = proxy
        }
        return settings
    }

    private func loadSharedState() throws -> [String: Any] {
        guard let value = UserDefaults(suiteName: Self.appGroup)?.string(forKey: Self.sharedStateKey) else {
            TunnelDiagnostics.log("PacketTunnel", "sharedState.missing")
            throw TunnelError.missingSharedState
        }
        return try decodeObject(value)
    }

    private func decodeObject(_ value: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else {
            throw TunnelError.invalidSharedState
        }
        return object
    }

    private func encodeObject(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        guard let result = String(data: data, encoding: .utf8) else {
            throw TunnelError.invalidSharedState
        }
        return result
    }
}

private enum TunnelError: LocalizedError {
    case appGroupUnavailable
    case missingSharedState
    case invalidSharedState
    case missingSetupState
    case invalidMessage
    case fileDescriptorUnavailable
    case coreStartFailed
    case coreActionFailed(String)
    case coreMessage(String)

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable: return "FlClash App Group is unavailable"
        case .missingSharedState: return "VPN settings have not been synchronized"
        case .invalidSharedState: return "VPN settings are invalid"
        case .missingSetupState: return "No active proxy profile is configured"
        case .invalidMessage: return "The application sent an invalid provider message"
        case .fileDescriptorUnavailable: return "The packet tunnel file descriptor is unavailable"
        case .coreStartFailed: return "The FlClash core failed to attach to the packet tunnel"
        case let .coreActionFailed(method): return "The FlClash core action failed: \(method)"
        case let .coreMessage(message): return message
        }
    }
}
