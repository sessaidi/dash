import CoreGraphics
import Foundation
import Testing
@testable import Dash

/// The Swift port of Codex's Dashii runtime must match core.mjs.
struct DashiiTests {
    private let assets = DashiiAssets(bundle: .main)

    @Test func bundledAssetsLoad() throws {
        #expect(assets.isLoaded)
        let rig = try #require(assets.rig)
        #expect(rig.bones.count == 14)
        #expect(rig.attachments.count == 13)
        let clips = try #require(assets.clips)
        #expect(Set(clips.clips.keys) == Set(DashiiClip.allCases.map(\.rawValue)))
        // Every region the rig draws is in the atlas.
        let used = Set(rig.attachments.map(\.region)).union(rig.directions.head.values).union(rig.directions.torso.values).union(["eye"])
        #expect(used.isSubset(of: Set(assets.regions.keys)))
    }

    @Test func sampleTrackInterpolatesAndHoldsEnds() {
        let keys: [[Double]] = [[0, 0], [1, 10], [3, -10]]
        #expect(DashiiMath.sampleTrack(keys, at: -1) == 0)
        #expect(DashiiMath.sampleTrack(keys, at: 0.5) == 5)
        #expect(DashiiMath.sampleTrack(keys, at: 2) == 0)
        #expect(DashiiMath.sampleTrack(keys, at: 9) == -10)
        #expect(DashiiMath.sampleTrack([], at: 1) == 0)
    }

    @Test func splineKeysPassThroughKeysWithoutOvershootingFlatEnds() {
        let keys: [[Double]] = [[0, 0], [1, 10], [2, 0]]
        #expect(DashiiMath.sampleTrackSmooth(keys, at: 1, loop: false, duration: 2) == 10)
        #expect(DashiiMath.sampleTrackSmooth(keys, at: 0, loop: false, duration: 2) == 0)
        // Open ends ease out of the first key; a looped peak has flat tangents at both keys.
        let open = DashiiMath.sampleTrackSmooth(keys, at: 0.5, loop: false, duration: 2)
        #expect(open > 5 && open < 10)
        #expect(abs(DashiiMath.sampleTrackSmooth(keys, at: 0.5, loop: true, duration: 2) - 5) < 1e-9)
    }

    @Test func viewHysteresisHoldsNearThresholds() {
        #expect(DashiiMath.view(forYaw: 24, current: .front) == .front)
        #expect(DashiiMath.view(forYaw: 30, current: .front) == .threequarter)
        #expect(DashiiMath.view(forYaw: 19, current: .threequarter) == .threequarter)
        #expect(DashiiMath.view(forYaw: 15, current: .threequarter) == .front)
    }

    @Test func loopingClipsWrapAndOthersClamp() {
        #expect(DashiiMath.clipTime(3.5, duration: 3, loop: true) == 0.5)
        #expect(abs(DashiiMath.clipTime(-0.5, duration: 3, loop: true) - 2.5) < 1e-9)
        #expect(DashiiMath.clipTime(5, duration: 2, loop: false) == 2)
    }

    @Test func blendTreatsMissingPropertiesAsZero() {
        let pose = DashiiMath.blend(["head": ["rotation": 10]], ["head": ["y": 4], "torso": ["x": 2]], 0.5)
        #expect(pose["head"]?["rotation"] == 5)
        #expect(pose["head"]?["y"] == 2)
        #expect(pose["torso"]?["x"] == 1)
    }

    @Test func worldBonesRotateChildrenAroundParents() {
        let bones = [DashiiRig.Bone(name: "a", parent: nil, x: 10, y: 0),
                     DashiiRig.Bone(name: "b", parent: "a", x: 0, y: 20)]
        let world = DashiiMath.worldBones(bones, pose: ["a": ["rotation": 90]])
        // b hangs 20 below a; a turned 90° clockwise (y down) swings it to the left.
        let b = try! #require(world["b"])
        #expect(abs(b.x - -10) < 1e-9)
        #expect(abs(b.y - 0) < 1e-9)
        #expect(b.rotation == 90)
    }

    @Test func inverseKinematicsPutsTheHandOnTheGoal() throws {
        let rig = try #require(assets.rig)
        let goal = CGPoint(x: -60, y: -60)
        var pose: DashiiPose = [:]
        let shoulder = try #require(DashiiMath.worldBones(rig.bones, pose: pose)["upperL"])
        let arm = DashiiMath.solveIK(from: CGPoint(x: shoulder.x, y: shoulder.y), to: goal, upper: 32, lower: 30, bend: -1)
        pose["upperL"] = ["rotation": arm.upper]
        pose["foreL"] = ["rotation": arm.lower]
        let hand = try #require(DashiiMath.worldBones(rig.bones, pose: pose)["handL"])
        #expect(hypot(hand.x - goal.x, hand.y - goal.y) < 0.01)
    }

    @Test func gazeIsClampedAndViewsFollowYaw() {
        let far = DashiiMath.gaze(cursor: CGPoint(x: 2000, y: 2000), head: .zero)
        #expect(far == DashiiMath.Gaze(yaw: 60, pitch: 22, eyeX: 8, eyeY: 5))
        #expect(DashiiMath.view(forYaw: 10) == .front)
        #expect(DashiiMath.view(forYaw: -30) == .threequarter)
        #expect(DashiiMath.view(forYaw: 60) == .profile)
        #expect(DashiiMath.view(forYaw: 150) == .back)
    }

    @Test func perchesOnTheTopEdgeWithRoomAbove() {
        let viewport = CGSize(width: 1600, height: 1000)
        let window = CGRect(x: 300, y: 400, width: 800, height: 400)
        let place = DashiiPlacement.compute(state: .idle, time: 0, target: window, viewport: viewport)
        #expect(place.visible && place.edge == .top && !place.contact)
        #expect(place.root == CGPoint(x: 405, y: 374))
        #expect(place.contacts.map(\.goal) == [CGPoint(x: 371, y: 400), CGPoint(x: 439, y: 400)])
    }

    @Test func perchesInsideTheSideEdgeWhenTheWindowIsNearTheTop() {
        let viewport = CGSize(width: 1600, height: 1000)
        let place = DashiiPlacement.compute(state: .idle, time: 0, target: CGRect(x: 0, y: 30, width: 1600, height: 900), viewport: viewport)
        #expect(place.edge == .right)
        #expect(place.root == CGPoint(x: 1508, y: 195))
    }

    @Test func climbsInFromTheRightAndJumpsOffTheBottom() {
        let viewport = CGSize(width: 1600, height: 1000)
        let window = CGRect(x: 300, y: 400, width: 800, height: 400)
        let start = DashiiPlacement.compute(state: .enter, time: 0, target: window, viewport: viewport)
        #expect(start.root.x == 1780 && !start.contact)
        let pulling = DashiiPlacement.compute(state: .enter, time: 2, target: window, viewport: viewport)
        #expect(pulling.contact && pulling.root.x == 405)
        let done = DashiiPlacement.compute(state: .enter, time: 3, target: window, viewport: viewport)
        #expect(done.root == CGPoint(x: 405, y: 374))
        #expect(!DashiiPlacement.compute(state: .exit, time: 2.1, target: window, viewport: viewport).visible)
        #expect(!DashiiPlacement.compute(state: .idle, time: 0, target: .zero, viewport: viewport).visible)
    }

    @Test func animatorCrossFadesIntoTheNextClip() throws {
        let clips = try #require(assets.clips)
        var animator = DashiiAnimator(clips: clips)
        animator.play(.thinking, at: 0)
        animator.play(.idle, at: 10)
        let thinking = DashiiMath.sample(try #require(clips.clips["thinking"]), at: 10)
        let blended = animator.pose(at: 10)
        // At the switch the pose is still the previous clip's.
        #expect(abs((blended["upperR"]?["rotation"] ?? 0) - (thinking["upperR"]?["rotation"] ?? 0)) < 1e-6)
        let settled = animator.pose(at: 10.5)
        let idle = DashiiMath.sample(try #require(clips.clips["idle"]), at: 0.5)
        #expect(abs((settled["upperR"]?["rotation"] ?? 0) - (idle["upperR"]?["rotation"] ?? 0)) < 1e-6)
    }

    @Test func picksTheFrontmostOrdinaryWindowOfTheApp() {
        func window(_ id: Int, pid: Int, layer: Int = 0, _ rect: CGRect) -> [String: Any] {
            [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
             kCGWindowBounds as String: rect.dictionaryRepresentation as NSDictionary]
        }
        let list = [window(1, pid: 7, layer: 3, CGRect(x: 0, y: 0, width: 500, height: 500)), // a floating panel
                    window(2, pid: 8, CGRect(x: 0, y: 0, width: 900, height: 700)), // another app
                    window(3, pid: 7, CGRect(x: 0, y: 0, width: 100, height: 40)), // too small
                    window(4, pid: 7, CGRect(x: 50, y: 60, width: 900, height: 700))]
        #expect(FrontWindow.pick(from: list, pid: 7) == FrontWindow(id: 4, pid: 7, frame: CGRect(x: 50, y: 60, width: 900, height: 700)))
        #expect(FrontWindow.pick(from: list, pid: 9) == nil)
        #expect(FrontWindow.pick(from: list, pid: 7, allowed: [2]) == nil)
    }

    @Test func perchSpaceMapsQuartzToRigAndBackToAppKit() {
        // A 1000 pt tall primary screen; a second screen above it.
        let primary = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let above = CGRect(x: 0, y: 1000, width: 1600, height: 900)
        let quartz = CGRect(x: 100, y: -800, width: 600, height: 400) // on the upper screen
        #expect(PerchSpace.screen(for: quartz, screens: [primary, above], primaryHeight: 1000) == above)
        let space = PerchSpace(screen: above, primaryHeight: 1000, scale: 0.5)
        #expect(space.rig(quartz) == CGRect(x: 200, y: 200, width: 1200, height: 800))
        // Rig (200, 200) is the window's top-left corner: AppKit y = 1900 - 100.
        #expect(space.screenPoint(CGPoint(x: 200, y: 200)) == CGPoint(x: 100, y: 1800))
    }

    @MainActor
    @Test func moodsMapToClips() {
        #expect(MascotController.clip(for: .thinking) == .thinking)
        #expect(MascotController.clip(for: .talking) == .idle)
        #expect(MascotController.clip(for: .listening) == .asking)
        #expect(MascotController.clip(for: .happy) == .success)
        #expect(MascotController.clip(for: .worried) == .error)
        #expect(MascotController.clip(for: .sleepy) == .idle)
    }
}
