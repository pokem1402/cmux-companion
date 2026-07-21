import AppKit
import Combine
import Foundation

enum PopoverSizePreset: String, CaseIterable, Identifiable {
    case compact
    case standard
    case large

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: return "작게"
        case .standard: return "기본"
        case .large: return "크게"
        }
    }

    var size: NSSize {
        switch self {
        case .compact: return NSSize(width: 380, height: 520)
        case .standard: return NSSize(width: 430, height: 640)
        case .large: return NSSize(width: 560, height: 760)
        }
    }
}

enum PopoverLayoutMetrics {
    static let defaultSize = PopoverSizePreset.standard.size
    static let minimumSize = NSSize(width: 380, height: 480)
    static let maximumSize = NSSize(width: 720, height: 840)

    static func clamped(width: CGFloat, height: CGFloat) -> NSSize {
        NSSize(
            width: clamped(
                width,
                minimum: minimumSize.width,
                maximum: maximumSize.width,
                fallback: defaultSize.width
            ),
            height: clamped(
                height,
                minimum: minimumSize.height,
                maximum: maximumSize.height,
                fallback: defaultSize.height
            )
        )
    }

    private static func clamped(
        _ value: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat,
        fallback: CGFloat
    ) -> CGFloat {
        guard value.isFinite else { return fallback }
        return min(maximum, max(minimum, value))
    }
}

@MainActor
final class PopoverLayoutSettings: ObservableObject {
    /// The effective size presented on the current screen. Width and height
    /// publish atomically so presets cannot animate through an intermediate
    /// old-width/new-height combination.
    @Published private(set) var size: NSSize
    @Published private(set) var screenMaximumSize = PopoverLayoutMetrics.maximumSize

    private static let widthKey = "companionPopoverWidth"
    private static let heightKey = "companionPopoverHeight"
    private let defaults: UserDefaults
    private var preferredSize: NSSize

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedWidth = defaults.object(forKey: Self.widthKey) as? NSNumber
        let storedHeight = defaults.object(forKey: Self.heightKey) as? NSNumber
        let restoredSize = PopoverLayoutMetrics.clamped(
            width: storedWidth.map(CGFloat.init(truncating:)) ?? PopoverLayoutMetrics.defaultSize.width,
            height: storedHeight.map(CGFloat.init(truncating:)) ?? PopoverLayoutMetrics.defaultSize.height
        )
        preferredSize = restoredSize
        size = restoredSize
    }

    var width: CGFloat { size.width }
    var height: CGFloat { size.height }
    var preferredSizeForTesting: NSSize { preferredSize }

    func setWidth(_ value: CGFloat) {
        setPreferredSize(width: value, height: preferredSize.height)
    }

    func setHeight(_ value: CGFloat) {
        setPreferredSize(width: preferredSize.width, height: value)
    }

    func apply(_ preset: PopoverSizePreset) {
        setPreferredSize(width: preset.size.width, height: preset.size.height)
    }

    /// Applies a temporary display constraint without overwriting the user's
    /// preferred size. Returning to a larger monitor restores that preference.
    func updateScreenMaximum(maximumWidth: CGFloat, maximumHeight: CGFloat) {
        let maximum = NSSize(
            width: min(
                PopoverLayoutMetrics.maximumSize.width,
                max(PopoverLayoutMetrics.minimumSize.width, maximumWidth)
            ),
            height: min(
                PopoverLayoutMetrics.maximumSize.height,
                max(PopoverLayoutMetrics.minimumSize.height, maximumHeight)
            )
        )
        if screenMaximumSize != maximum {
            screenMaximumSize = maximum
        }
        updatePresentedSize()
    }

    private func setPreferredSize(width: CGFloat, height: CGFloat) {
        let preferred = PopoverLayoutMetrics.clamped(width: width, height: height)
        guard preferred != preferredSize else { return }
        preferredSize = preferred
        defaults.set(Double(preferred.width), forKey: Self.widthKey)
        defaults.set(Double(preferred.height), forKey: Self.heightKey)
        updatePresentedSize()
    }

    private func updatePresentedSize() {
        let presented = NSSize(
            width: min(preferredSize.width, screenMaximumSize.width),
            height: min(preferredSize.height, screenMaximumSize.height)
        )
        if size != presented {
            size = presented
        }
    }
}
