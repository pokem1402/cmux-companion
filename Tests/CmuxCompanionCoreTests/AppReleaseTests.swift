import Foundation
import XCTest
@testable import CmuxCompanionCore

final class AppReleaseTests: XCTestCase {
    func testSemanticVersionComparisonIncludesPrereleaseRules() throws {
        let patchNine = try XCTUnwrap(AppSemanticVersion("0.1.9"))
        let patchTen = try XCTUnwrap(AppSemanticVersion("0.1.10"))
        let alpha = try XCTUnwrap(AppSemanticVersion("1.0.0-alpha"))
        let alphaOne = try XCTUnwrap(AppSemanticVersion("1.0.0-alpha.1"))
        let beta = try XCTUnwrap(AppSemanticVersion("1.0.0-beta"))
        let release = try XCTUnwrap(AppSemanticVersion("1.0.0"))

        XCTAssertLessThan(patchNine, patchTen)
        XCTAssertLessThan(alpha, alphaOne)
        XCTAssertLessThan(alphaOne, beta)
        XCTAssertLessThan(beta, release)
        XCTAssertEqual(AppSemanticVersion("v1.2.3")?.description, "1.2.3")
        XCTAssertEqual(AppSemanticVersion("1.2.3+build.4"), AppSemanticVersion("1.2.3+build.5"))
        XCTAssertNil(AppSemanticVersion("01.2.3"))
        XCTAssertNil(AppSemanticVersion("1.2.3-01"))
        XCTAssertNil(AppSemanticVersion("1.2"))
    }

    func testGitHubDecodingAndChannelSelectionRequireExactArm64Assets() throws {
        let digest = String(repeating: "a", count: 64)
        let json = #"""
        [{
          "tag_name":"v0.2.0-beta.1","name":"Beta","body":"notes",
          "draft":false,"prerelease":true,"published_at":"2026-07-19T01:02:03.456Z",
          "html_url":"https://github.com/pokem1402/cmux-companion/releases/tag/v0.2.0-beta.1",
          "assets":[
            {
              "name":"CmuxCompanion-v0.2.0-beta.1-macos-arm64.zip",
              "browser_download_url":"https://github.com/pokem1402/cmux-companion/releases/download/v0.2.0-beta.1/CmuxCompanion-v0.2.0-beta.1-macos-arm64.zip",
              "content_type":"application/zip","size":1234,"digest":"sha256:\#(digest)"
            },
            {
              "name":"CmuxCompanion-v0.2.0-beta.1-macos-arm64.zip.sha256",
              "browser_download_url":"https://github.com/pokem1402/cmux-companion/releases/download/v0.2.0-beta.1/CmuxCompanion-v0.2.0-beta.1-macos-arm64.zip.sha256"
            }
          ]
        }]
        """#
        let decoded = try JSONDecoder().decode([GitHubAppRelease].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.first?.semanticVersion, AppSemanticVersion("0.2.0-beta.1"))
        XCTAssertEqual(decoded.first?.body, "notes")
        XCTAssertNotNil(decoded.first?.publishedAt)
        XCTAssertEqual(decoded.first?.assets.first?.size, 1234)
        XCTAssertEqual(decoded.first?.assets.first?.digest, "sha256:\(digest)")

        let current = try XCTUnwrap(AppSemanticVersion("0.1.0"))
        let older = makeRelease("0.0.9")
        let equal = makeRelease("0.1.0")
        let stable = makeRelease("0.1.1")
        let preview = try XCTUnwrap(decoded.first)
        let draft = makeRelease("9.0.0", draft: true)
        let wrongArchitecture = makeRelease("8.0.0", architecture: "x86_64")

        XCTAssertNil(AppReleaseSelector.latest(
            from: [older, equal],
            newerThan: current,
            channel: .preview
        ))
        XCTAssertNil(AppReleaseSelector.latest(
            from: [draft, wrongArchitecture],
            newerThan: current,
            channel: .preview
        ))
        XCTAssertEqual(
            AppReleaseSelector.latest(
                from: [draft, preview, stable, wrongArchitecture],
                newerThan: current,
                channel: .stable
            )?.version,
            AppSemanticVersion("0.1.1")
        )
        XCTAssertEqual(
            AppReleaseSelector.latest(
                from: [stable, preview],
                newerThan: current,
                channel: .preview
            )?.version,
            AppSemanticVersion("0.2.0-beta.1")
        )
    }

    func testChecksumParsersAreStrictAboutAlgorithmAndFilename() throws {
        let digest = String(repeating: "A", count: 64)
        let filename = "CmuxCompanion-v0.1.1-macos-arm64.zip"
        let expected = try XCTUnwrap(AppUpdateChecksum(hexadecimal: digest))

        XCTAssertEqual(AppUpdateChecksum(githubDigest: "sha256:\(digest)"), expected)
        XCTAssertNil(AppUpdateChecksum(githubDigest: "sha1:\(digest)"))
        XCTAssertNil(AppUpdateChecksum(hexadecimal: String(repeating: "a", count: 63)))
        XCTAssertEqual(
            AppUpdateChecksum.parseSidecar("\(digest)  \(filename)\n", expectedFilename: filename),
            expected
        )
        XCTAssertEqual(
            AppUpdateChecksum.parseSidecar("\(digest) *\(filename)\n", expectedFilename: filename),
            expected
        )
        XCTAssertEqual(
            AppUpdateChecksum.parseSidecar("SHA256 (\(filename)) = \(digest)\n", expectedFilename: filename),
            expected
        )
        XCTAssertEqual(
            AppUpdateChecksum.parseSidecar(Data(digest.utf8), expectedFilename: filename),
            expected
        )
        XCTAssertNil(AppUpdateChecksum.parseSidecar(
            "\(digest)  another.zip\n",
            expectedFilename: filename
        ))
        XCTAssertNil(AppUpdateChecksum.parseSidecar(
            "\(digest)  \(filename)\n\(digest)  \(filename)\n",
            expectedFilename: filename
        ))
    }

    func testArchiveEntryPathPolicyRejectsTraversalAndAmbiguity() {
        XCTAssertTrue(AppUpdateArchivePolicy.isSafeEntryPath(
            "CmuxCompanion.app/Contents/MacOS/CmuxCompanion"
        ))
        XCTAssertTrue(AppUpdateArchivePolicy.isSafeEntryPath(
            "CmuxCompanion.app/Contents/Resources/"
        ))

        for unsafe in [
            "",
            "/absolute/path",
            "../escape",
            "CmuxCompanion.app/../../escape",
            "CmuxCompanion.app/./Contents",
            "CmuxCompanion.app//Contents",
            "C:/Windows/path",
            "C:\\Windows\\path",
            "CmuxCompanion.app/Contents\nEscape"
        ] {
            XCTAssertFalse(AppUpdateArchivePolicy.isSafeEntryPath(unsafe), unsafe)
        }
        XCTAssertTrue(AppUpdateArchivePolicy.allEntriesAreSafe([
            "CmuxCompanion.app/",
            "CmuxCompanion.app/Contents/Info.plist"
        ]))
        XCTAssertFalse(AppUpdateArchivePolicy.allEntriesAreSafe([
            "CmuxCompanion.app/Contents/Info.plist",
            "../escape"
        ]))
        XCTAssertFalse(AppUpdateArchivePolicy.allEntriesAreSafe([String]()))
    }

    private func makeRelease(
        _ version: String,
        architecture: String = "arm64",
        draft: Bool = false,
        prerelease: Bool = false
    ) -> GitHubAppRelease {
        let archiveName = "CmuxCompanion-v\(version)-macos-\(architecture).zip"
        let baseURL = URL(string: "https://github.com/pokem1402/cmux-companion/releases/download/v\(version)/")!
        return GitHubAppRelease(
            tagName: "v\(version)",
            draft: draft,
            prerelease: prerelease,
            assets: [
                GitHubAppReleaseAsset(
                    name: archiveName,
                    browserDownloadURL: baseURL.appendingPathComponent(archiveName)
                ),
                GitHubAppReleaseAsset(
                    name: archiveName + ".sha256",
                    browserDownloadURL: baseURL.appendingPathComponent(archiveName + ".sha256")
                )
            ]
        )
    }
}
