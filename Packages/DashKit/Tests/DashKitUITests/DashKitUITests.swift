import Testing
@testable import DashKitUI

struct ConnectionStateTests {
    @Test func tonesAndTitles() {
        #expect(ConnectionState.notConfigured.tone == .neutral)
        #expect(ConnectionState.connected("Signed in as a").title == "Signed in as a")
        #expect(ConnectionState.connected(nil).title == "Connected")
        #expect(ConnectionState.failed("401").tone == .danger)
        #expect(ConnectionState.connected(nil).isConnected && !ConnectionState.checking.isConnected)
    }
}

@Test func heatmapLevelsByQuartile() {
    let thresholds = [10.0, 20, 30]
    #expect([0, 5, 10, 15, 25, 99].map { ActivityHeatmap.level($0, thresholds: thresholds) } == [0, 1, 1, 2, 3, 4])
}
