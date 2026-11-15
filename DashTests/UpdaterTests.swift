import Foundation
import Testing
@testable import Dash

/// Updates: which release counts as newer, and where releases come from.
struct UpdaterTests {
    @Test func comparesVersionsNumerically() {
        #expect(Updater.isNewer("0.2.0", than: "0.1.0"))
        #expect(Updater.isNewer("0.10.0", than: "0.9.3"))
        #expect(Updater.isNewer("1.0", than: "0.9.9"))
        #expect(Updater.isNewer("1.0.1", than: "1.0"))
        #expect(!Updater.isNewer("1.0.0", than: "1.0"))
        #expect(!Updater.isNewer("0.1.0", than: "0.2.0"))
        #expect(!Updater.isNewer("0.2.0-beta", than: "0.2.0"))
    }

    @Test func sourcesAreGitHubReposOrFolders() {
        #expect(Updater.parse("sessaidi/dash") == .github("sessaidi/dash"))
        #expect(Updater.parse("git@github.com:sessaidi/dash.git") == .github("sessaidi/dash"))
        #expect(Updater.parse("https://github.com/sessaidi/dash/") == .github("sessaidi/dash"))
        #expect(Updater.parse("/tmp/dash") == .local(URL(filePath: "/tmp/dash", directoryHint: .isDirectory)))
        if case .local(let url) = Updater.parse("~/code/dash") {
            #expect(url.path(percentEncoded: false).hasSuffix("/code/dash/") && !url.path().contains("~"))
        } else {
            Issue.record("expected a folder")
        }
        #expect(Updater.parse("not a source") == nil)
    }

    @Test func aLocalFolderOffersItsNewestZip() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dash-updates-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: "dist"), withIntermediateDirectories: true)
        for name in ["dist/Dash-0.9.0.zip", "dist/Dash-0.10.0.zip", "Dash-0.2.0.zip", "dist/Other-9.zip"] {
            try Data().write(to: folder.appending(path: name))
        }
        let release = try Updater.latestRelease(in: folder)
        #expect(release.version == "0.10.0" && release.asset.downloadURL.lastPathComponent == "Dash-0.10.0.zip")
        #expect(throws: UpdateError.self) { try Updater.latestRelease(in: folder.appending(path: "missing")) }
    }
}
