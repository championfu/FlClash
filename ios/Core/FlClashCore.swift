import Foundation
import OSLog

// Shared by Runner and PacketTunnel. Never log action payloads or configuration
// contents: they can contain subscription tokens and proxy credentials.
enum TunnelDiagnostics {
    static let subsystem = "com.champion.flClash.vpn"

    static func log(_ category: String, _ message: String) {
        Logger(subsystem: subsystem, category: category).notice("[FlClashVPN] \(category, privacy: .public) \(message, privacy: .public)")
    }

    static func error(_ category: String, _ stage: String, _ error: Error) {
        let value = error as NSError
        let logger = Logger(subsystem: subsystem, category: category)
        logger.error("[FlClashVPN] \(category, privacy: .public) \(stage, privacy: .public) domain=\(value.domain, privacy: .public) code=\(value.code) detail=\(value.localizedDescription, privacy: .private)")
    }

    static func actionName(_ action: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(action.utf8)) as? [String: Any],
              let method = object["method"] as? String else { return "invalid" }
        switch method {
        case "initClash", "getIsInit", "setupConfig", "updateConfig", "startListener",
             "stopListener", "shutdown", "getTraffic", "getTotalTraffic", "getProxies",
             "getConnections", "startLog", "stopLog", "changeProxy", "asyncTestDelay",
             "getExternalProvider", "getExternalProviders", "updateExternalProvider":
            return method
        default: return "other"
        }
    }

    static func isFrequent(_ method: String) -> Bool {
        return ["getTraffic", "getTotalTraffic", "getConnections", "pollEvent"].contains(method)
    }

    static func stateSummary(_ state: [String: Any]) -> String {
        let setup = state["setupParams"] as? [String: Any]
        let vpn = state["vpnOptions"] as? [String: Any]
        let selectedCount = (setup?["selected-map"] as? [String: Any])?.count ?? 0
        return "setup=\(setup != nil) selectedCount=\(selectedCount) vpnOptions=\(vpn != nil) ipv6=\(vpn?["ipv6"] as? Bool == true) systemProxy=\(vpn?["systemProxy"] as? Bool == true) dnsHijacking=\(vpn?["dnsHijacking"] as? Bool != false)"
    }

    final class Span {
        private let category: String
        private let label: String
        private let started = ProcessInfo.processInfo.systemUptime
        private let quiet: Bool
        private var watchdog: DispatchWorkItem?

        init(_ category: String, _ operation: String, quiet: Bool = false) {
            self.category = category
            self.label = "\(operation) id=\(UUID().uuidString.prefix(8))"
            self.quiet = quiet
            if !quiet { log(category, "\(label) begin") }
            // Diagnostic only: this does not cancel the operation or complete a
            // NetworkExtension callback. It also fires if coreQueue is blocked.
            let label = self.label
            let pending = DispatchWorkItem {
                log(category, "\(label) pendingAfter=10s")
            }
            watchdog = pending
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: pending)
        }

        func checkpoint(_ stage: String) {
            log(category, "\(label) stage=\(stage) elapsedMs=\(elapsedMs)")
        }

        func finish(_ result: String = "ok", failed: Bool = false) {
            watchdog?.cancel()
            watchdog = nil
            if !quiet || failed || elapsedMs >= 1000 {
                log(category, "\(label) end=\(result) elapsedMs=\(elapsedMs)")
            }
        }

        private var elapsedMs: Int {
            Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        }
    }
}

enum FlClashCore {
    static func invoke(_ action: String) -> String? {
        let method = TunnelDiagnostics.actionName(action)
        let trace = TunnelDiagnostics.Span("Core", method, quiet: TunnelDiagnostics.isFrequent(method))
        guard let input = strdup(action),
              let output = FlClashInvokeAction(input) else {
            trace.finish("noResponse", failed: true)
            return nil
        }
        defer { FlClashFreeString(output) }
        let response = String(cString: output)
        if let result = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any] {
            let code = result["code"] as? Int ?? -1
            let hasMessage = !(result["data"] as? String ?? "").isEmpty
            let setupError = method == "setupConfig" && hasMessage
            let initRejected = method == "initClash" && result["data"] as? Bool == false
            trace.finish("code=\(code) setupError=\(setupError) initRejected=\(initRejected)",
                         failed: code != 0 || setupError || initRejected)
        } else {
            trace.finish("invalidResponse", failed: true)
        }
        return response
    }

    static func startTunnel(
        fileDescriptor: Int32,
        stack: String,
        address: String,
        dns: String
    ) -> Bool {
        let trace = TunnelDiagnostics.Span("Core", "startTUN fd=\(fileDescriptor)")
        guard let stackValue = strdup(stack),
              let addressValue = strdup(address),
              let dnsValue = strdup(dns) else {
            trace.finish("allocationFailed", failed: true)
            return false
        }
        let started = startTUN(nil, fileDescriptor, stackValue, addressValue, dnsValue)
        trace.finish("started=\(started)", failed: !started)
        return started
    }

    static func stopTunnel() {
        let trace = TunnelDiagnostics.Span("Core", "stopTun")
        stopTun()
        trace.finish()
    }

    static func pollEvent() -> String? {
        guard let output = FlClashPollEvent() else { return nil }
        defer { FlClashFreeString(output) }
        return String(cString: output)
    }
}
