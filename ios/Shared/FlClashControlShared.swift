import AppIntents
import Foundation

enum FlClashControlShared {
    static let appGroup = "group.com.champion.flClash"
    static let vpnStateKey = "vpnIsOn"
    static let controlKind = "com.champion.flClash.control.vpn"
    static let glyphName = "FlClashGlyph"
    /// 自定义符号：按 Apple 文档必须用 Image(_:)（即 Label(_, image:)）加载，
    /// 用 systemImage: 永远查不到（那是系统符号的命名空间）。
    /// 当前先用系统符号验证链路（systemImage:），图形与自定义符号的边界问题另行处理。
    static let systemGlyphName = "lock.shield.fill"
}

/// Toggles the VPN from the Control Center control.
///
/// This type is compiled into both the app and the widget extension. Thanks to
/// `LiveActivityIntent`, the system performs it in the app process (launching
/// the app in the background when needed), which is where the tunnel can be
/// started or stopped.
@available(iOS 18.0, *)
struct ToggleVPNIntent: SetValueIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "FlClash VPN"

    @Parameter(title: "Enabled")
    var value: Bool

    init() {}

    init(value: Bool) {
        self.value = value
    }

    func perform() async throws -> some IntentResult {
        #if FLCLASH_EXTENSION
        return .result()
        #else
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            IOSService.shared.setEnabled(value) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        return .result()
        #endif
    }
}
