import AppKit
import Combine
import CryptoKit
import Foundation
import CmuxCompanionCore

enum AppUpdatePhase: Equatable {
    case idle
    case checking
    case upToDate
    case available
    case downloading
    case installing
    case failed(String)
}

struct StagedAppUpdate: Sendable {
    let update: AvailableAppUpdate
    let appURL: URL
    let stagingDirectory: URL
}

enum AppUpdateError: LocalizedError {
    case invalidInstalledVersion(String)
    case invalidResponse
    case httpStatus(Int)
    case responseTooLarge
    case releaseMetadataInvalid(String)
    case unsafeDownloadURL
    case assetSizeMismatch
    case missingGitHubDigest
    case checksumMismatch
    case unsafeArchive
    case extractedBundleMissing
    case extractedBundleInvalid(String)
    case selfInstallUnavailable(String)
    case installerLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidInstalledVersion(let value):
            return "설치된 앱 버전을 해석할 수 없습니다: \(value)"
        case .invalidResponse:
            return "GitHub가 올바른 응답을 반환하지 않았습니다."
        case .httpStatus(let status):
            return "GitHub 요청이 HTTP \(status)로 실패했습니다."
        case .responseTooLarge:
            return "업데이트 응답이 허용된 크기를 초과했습니다."
        case .releaseMetadataInvalid(let detail):
            return "업데이트 메타데이터가 올바르지 않습니다: \(detail)"
        case .unsafeDownloadURL:
            return "허용되지 않은 위치의 업데이트 파일입니다."
        case .assetSizeMismatch:
            return "다운로드한 파일 크기가 GitHub 메타데이터와 다릅니다."
        case .missingGitHubDigest:
            return "GitHub SHA-256 digest가 없는 업데이트는 설치할 수 없습니다."
        case .checksumMismatch:
            return "업데이트 파일의 SHA-256 검증에 실패했습니다."
        case .unsafeArchive:
            return "업데이트 ZIP에 안전하지 않은 경로나 파일이 포함되어 있습니다."
        case .extractedBundleMissing:
            return "업데이트 ZIP에서 CmuxCompanion.app을 찾지 못했습니다."
        case .extractedBundleInvalid(let detail):
            return "업데이트 앱 검증에 실패했습니다: \(detail)"
        case .selfInstallUnavailable(let detail):
            return "현재 위치에서는 자동 교체할 수 없습니다: \(detail)"
        case .installerLaunchFailed(let detail):
            return "업데이트 설치 프로그램을 시작하지 못했습니다: \(detail)"
        }
    }
}

actor GitHubAppUpdateClient {
    private static let repositoryOwner = "pokem1402"
    private static let repositoryName = "cmux-companion"
    private static let maximumMetadataBytes = 5 * 1_024 * 1_024
    private static let maximumArchiveBytes: Int64 = 100 * 1_024 * 1_024
    private static let maximumExtractedBytes: Int64 = 300 * 1_024 * 1_024
    private static let maximumArchiveEntries = 5_000

    private let session: URLSession
    private let fileManager: FileManager
    private let cacheRoot: URL

    init(
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        cacheRoot: URL? = nil
    ) {
        self.session = session
        self.fileManager = fileManager
        self.cacheRoot = cacheRoot
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CmuxCompanion/Updates", isDirectory: true)
    }

    func latestUpdate(
        newerThan currentVersion: AppSemanticVersion,
        channel: AppUpdateChannel,
        architecture: String
    ) async throws -> AvailableAppUpdate? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(Self.repositoryOwner)/\(Self.repositoryName)/releases"
        components.queryItems = [URLQueryItem(name: "per_page", value: "20")]
        guard let url = components.url else { throw AppUpdateError.invalidResponse }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CmuxCompanion-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let data = try await responseData(for: request, maximumBytes: Self.maximumMetadataBytes)
        let releases: [GitHubAppRelease]
        do {
            releases = try JSONDecoder().decode([GitHubAppRelease].self, from: data)
        } catch {
            throw AppUpdateError.releaseMetadataInvalid(error.localizedDescription)
        }
        return AppReleaseSelector.latest(
            from: releases,
            newerThan: currentVersion,
            channel: channel,
            architecture: architecture
        )
    }

    /// A successfully staged update must survive until the external installer
    /// copies it. The next launched app can then remove every old staging tree;
    /// failed staging attempts are removed immediately in `stage` below.
    func discardPreviousStagingDirectories() {
        guard let items = try? fileManager.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for item in items {
            try? fileManager.removeItem(at: item)
        }
    }

    func discardStagingDirectory(_ directory: URL) {
        let standardizedDirectory = directory.standardizedFileURL
        guard standardizedDirectory.deletingLastPathComponent() == cacheRoot.standardizedFileURL else {
            return
        }
        try? fileManager.removeItem(at: standardizedDirectory)
    }

    func stage(
        _ update: AvailableAppUpdate,
        currentBuildNumber: Int,
        expectedArchitecture: String
    ) async throws -> StagedAppUpdate {
        try validate(asset: update.archiveAsset, tagName: update.release.tagName)
        try validate(asset: update.checksumAsset, tagName: update.release.tagName)
        guard update.archiveAsset.size > 0,
              update.archiveAsset.size <= Self.maximumArchiveBytes else {
            throw AppUpdateError.releaseMetadataInvalid("archive size")
        }

        let stagingDirectory = cacheRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        var preserveForInstaller = false
        defer {
            if !preserveForInstaller {
                try? fileManager.removeItem(at: stagingDirectory)
            }
        }
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let archiveURL = stagingDirectory.appendingPathComponent(update.archiveAsset.name)
        let (temporaryURL, response) = try await session.download(from: update.archiveAsset.browserDownloadURL)
        try validate(response: response)
        try fileManager.moveItem(at: temporaryURL, to: archiveURL)

        let attributes = try fileManager.attributesOfItem(atPath: archiveURL.path)
        let downloadedSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard downloadedSize == update.archiveAsset.size else {
            throw AppUpdateError.assetSizeMismatch
        }

        var checksumRequest = URLRequest(url: update.checksumAsset.browserDownloadURL)
        checksumRequest.cachePolicy = .reloadIgnoringLocalCacheData
        checksumRequest.timeoutInterval = 20
        checksumRequest.setValue("CmuxCompanion-Updater", forHTTPHeaderField: "User-Agent")
        let sidecarData = try await responseData(for: checksumRequest, maximumBytes: 64 * 1_024)
        guard let sidecarChecksum = AppUpdateChecksum.parseSidecar(
            sidecarData,
            expectedFilename: update.archiveAsset.name
        ) else {
            throw AppUpdateError.releaseMetadataInvalid("SHA-256 sidecar")
        }
        guard let digestValue = update.archiveAsset.digest,
              let githubChecksum = AppUpdateChecksum(githubDigest: digestValue) else {
            throw AppUpdateError.missingGitHubDigest
        }
        let downloadedChecksum = try await Task.detached(priority: .utility) {
            try Self.sha256(of: archiveURL)
        }.value
        guard downloadedChecksum == githubChecksum,
              downloadedChecksum == sidecarChecksum else {
            throw AppUpdateError.checksumMismatch
        }

        let zipInfo = CmuxProcessRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/zipinfo", isDirectory: false)
        )
        let listing = try await zipInfo.run(arguments: ["-1", archiveURL.path])
        let entries = listing.stdout
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        guard !entries.isEmpty,
              entries.count <= Self.maximumArchiveEntries,
              AppUpdateArchivePolicy.allEntriesAreSafe(entries) else {
            throw AppUpdateError.unsafeArchive
        }
        let detailedListing = try await zipInfo.run(arguments: ["-l", archiveURL.path])
        try validateDetailedArchiveListing(
            detailedListing.stdout,
            expectedEntryCount: entries.count
        )

        let extractionDirectory = stagingDirectory.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(
            at: extractionDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let ditto = CmuxProcessRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto", isDirectory: false)
        )
        _ = try await ditto.run(arguments: ["-x", "-k", archiveURL.path, extractionDirectory.path])
        try validateExtractedTree(extractionDirectory)

        let rootItems = try fileManager.contentsOfDirectory(
            at: extractionDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        guard rootItems.count == 1,
              rootItems[0].lastPathComponent == "CmuxCompanion.app" else {
            throw AppUpdateError.extractedBundleMissing
        }
        let candidate = rootItems[0]
        try await validateCandidate(
            candidate,
            update: update,
            currentBuildNumber: currentBuildNumber,
            expectedArchitecture: expectedArchitecture
        )
        preserveForInstaller = true
        return StagedAppUpdate(
            update: update,
            appURL: candidate,
            stagingDirectory: stagingDirectory
        )
    }

    private func responseData(for request: URLRequest, maximumBytes: Int) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        guard data.count <= maximumBytes else { throw AppUpdateError.responseTooLarge }
        return data
    }

    private func validate(response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw AppUpdateError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw AppUpdateError.httpStatus(response.statusCode)
        }
    }

    private func validate(asset: GitHubAppReleaseAsset, tagName: String) throws {
        let assetURL = asset.browserDownloadURL
        let expectedPath = "/\(Self.repositoryOwner)/\(Self.repositoryName)"
            + "/releases/download/\(tagName)/\(asset.name)"
        guard assetURL.scheme?.lowercased() == "https",
              assetURL.host?.lowercased() == "github.com",
              assetURL.port == nil,
              assetURL.user == nil,
              assetURL.password == nil,
              assetURL.query == nil,
              assetURL.fragment == nil,
              assetURL.path == expectedPath else {
            throw AppUpdateError.unsafeDownloadURL
        }
    }

    private func validateExtractedTree(_ root: URL) throws {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isRegularFileKey,
            .fileSizeKey,
        ]
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw AppUpdateError.unsafeArchive
        }
        var totalSize: Int64 = 0
        while let item = enumerator.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw AppUpdateError.unsafeArchive }
            guard values.isRegularFile == true || values.isDirectory == true else {
                throw AppUpdateError.unsafeArchive
            }
            if values.isRegularFile == true {
                totalSize += Int64(values.fileSize ?? 0)
                guard totalSize <= Self.maximumExtractedBytes else {
                    throw AppUpdateError.unsafeArchive
                }
            }
        }
        if enumerationError != nil {
            throw AppUpdateError.unsafeArchive
        }
    }

    /// `zipinfo -1` proves path safety, while this long listing rejects
    /// symlinks/special files and ZIP bombs before `ditto` extracts anything.
    private func validateDetailedArchiveListing(
        _ listing: String,
        expectedEntryCount: Int
    ) throws {
        var entryCount = 0
        var totalUncompressedSize: Int64 = 0
        for line in listing.split(whereSeparator: \Character.isNewline) {
            guard let marker = line.first,
                  marker == "-" || marker == "d" || marker == "l"
                    || marker == "b" || marker == "c" || marker == "p" || marker == "s" else {
                continue
            }
            entryCount += 1
            guard marker == "-" || marker == "d" else {
                throw AppUpdateError.unsafeArchive
            }
            let fields = line.split(whereSeparator: \Character.isWhitespace)
            guard fields.count >= 4, let size = Int64(fields[3]), size >= 0 else {
                throw AppUpdateError.unsafeArchive
            }
            totalUncompressedSize += size
            guard totalUncompressedSize <= Self.maximumExtractedBytes else {
                throw AppUpdateError.unsafeArchive
            }
        }
        guard entryCount == expectedEntryCount else {
            throw AppUpdateError.unsafeArchive
        }
    }

    private func validateCandidate(
        _ candidate: URL,
        update: AvailableAppUpdate,
        currentBuildNumber: Int,
        expectedArchitecture: String
    ) async throws {
        let infoURL = candidate.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        let infoData = try Data(contentsOf: infoURL, options: .mappedIfSafe)
        guard let plist = try PropertyListSerialization.propertyList(
            from: infoData,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw AppUpdateError.extractedBundleInvalid("Info.plist")
        }
        guard plist["CFBundleIdentifier"] as? String == "dev.cmuxcompanion.app" else {
            throw AppUpdateError.extractedBundleInvalid("bundle identifier")
        }
        guard plist["CFBundleExecutable"] as? String == "CmuxCompanion",
              plist["CFBundlePackageType"] as? String == "APPL" else {
            throw AppUpdateError.extractedBundleInvalid("bundle executable or package type")
        }
        guard let versionText = plist["CFBundleShortVersionString"] as? String,
              let candidateVersion = AppSemanticVersion(versionText),
              candidateVersion == update.version else {
            throw AppUpdateError.extractedBundleInvalid("release version")
        }
        let buildText = plist["CFBundleVersion"] as? String
        guard let buildText, let candidateBuild = Int(buildText), candidateBuild > currentBuildNumber else {
            throw AppUpdateError.extractedBundleInvalid("build number")
        }

        let executable = candidate
            .appendingPathComponent("Contents/MacOS/CmuxCompanion", isDirectory: false)
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw AppUpdateError.extractedBundleInvalid("main executable")
        }
        let codesign = CmuxProcessRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign", isDirectory: false)
        )
        _ = try await codesign.run(arguments: ["--verify", "--deep", "--strict", candidate.path])

        let lipo = CmuxProcessRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/lipo", isDirectory: false)
        )
        let architecture = try await lipo.run(arguments: ["-archs", executable.path])
        let supported = Set(architecture.stdout.split(whereSeparator: \Character.isWhitespace).map(String.init))
        guard supported.contains(expectedArchitecture) else {
            throw AppUpdateError.extractedBundleInvalid("CPU architecture")
        }
    }

    private static func sha256(of fileURL: URL) throws -> AppUpdateChecksum {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let value = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard let checksum = AppUpdateChecksum(hexadecimal: value) else {
            throw AppUpdateError.checksumMismatch
        }
        return checksum
    }
}

@MainActor
final class AppUpdateController: ObservableObject {
    @Published private(set) var phase: AppUpdatePhase = .idle
    @Published private(set) var availableUpdate: AvailableAppUpdate?

    private static let automaticCheckInterval: TimeInterval = 24 * 60 * 60
    private static let firstCheckDelay: TimeInterval = 10
    private static let lastCheckKey = "CmuxCompanionLastGitHubUpdateCheck"

    private let client: GitHubAppUpdateClient
    private let bundle: Bundle
    private let defaults: UserDefaults
    private var automaticTask: Task<Void, Never>?
    private var installerProcess: Process?

    init(
        client: GitHubAppUpdateClient = GitHubAppUpdateClient(),
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.bundle = bundle
        self.defaults = defaults
    }

    var currentVersionText: String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "개발 빌드"
    }

    var currentBuildNumber: Int {
        Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    var updateVersionText: String? {
        availableUpdate.map { $0.version.description }
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    var canInstallInPlace: Bool {
        selfInstallProblem == nil
    }

    var releasePageURL: URL? {
        availableUpdate?.release.htmlURL
    }

    func start() {
        guard automaticTask == nil else { return }
        automaticTask = Task { [weak self] in
            guard let self else { return }
            await self.client.discardPreviousStagingDirectories()
            while !Task.isCancelled {
                let delay = self.delayUntilNextAutomaticCheck()
                do {
                    try await Task.sleep(nanoseconds: Self.nanoseconds(delay))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard self.isAutomaticCheckDue() else { continue }
                await self.checkForUpdates(manual: false)
            }
        }
    }

    func stop() {
        automaticTask?.cancel()
        automaticTask = nil
    }

    func checkForUpdates(manual: Bool = true) async {
        guard !isBusy else { return }
        let rawVersion = currentVersionText
        guard let currentVersion = AppSemanticVersion(rawVersion) else {
            if manual { phase = .failed(AppUpdateError.invalidInstalledVersion(rawVersion).localizedDescription) }
            return
        }
        let channelText = bundle.object(forInfoDictionaryKey: "CmuxCompanionUpdateChannel") as? String
        let channel = AppUpdateChannel(rawValue: channelText ?? "preview") ?? .preview
        phase = .checking
        defaults.set(Date(), forKey: Self.lastCheckKey)
        do {
            let update = try await client.latestUpdate(
                newerThan: currentVersion,
                channel: channel,
                architecture: Self.currentArchitecture
            )
            availableUpdate = update
            if update != nil {
                phase = .available
            } else {
                phase = manual ? .upToDate : .idle
            }
        } catch {
            if manual {
                phase = .failed(error.localizedDescription)
            } else {
                phase = .idle
                NSLog("Cmux Companion automatic update check failed: %@", error.localizedDescription)
            }
        }
    }

    func downloadAndInstall() async {
        guard !isBusy, let update = availableUpdate else { return }
        if let problem = selfInstallProblem {
            phase = .failed(AppUpdateError.selfInstallUnavailable(problem).localizedDescription)
            return
        }
        phase = .downloading
        var stagedUpdate: StagedAppUpdate?
        do {
            let staged = try await client.stage(
                update,
                currentBuildNumber: currentBuildNumber,
                expectedArchitecture: Self.currentArchitecture
            )
            stagedUpdate = staged
            phase = .installing
            try launchInstaller(for: staged)
        } catch {
            if let stagedUpdate {
                await client.discardStagingDirectory(stagedUpdate.stagingDirectory)
            }
            phase = .failed(error.localizedDescription)
        }
    }

    func openReleasePage() {
        guard let releasePageURL else { return }
        NSWorkspace.shared.open(releasePageURL)
    }

    func dismissStatus() {
        if !isBusy {
            phase = availableUpdate == nil ? .idle : .available
        }
    }

    private var selfInstallProblem: String? {
        let appURL = bundle.bundleURL.standardizedFileURL
        guard appURL.pathExtension.lowercased() == "app",
              appURL.lastPathComponent == "CmuxCompanion.app" else {
            return "앱을 Applications 폴더로 옮긴 뒤 다시 실행하세요."
        }
        guard !appURL.path.contains("/AppTranslocation/") else {
            return "App Translocation 상태입니다. 앱을 Applications 폴더로 옮겨야 합니다."
        }
        let parent = appURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            return "설치 폴더에 쓰기 권한이 없습니다."
        }
        let script = appURL.appendingPathComponent(
            "Contents/Resources/scripts/install-local.sh",
            isDirectory: false
        )
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            return "번들에 업데이트 설치 도구가 없습니다."
        }
        return nil
    }

    private func launchInstaller(for staged: StagedAppUpdate) throws {
        let currentApp = bundle.bundleURL.standardizedFileURL
        let installRoot = currentApp.deletingLastPathComponent()
        let script = currentApp.appendingPathComponent(
            "Contents/Resources/scripts/install-local.sh",
            isDirectory: false
        )
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash", isDirectory: false)
        process.arguments = [script.path, "--replace", "--launch"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CMUX_COMPANION_SOURCE_APP": staged.appURL.path,
            "CMUX_COMPANION_INSTALL_DIR": installRoot.path,
            "CMUX_COMPANION_RUNNING_PID": String(ProcessInfo.processInfo.processIdentifier),
        ]) { _, value in value }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] terminated in
            let data = try? errorPipe.fileHandleForReading.readToEnd()
            let detail = data.map {
                String(decoding: $0, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.client.discardStagingDirectory(staged.stagingDirectory)
                self.installerProcess = nil
                if terminated.terminationStatus != 0 {
                    let message = detail?.isEmpty == false
                        ? detail!
                        : "종료 상태 \(terminated.terminationStatus)"
                    self.phase = .failed(AppUpdateError.installerLaunchFailed(message).localizedDescription)
                } else {
                    // Normally the installer has already stopped this process.
                    // If path-based process discovery missed it, do not leave
                    // the old executable alive beside the relaunched update.
                    NSApp.terminate(nil)
                }
            }
        }
        do {
            try process.run()
        } catch {
            throw AppUpdateError.installerLaunchFailed(error.localizedDescription)
        }
        installerProcess = process
    }

    private func delayUntilNextAutomaticCheck(now: Date = Date()) -> TimeInterval {
        guard let lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date else {
            return Self.firstCheckDelay
        }
        let elapsed = now.timeIntervalSince(lastCheck)
        return max(Self.firstCheckDelay, Self.automaticCheckInterval - elapsed)
    }

    private func isAutomaticCheckDue(now: Date = Date()) -> Bool {
        guard let lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date else {
            return true
        }
        return now.timeIntervalSince(lastCheck) >= Self.automaticCheckInterval
    }

    private static func nanoseconds(_ interval: TimeInterval) -> UInt64 {
        UInt64(max(0, min(interval, 7 * 24 * 60 * 60)) * 1_000_000_000)
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
