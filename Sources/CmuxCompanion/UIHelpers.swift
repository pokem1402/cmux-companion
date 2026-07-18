import AppKit
import SwiftUI
import CmuxCompanionCore

struct CompanionColorPreset: Identifiable, Equatable {
    let name: String
    let hex: String

    var id: String { hex }
}

enum CompanionHexColor {
    private static let aliases: [String: String] = [
        "blue": "#0A84FF", "파랑": "#0A84FF",
        "indigo": "#5E5CE6", "남색": "#5E5CE6",
        "purple": "#BF5AF2", "보라": "#BF5AF2",
        "pink": "#FF375F", "분홍": "#FF375F",
        "red": "#FF453A", "빨강": "#FF453A",
        "orange": "#FF9F0A", "주황": "#FF9F0A",
        "yellow": "#FFD60A", "노랑": "#FFD60A",
        "lime": "#A8E063", "연두": "#A8E063",
        "green": "#30D158", "초록": "#30D158",
        "mint": "#66D4CF", "민트": "#66D4CF",
        "teal": "#40C8E0", "청록": "#40C8E0",
        "cyan": "#64D2FF", "하늘": "#64D2FF",
        "navy": "#0040DD", "짙은 파랑": "#0040DD",
        "coral": "#FF6B6B", "코랄": "#FF6B6B",
        "brown": "#AC8E68", "갈색": "#AC8E68",
        "gray": "#8E8E93", "grey": "#8E8E93", "회색": "#8E8E93",
    ]

    static func canonicalize(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let alias = aliases[trimmed.lowercased()] { return alias }

        let digits = trimmed.first == "#" ? String(trimmed.dropFirst()) : trimmed
        guard digits.count == 3 || digits.count == 6,
              digits.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57)
                      || (byte >= 65 && byte <= 70)
                      || (byte >= 97 && byte <= 102)
              }) else {
            return nil
        }
        let expanded: String
        if digits.count == 3 {
            expanded = digits.map { "\($0)\($0)" }.joined()
        } else {
            expanded = digits
        }
        return "#" + expanded.uppercased()
    }
}

enum CompanionColorPalette {
    static let presets: [CompanionColorPreset] = [
        CompanionColorPreset(name: "파랑", hex: "#0A84FF"),
        CompanionColorPreset(name: "남색", hex: "#5E5CE6"),
        CompanionColorPreset(name: "보라", hex: "#BF5AF2"),
        CompanionColorPreset(name: "분홍", hex: "#FF375F"),
        CompanionColorPreset(name: "빨강", hex: "#FF453A"),
        CompanionColorPreset(name: "주황", hex: "#FF9F0A"),
        CompanionColorPreset(name: "노랑", hex: "#FFD60A"),
        CompanionColorPreset(name: "연두", hex: "#A8E063"),
        CompanionColorPreset(name: "초록", hex: "#30D158"),
        CompanionColorPreset(name: "민트", hex: "#66D4CF"),
        CompanionColorPreset(name: "청록", hex: "#40C8E0"),
        CompanionColorPreset(name: "하늘", hex: "#64D2FF"),
        CompanionColorPreset(name: "짙은 파랑", hex: "#0040DD"),
        CompanionColorPreset(name: "코랄", hex: "#FF6B6B"),
        CompanionColorPreset(name: "갈색", hex: "#AC8E68"),
        CompanionColorPreset(name: "회색", hex: "#8E8E93"),
    ]

    static func hex(for index: Int) -> String {
        presets[index % presets.count].hex
    }
}

@MainActor
final class CompanionColorPanelCoordinator: NSObject, ObservableObject {
    private var onColorChange: ((Color) -> Void)?

    func present(initialColor: Color, onColorChange: @escaping (Color) -> Void) {
        self.onColorChange = onColorChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = NSColor(initialColor).usingColorSpace(.sRGB) ?? .systemBlue
        panel.setTarget(self)
        panel.setAction(#selector(colorDidChange(_:)))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func finish() {
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.orderOut(nil)
        onColorChange = nil
    }

    @objc private func colorDidChange(_ sender: NSColorPanel) {
        onColorChange?(Color(nsColor: sender.color))
    }
}

extension Color {
    init(companionHex hex: String) {
        guard let canonical = CompanionHexColor.canonicalize(hex),
              let value = UInt64(canonical.dropFirst(), radix: 16) else {
            self = .accentColor
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var companionHexString: String? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        guard components.allSatisfy(\.isFinite) else { return nil }
        func byte(_ component: CGFloat) -> Int {
            Int((min(max(component, 0), 1) * 255).rounded())
        }
        return String(
            format: "#%02X%02X%02X",
            byte(rgb.redComponent),
            byte(rgb.greenComponent),
            byte(rgb.blueComponent)
        )
    }
}

extension MemberRole {
    var displayName: String {
        switch self {
        case .worker: return "Worker"
        case .reviewer: return "Reviewer"
        case .pr: return "PR"
        case .other: return "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .worker: return "hammer.fill"
        case .reviewer: return "checkmark.bubble.fill"
        case .pr: return "arrow.triangle.pull"
        case .other: return "terminal.fill"
        }
    }
}

extension MemberRuntimeState {
    var displayName: String {
        switch self {
        case .running: return "작업 중"
        case .waiting: return "확인 필요"
        case .idle: return "대기"
        case .ended: return "종료"
        case .stale: return "오래된 상태"
        case .disconnected: return "연결 끊김"
        case .unknown: return "상태 미확인"
        case .error: return "오류"
        }
    }

    var color: Color {
        switch self {
        case .running: return .green
        case .waiting: return .orange
        case .idle: return .secondary
        case .ended: return .secondary.opacity(0.7)
        case .stale: return .yellow
        case .disconnected: return .red
        case .unknown: return .secondary
        case .error: return .red
        }
    }

    var symbolName: String {
        switch self {
        case .running: return "circle.fill"
        case .waiting: return "exclamationmark.circle.fill"
        case .idle: return "pause.circle.fill"
        case .ended: return "stop.circle"
        case .stale: return "clock.badge.exclamationmark"
        case .disconnected: return "wifi.slash"
        case .unknown: return "questionmark.circle"
        case .error: return "xmark.octagon.fill"
        }
    }
}

extension SetActivityStatus {
    var displayName: String {
        switch self {
        case .attention: return "확인 필요"
        case .incomplete: return "일부 멈춤"
        case .active: return "진행 중"
        case .idle: return "대기"
        }
    }

    var color: Color {
        switch self {
        case .attention: return .red
        case .incomplete: return .orange
        case .active: return .green
        case .idle: return .secondary
        }
    }

    var symbolName: String {
        switch self {
        case .attention: return "exclamationmark.triangle.fill"
        case .incomplete: return "person.2.slash.fill"
        case .active: return "bolt.fill"
        case .idle: return "moon.zzz.fill"
        }
    }
}

struct RuntimeDot: View {
    let state: MemberRuntimeState

    var body: some View {
        Image(systemName: state.symbolName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(state.color)
            .help(state.displayName)
    }
}

struct RelativeTimestamp: View {
    let date: Date?

    var body: some View {
        if let date {
            Text(date, style: .relative)
                .foregroundStyle(.tertiary)
        }
    }
}
