import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct VPNStateProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        UserDefaults(suiteName: FlClashControlShared.appGroup)?
            .bool(forKey: FlClashControlShared.vpnStateKey) ?? false
    }
}

@available(iOS 18.0, *)
struct VPNToggleControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: FlClashControlShared.controlKind,
            provider: VPNStateProvider()
        ) { isOn in
            ControlWidgetToggle(
                "FlClash",
                isOn: isOn,
                action: ToggleVPNIntent()
            ) { isOn in
                // 自定义符号：按 Apple《Configuring and displaying symbol images in your UI》
                // 必须用 image:（Image(_:) 按资源名，自定义符号专用通道）；systemImage: 只查系统符号。
                Label(
                    isOn ? "On" : "Off",
                    image: FlClashControlShared.glyphName
                )
            }
            .tint(Color(red: 0.376, green: 0.376, blue: 0.941))
        }
        .displayName("FlClash VPN")
        .description("Turn the FlClash VPN on or off.")
    }
}
