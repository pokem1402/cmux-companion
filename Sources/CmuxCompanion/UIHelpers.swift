import SwiftUI
import CmuxCompanionCore

extension Color {
    init(companionHex hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        switch cleaned.count {
        case 3:
            self.init(
                red: Double((value >> 8) & 0xF) / 15,
                green: Double((value >> 4) & 0xF) / 15,
                blue: Double(value & 0xF) / 15
            )
        case 6:
            self.init(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            )
        default:
            self = .accentColor
        }
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
