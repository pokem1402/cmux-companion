import Foundation

public struct CmuxRemoteEventOrder: Equatable, Sendable {
    public var bootID: String
    public var sequence: UInt64

    public init(bootID: String, sequence: UInt64) {
        self.bootID = bootID
        self.sequence = sequence
    }
}

/// Non-sensitive identity encoded by `remote-hook-bridge.sh` into fields that
/// cmux exposes on its public event stream.
public struct CmuxRemoteEventIdentity: Equatable, Sendable {
    public var surfaceID: String
    public var originalHookName: String?
    public var order: CmuxRemoteEventOrder?

    public static func isRemoteSessionID(_ sessionID: String) -> Bool {
        sessionID.hasPrefix("cmux-remote:") || sessionID.hasPrefix("remote:")
    }

    public init?(sessionID: String, payload: JSONValue) {
        let sessionMarkers = ["cmux-remote:", "remote:"]
        guard Self.isRemoteSessionID(sessionID),
              let marker = sessionMarkers.first(where: { sessionID.hasPrefix($0) }) else {
            return nil
        }
        let suffix = sessionID.dropFirst(marker.count)
        if suffix.hasPrefix("v2:") {
            let encodedAndNativeSession = suffix.dropFirst(3)
            guard let separator = encodedAndNativeSession.firstIndex(of: ":") else {
                return nil
            }
            let encodedSurface = String(encodedAndNativeSession[..<separator])
            let nativeSession = encodedAndNativeSession[encodedAndNativeSession.index(after: separator)...]
            guard !encodedSurface.isEmpty,
                  !nativeSession.isEmpty,
                  let decodedSurface = encodedSurface.removingPercentEncoding,
                  !decodedSurface.isEmpty else { return nil }
            surfaceID = decodedSurface
        } else {
            // Legacy bridge sessions did not escape `:` in a short ref such as
            // `surface:1`. Recover the full value from the managed payload when
            // available, while retaining UUID/session compatibility.
            let declaredSurface = payload.firstString(forKeys: [
                "surface_id", "surfaceId", "panel_id"
            ])
            if let declaredSurface,
               suffix.hasPrefix("\(declaredSurface):") {
                surfaceID = declaredSurface
            } else {
                guard let encodedSurface = suffix.split(separator: ":", maxSplits: 1).first,
                      !encodedSurface.isEmpty else { return nil }
                surfaceID = String(encodedSurface)
            }
        }

        originalHookName = payload.firstString(forKeys: [
            "_cmux_companion_original_event", "_remote_original_event"
        ])
        if originalHookName == nil {
            let carrierPrefix = "cmux-companion-remote-event:"
            originalHookName = payload.firstString(forKeys: ["tool_name", "toolName"])
                .flatMap { value in
                    value.hasPrefix(carrierPrefix)
                        ? String(value.dropFirst(carrierPrefix.count))
                        : nil
                }
        }

        let orderPrefix = "cmux-companion-seq:"
        if let value = payload.firstString(forKeys: ["_opencode_request_id"]),
           value.hasPrefix(orderPrefix) {
            let components = value.dropFirst(orderPrefix.count).split(separator: ":", maxSplits: 2)
            if components.count == 3, let sequence = UInt64(components[1]) {
                order = CmuxRemoteEventOrder(bootID: String(components[0]), sequence: sequence)
            } else {
                order = nil
            }
        } else {
            order = nil
        }
    }
}
