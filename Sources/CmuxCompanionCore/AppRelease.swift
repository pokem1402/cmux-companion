import Foundation

/// A strict Semantic Version 2.0 value. A leading `v` is accepted so GitHub
/// release tags can be parsed directly. Build metadata is retained for display
/// but, as required by SemVer, does not participate in precedence or equality.
public struct AppSemanticVersion: Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prereleaseIdentifiers: [String]
    public let buildMetadataIdentifiers: [String]

    public init?(_ value: String) {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.first == "v" || candidate.first == "V" {
            candidate.removeFirst()
        }
        guard !candidate.isEmpty else { return nil }

        let buildParts = candidate.split(
            separator: "+",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard buildParts.count <= 2 else { return nil }
        let buildIdentifiers: [String]
        if buildParts.count == 2 {
            buildIdentifiers = buildParts[1].split(
                separator: ".",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard Self.areValidIdentifiers(buildIdentifiers, rejectNumericLeadingZeroes: false) else {
                return nil
            }
        } else {
            buildIdentifiers = []
        }

        let precedenceParts = buildParts[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard precedenceParts.count <= 2 else { return nil }
        let coreParts = precedenceParts[0].split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard coreParts.count == 3,
              let major = Self.parseCoreNumber(coreParts[0]),
              let minor = Self.parseCoreNumber(coreParts[1]),
              let patch = Self.parseCoreNumber(coreParts[2]) else {
            return nil
        }

        let prereleaseIdentifiers: [String]
        if precedenceParts.count == 2 {
            prereleaseIdentifiers = precedenceParts[1].split(
                separator: ".",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard Self.areValidIdentifiers(
                prereleaseIdentifiers,
                rejectNumericLeadingZeroes: true
            ) else {
                return nil
            }
        } else {
            prereleaseIdentifiers = []
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prereleaseIdentifiers = prereleaseIdentifiers
        self.buildMetadataIdentifiers = buildIdentifiers
    }

    public var description: String {
        var result = "\(major).\(minor).\(patch)"
        if !prereleaseIdentifiers.isEmpty {
            result += "-" + prereleaseIdentifiers.joined(separator: ".")
        }
        if !buildMetadataIdentifiers.isEmpty {
            result += "+" + buildMetadataIdentifiers.joined(separator: ".")
        }
        return result
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.major == rhs.major
            && lhs.minor == rhs.minor
            && lhs.patch == rhs.patch
            && lhs.prereleaseIdentifiers == rhs.prereleaseIdentifiers
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        if lhs.prereleaseIdentifiers.isEmpty {
            return false
        }
        if rhs.prereleaseIdentifiers.isEmpty {
            return true
        }

        for (left, right) in zip(lhs.prereleaseIdentifiers, rhs.prereleaseIdentifiers) {
            if left == right { continue }
            let leftIsNumeric = Self.isASCIIInteger(left)
            let rightIsNumeric = Self.isASCIIInteger(right)
            if leftIsNumeric != rightIsNumeric {
                return leftIsNumeric
            }
            if leftIsNumeric {
                if left.utf8.count != right.utf8.count {
                    return left.utf8.count < right.utf8.count
                }
            }
            return left < right
        }
        return lhs.prereleaseIdentifiers.count < rhs.prereleaseIdentifiers.count
    }

    private static func parseCoreNumber(_ value: Substring) -> Int? {
        guard !value.isEmpty,
              value.allSatisfy({ $0.isASCII && $0.isNumber }),
              value.count == 1 || value.first != "0" else {
            return nil
        }
        return Int(value)
    }

    private static func areValidIdentifiers(
        _ identifiers: [String],
        rejectNumericLeadingZeroes: Bool
    ) -> Bool {
        guard !identifiers.isEmpty else { return false }
        return identifiers.allSatisfy { identifier in
            guard !identifier.isEmpty,
                  identifier.unicodeScalars.allSatisfy({ scalar in
                      switch scalar.value {
                      case 45, 48...57, 65...90, 97...122: return true
                      default: return false
                      }
                  }) else {
                return false
            }
            return !rejectNumericLeadingZeroes
                || !isASCIIInteger(identifier)
                || identifier.count == 1
                || identifier.first != "0"
        }
    }

    private static func isASCIIInteger(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            byte >= Character("0").asciiValue! && byte <= Character("9").asciiValue!
        }
    }
}

public struct GitHubAppReleaseAsset: Decodable, Equatable, Sendable {
    public let name: String
    public let browserDownloadURL: URL
    public let contentType: String?
    public let size: Int64
    public let digest: String?

    public init(
        name: String,
        browserDownloadURL: URL,
        contentType: String? = nil,
        size: Int64 = 0,
        digest: String? = nil
    ) {
        self.name = name
        self.browserDownloadURL = browserDownloadURL
        self.contentType = contentType
        self.size = size
        self.digest = digest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        browserDownloadURL = try container.decode(URL.self, forKey: .browserDownloadURL)
        contentType = try container.decodeIfPresent(String.self, forKey: .contentType)
        size = try container.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        digest = try container.decodeIfPresent(String.self, forKey: .digest)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case contentType = "content_type"
        case size
        case digest
    }
}

public struct GitHubAppRelease: Decodable, Equatable, Sendable {
    public let tagName: String
    public let name: String?
    public let body: String?
    public let draft: Bool
    public let prerelease: Bool
    public let htmlURL: URL?
    public let publishedAt: Date?
    public let assets: [GitHubAppReleaseAsset]

    public init(
        tagName: String,
        name: String? = nil,
        body: String? = nil,
        draft: Bool = false,
        prerelease: Bool = false,
        htmlURL: URL? = nil,
        publishedAt: Date? = nil,
        assets: [GitHubAppReleaseAsset] = []
    ) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.draft = draft
        self.prerelease = prerelease
        self.htmlURL = htmlURL
        self.publishedAt = publishedAt
        self.assets = assets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        draft = try container.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        prerelease = try container.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
        htmlURL = try container.decodeIfPresent(URL.self, forKey: .htmlURL)
        assets = try container.decodeIfPresent([GitHubAppReleaseAsset].self, forKey: .assets) ?? []

        if let published = try container.decodeIfPresent(String.self, forKey: .publishedAt) {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            publishedAt = fractional.date(from: published) ?? ISO8601DateFormatter().date(from: published)
        } else {
            publishedAt = nil
        }
    }

    public var semanticVersion: AppSemanticVersion? {
        AppSemanticVersion(tagName)
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case draft
        case prerelease
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case assets
    }
}

public enum AppUpdateChannel: String, Sendable {
    case stable
    case preview
}

public struct AvailableAppUpdate: Equatable, Sendable {
    public let version: AppSemanticVersion
    public let release: GitHubAppRelease
    public let archiveAsset: GitHubAppReleaseAsset
    public let checksumAsset: GitHubAppReleaseAsset

    public init(
        version: AppSemanticVersion,
        release: GitHubAppRelease,
        archiveAsset: GitHubAppReleaseAsset,
        checksumAsset: GitHubAppReleaseAsset
    ) {
        self.version = version
        self.release = release
        self.archiveAsset = archiveAsset
        self.checksumAsset = checksumAsset
    }
}

public enum AppReleaseSelector {
    /// Selects the highest eligible release that contains one exact archive and
    /// one exact checksum asset. This intentionally never guesses from a prefix
    /// or accepts a differently-architected build.
    public static func latest(
        from releases: [GitHubAppRelease],
        newerThan currentVersion: AppSemanticVersion,
        channel: AppUpdateChannel,
        architecture: String = "arm64"
    ) -> AvailableAppUpdate? {
        guard architecture == "arm64" else { return nil }
        var latestUpdate: AvailableAppUpdate?

        for release in releases {
            guard !release.draft,
                  let version = release.semanticVersion,
                  version > currentVersion else {
                continue
            }
            if channel == .stable,
               release.prerelease || !version.prereleaseIdentifiers.isEmpty {
                continue
            }

            let archiveName = "CmuxCompanion-v\(version.description)-macos-\(architecture).zip"
            let checksumName = archiveName + ".sha256"
            let archives = release.assets.filter { $0.name == archiveName }
            let checksums = release.assets.filter { $0.name == checksumName }
            guard archives.count == 1,
                  checksums.count == 1,
                  Self.isSecureDownloadURL(archives[0].browserDownloadURL),
                  Self.isSecureDownloadURL(checksums[0].browserDownloadURL) else {
                continue
            }

            let update = AvailableAppUpdate(
                version: version,
                release: release,
                archiveAsset: archives[0],
                checksumAsset: checksums[0]
            )
            if latestUpdate == nil || latestUpdate!.version < version {
                latestUpdate = update
            }
        }
        return latestUpdate
    }

    private static func isSecureDownloadURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil
    }
}

public struct AppUpdateChecksum: Equatable, Sendable, CustomStringConvertible {
    public let hexDigest: String

    public init?(hexadecimal value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.utf8.count == 64,
              normalized.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
              }) else {
            return nil
        }
        hexDigest = normalized
    }

    public init?(githubDigest value: String) {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard parts.count == 2,
              parts[0].lowercased() == "sha256",
              let checksum = AppUpdateChecksum(hexadecimal: String(parts[1])) else {
            return nil
        }
        self = checksum
    }

    public var description: String { hexDigest }

    public static func parseSidecar(
        _ data: Data,
        expectedFilename: String
    ) -> AppUpdateChecksum? {
        guard let contents = String(data: data, encoding: .utf8) else { return nil }
        return parseSidecar(contents, expectedFilename: expectedFilename)
    }

    public static func parseSidecar(
        _ contents: String,
        expectedFilename: String
    ) -> AppUpdateChecksum? {
        guard isSafeSidecarFilename(expectedFilename) else { return nil }
        let lines = contents.split(whereSeparator: \Character.isNewline).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        guard lines.count == 1 else { return nil }
        let line = lines[0]

        if let checksum = AppUpdateChecksum(hexadecimal: line) {
            return checksum
        }

        let bsdPrefix = "SHA256 (\(expectedFilename)) = "
        if line.hasPrefix(bsdPrefix) {
            return AppUpdateChecksum(hexadecimal: String(line.dropFirst(bsdPrefix.count)))
        }

        let fields = line.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: { $0 == " " || $0 == "\t" }
        )
        guard fields.count == 2,
              let checksum = AppUpdateChecksum(hexadecimal: String(fields[0])) else {
            return nil
        }
        var filename = String(fields[1]).trimmingCharacters(in: .whitespaces)
        if filename.first == "*" { filename.removeFirst() }
        guard filename == expectedFilename else { return nil }
        return checksum
    }

    private static func isSafeSidecarFilename(_ filename: String) -> Bool {
        !filename.isEmpty
            && filename != "."
            && filename != ".."
            && !filename.contains("/")
            && !filename.contains("\\")
            && !filename.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

public enum AppUpdateArchivePolicy {
    /// Rejects paths that an archive extractor could interpret as absolute,
    /// parent-relative, Windows-drive-relative, or structurally ambiguous.
    /// File type and symlink-target validation must still be performed after
    /// extraction because a ZIP entry name alone does not carry that evidence.
    public static func isSafeEntryPath(_ entryPath: String) -> Bool {
        guard !entryPath.isEmpty,
              !entryPath.hasPrefix("/"),
              !entryPath.contains("\\"),
              !entryPath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return false
        }

        var normalized = entryPath
        if normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        guard !normalized.isEmpty else { return false }
        let components = normalized.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return false
        }

        if let first = components.first,
           first.utf8.count >= 2 {
            let bytes = Array(first.utf8.prefix(2))
            let isDriveLetter = (bytes[0] >= 65 && bytes[0] <= 90)
                || (bytes[0] >= 97 && bytes[0] <= 122)
            if isDriveLetter && bytes[1] == 58 { return false }
        }
        return true
    }

    public static func allEntriesAreSafe<S: Sequence>(_ entries: S) -> Bool where S.Element == String {
        var foundEntry = false
        for entry in entries {
            foundEntry = true
            if !isSafeEntryPath(entry) { return false }
        }
        return foundEntry
    }
}
