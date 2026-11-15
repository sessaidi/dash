import Testing
@testable import Dash

/// Updates: which release counts as newer.
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
}
