import CoreGraphics
import Foundation
import ImageIO

// A Swift port of Codex's Dashii runtime (PersonaCat/runtime/core.mjs). The rig, clips and atlas
// are the JSON files Codex exports (synced by scripts/sync-dashii-assets.sh). Coordinates are in
// rig points: x right, y down, rotations in clockwise degrees.

struct DashiiRig: Decodable, Sendable {
    struct Bone: Decodable, Sendable {
        let name: String
        let parent: String?
        let x: Double
        let y: Double
        var rotation: Double?
    }

    struct Attachment: Decodable, Sendable {
        let bone: String
        let region: String
        let size: [Double]
        let pivot: [Double]
        let z: Double
        let rotation: Double
    }

    struct IK: Decodable, Sendable {
        let upperLength: Double
        let lowerLength: Double
        let contactOffset: Double
    }

    struct Directions: Decodable, Sendable {
        let head: [String: String]
        let torso: [String: String]
        let thresholdsDegrees: [Double]
    }

    let bones: [Bone]
    let attachments: [Attachment]
    let ik: IK
    let directions: Directions
}

struct DashiiClips: Decodable, Sendable {
    struct Clip: Decodable, Sendable {
        let duration: Double
        let loop: Bool
        let expression: String
        let prop: String?
        /// "bone.property" to [time, value] keyframes.
        let tracks: [String: [[Double]]]
    }

    let transitionSeconds: Double
    let clips: [String: Clip]
}

struct DashiiAtlas: Decodable, Sendable {
    struct Region: Decodable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    let regions: [String: Region]
}

/// The animation clips Codex authored.
enum DashiiClip: String, CaseIterable, Sendable {
    case idle, thinking, working, asking, delegating, success, error, enter, exit
}

/// Per-bone offsets: rotation, x, y.
typealias DashiiPose = [String: [String: Double]]

/// A bone's position and rotation in rig space.
struct DashiiBone: Equatable, Sendable {
    var x: Double
    var y: Double
    var rotation: Double
}

enum DashiiMath {
    static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { max(low, min(high, value)) }
    static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    static func smooth(_ t: Double) -> Double {
        let t = clamp(t, 0, 1)
        return t * t * (3 - 2 * t)
    }

    /// Linear interpolation between keyframes, holding the first and last values outside them.
    static func sampleTrack(_ keys: [[Double]], at t: Double) -> Double {
        guard let first = keys.first, first.count == 2 else { return 0 }
        if t <= first[0] { return first[1] }
        for index in 1..<keys.count where t <= keys[index][0] {
            let a = keys[index - 1], b = keys[index]
            return mix(a[1], b[1], (t - a[0]) / (b[0] - a[0]))
        }
        return keys[keys.count - 1][1]
    }

    /// Catmull-Rom through the keyframes: no velocity jumps at keys, so motion reads organic
    /// rather than robotic. Looping tracks wrap their neighbours (the last key equals the first).
    static func sampleTrackSmooth(_ keys: [[Double]], at t: Double, loop: Bool, duration: Double) -> Double {
        guard keys.count > 1, keys.allSatisfy({ $0.count == 2 }) else { return sampleTrack(keys, at: t) }
        if t <= keys[0][0] { return keys[0][1] }
        guard let index = (1..<keys.count).first(where: { t <= keys[$0][0] }) else { return keys[keys.count - 1][1] }
        let last = keys.count - 1
        func key(_ i: Int) -> (t: Double, v: Double) {
            if i < 0 {
                // Before the first key: the loop's second-to-last key, shifted back a period.
                return loop && last >= 2 ? (keys[last - 1][0] - duration, keys[last - 1][1]) : (keys[0][0] - 1, keys[0][1])
            }
            if i > last {
                return loop && last >= 2 ? (keys[1][0] + duration, keys[1][1]) : (keys[last][0] + 1, keys[last][1])
            }
            return (keys[i][0], keys[i][1])
        }
        let p0 = key(index - 2), p1 = key(index - 1), p2 = key(index), p3 = key(index + 1)
        let span = p2.t - p1.t
        guard span > 0 else { return p2.v }
        let u = (t - p1.t) / span
        // Tangents scaled to this segment's length (non-uniform Catmull-Rom).
        let m1 = (p2.v - p0.v) / max(p2.t - p0.t, 1e-6) * span
        let m2 = (p3.v - p1.v) / max(p3.t - p1.t, 1e-6) * span
        let u2 = u * u, u3 = u2 * u
        return (2 * u3 - 3 * u2 + 1) * p1.v + (u3 - 2 * u2 + u) * m1 + (-2 * u3 + 3 * u2) * p2.v + (u3 - u2) * m2
    }

    /// Smootherstep: zero velocity and acceleration at both ends.
    static func smoother(_ t: Double) -> Double {
        let t = clamp(t, 0, 1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    static func clipTime(_ t: Double, duration: Double, loop: Bool) -> Double {
        loop ? (t.truncatingRemainder(dividingBy: duration) + duration).truncatingRemainder(dividingBy: duration) : clamp(t, 0, duration)
    }

    static func sample(_ clip: DashiiClips.Clip, at t: Double, smooth: Bool = false) -> DashiiPose {
        let t = clipTime(t, duration: clip.duration, loop: clip.loop)
        var pose: DashiiPose = [:]
        for (path, keys) in clip.tracks {
            let parts = path.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            pose[parts[0], default: [:]][parts[1]] = smooth
                ? sampleTrackSmooth(keys, at: t, loop: clip.loop, duration: clip.duration)
                : sampleTrack(keys, at: t)
        }
        return pose
    }

    /// Mixes every property of either pose; a property missing on one side counts as 0.
    static func blend(_ a: DashiiPose, _ b: DashiiPose, _ t: Double) -> DashiiPose {
        var out: DashiiPose = [:]
        for name in Set(a.keys).union(b.keys) {
            let pa = a[name] ?? [:], pb = b[name] ?? [:]
            var props: [String: Double] = [:]
            for prop in Set(pa.keys).union(pb.keys) { props[prop] = mix(pa[prop] ?? 0, pb[prop] ?? 0, t) }
            out[name] = props
        }
        return out
    }

    /// Bones in rig space: each child's offset is rotated by its parent's rotation.
    /// Parents must come before their children (they do in rig.json).
    static func worldBones(_ bones: [DashiiRig.Bone], pose: DashiiPose) -> [String: DashiiBone] {
        var out: [String: DashiiBone] = [:]
        for bone in bones {
            let parent = bone.parent.flatMap { out[$0] } ?? DashiiBone(x: 0, y: 0, rotation: 0)
            let delta = pose[bone.name] ?? [:]
            let x = bone.x + (delta["x"] ?? 0), y = bone.y + (delta["y"] ?? 0)
            let r = parent.rotation * .pi / 180
            out[bone.name] = DashiiBone(x: parent.x + x * cos(r) - y * sin(r),
                                        y: parent.y + x * sin(r) + y * cos(r),
                                        rotation: parent.rotation + (bone.rotation ?? 0) + (delta["rotation"] ?? 0))
        }
        return out
    }

    /// Two-bone IK: the upper and lower arm rotations (degrees) that put the hand on `to`.
    /// Bones hang down at rotation 0, hence the -90.
    static func solveIK(from: CGPoint, to: CGPoint, upper a: Double, lower b: Double, bend: Double = 1) -> (upper: Double, lower: Double) {
        let dx = to.x - from.x, dy = to.y - from.y
        let d = clamp(hypot(dx, dy), abs(a - b) + 0.00001, a + b - 0.00001)
        let elbow = bend * acos(clamp((d * d - a * a - b * b) / (2 * a * b), -1, 1))
        let shoulder = atan2(dy, dx) - atan2(b * sin(elbow), a + b * cos(elbow))
        return (shoulder * 180 / .pi - 90, elbow * 180 / .pi)
    }

    struct Gaze: Equatable, Sendable {
        var yaw = 0.0, pitch = 0.0, eyeX = 0.0, eyeY = 0.0

        mutating func approach(_ target: Gaze, damp: Double) {
            yaw = mix(yaw, target.yaw, damp)
            pitch = mix(pitch, target.pitch, damp)
            eyeX = mix(eyeX, target.eyeX, damp)
            eyeY = mix(eyeY, target.eyeY, damp)
        }
    }

    /// Where the head and eyes turn to look at `cursor` (rig space, relative to the same origin as `head`).
    static func gaze(cursor: CGPoint, head: CGPoint) -> Gaze {
        let dx = cursor.x - head.x, dy = cursor.y - head.y
        return Gaze(yaw: clamp(dx * 0.12, -60, 60), pitch: clamp(dy * 0.06, -22, 22),
                    eyeX: clamp(dx * 0.022, -8, 8), eyeY: clamp(dy * 0.018, -5, 5))
    }

    enum View: String, Sendable { case front, threequarter, profile, back }

    static func view(forYaw yaw: Double) -> View {
        let yaw = abs(yaw)
        return yaw > 135 ? .back : yaw > 52 ? .profile : yaw > 22 ? .threequarter : .front
    }

    /// Like `view(forYaw:)`, but keeps the current view until the yaw is clearly past a threshold,
    /// so a head hovering near 22° doesn't flicker between sprites.
    static func view(forYaw yaw: Double, current: View, margin: Double = 5) -> View {
        let plain = view(forYaw: yaw)
        guard plain != current else { return current }
        let nudged = view(forYaw: abs(yaw) + (order(plain) > order(current) ? -margin : margin))
        return nudged == current ? current : plain
    }

    private static func order(_ view: View) -> Int {
        switch view {
        case .front: 0
        case .threequarter: 1
        case .profile: 2
        case .back: 3
        }
    }

    /// The turn angle a head view's sprite is drawn at (positive yaw faces right).
    static func nominalTurn(_ view: View, yaw: Double) -> Double {
        let angle: Double = switch view {
        case .front: 0
        case .threequarter: 45
        case .profile: 90
        case .back: 180
        }
        return yaw < 0 ? -angle : angle
    }

    /// A point on the head's horizontal ring at `angle` degrees from the face (90 = the right
    /// side), seen with the head turned by `turn`: its x offset and depth (positive = towards the viewer).
    static func ring(angle: Double, radius: Double, turn: Double) -> (x: Double, depth: Double) {
        let a = (angle + turn) * .pi / 180
        return (radius * sin(a), cos(a))
    }

    /// Gaze for a pointer anywhere on screen: saturates softly (tanh) and stays mostly in the
    /// front and three-quarter views, so Dashii glances rather than turning its head away.
    static func softGaze(cursor: CGPoint, head: CGPoint) -> Gaze {
        let dx = cursor.x - head.x, dy = cursor.y - head.y
        return Gaze(yaw: 36 * tanh(dx / 320), pitch: 14 * tanh(dy / 320), eyeX: 7 * tanh(dx / 220), eyeY: 4 * tanh(dy / 220))
    }
}

/// Where Dashii perches on a window, and its path while climbing on or jumping off.
struct DashiiPlacement: Equatable, Sendable {
    enum Edge: String, Sendable { case top, left, right }
    struct Contact: Equatable, Sendable {
        /// "L" or "R".
        let side: String
        let goal: CGPoint
    }

    var visible: Bool
    var root: CGPoint
    var edge: Edge
    /// Hands gripping the edge (IK) rather than following the clip.
    var contact: Bool
    var contacts: [Contact]

    /// `target` and `viewport` are in rig points (y down, viewport origin at 0,0). The state is
    /// "enter" or "exit" while climbing; anything else perches.
    static func compute(state: DashiiClip, time: Double, target: CGRect, viewport: CGSize) -> DashiiPlacement {
        guard target.width > 0, target.height > 0, target.minX.isFinite, target.minY.isFinite else {
            return DashiiPlacement(visible: false, root: .zero, edge: .top, contact: false, contacts: [])
        }
        let mix = DashiiMath.mix, smooth = DashiiMath.smooth, clamp = DashiiMath.clamp
        // Perch inside a vertical border if there isn't enough room above the window.
        let side = target.minY < 170
        let right = target.maxX
        let edge: Edge = side ? (right <= viewport.width && right >= 185 ? .right : .left) : .top
        let x = side ? (edge == .right ? right - 92 : target.minX + 92)
            : clamp(target.minX + min(105, target.width * 0.5), 92, viewport.width - 92)
        let y = side ? clamp(target.minY + 165, 165, viewport.height - 100) : target.minY - 26
        let hang = side ? y + 50 : target.minY + 60
        var px = x, py = y, contact = false, visible = true
        switch state {
        case .exit:
            if time < 0.7 {
                py = mix(y, hang, smooth(time / 0.7))
                contact = true
            } else {
                let p = smooth((time - 0.7) / 1.3)
                px = mix(x, viewport.width + 180, p)
                py = mix(hang, viewport.height + 180, p)
            }
            visible = time < 2
        case .enter:
            let travel = smooth(time / 1.25), pull = smooth((time - 1.25) / 1.75)
            px = mix(viewport.width + 180, x, travel)
            py = time < 1.25 ? mix(hang + 60, hang, travel) : mix(hang, y, pull)
            contact = time >= 1.25 && time <= 3
        default:
            break
        }
        let contacts: [Contact] = side
            ? [Contact(side: edge == .right ? "R" : "L", goal: CGPoint(x: edge == .right ? right : target.minX, y: py - 20))]
            : [Contact(side: "L", goal: CGPoint(x: x - 34, y: target.minY)), Contact(side: "R", goal: CGPoint(x: x + 34, y: target.minY))]
        return DashiiPlacement(visible: visible, root: CGPoint(x: px, y: py), edge: edge, contact: contact, contacts: contacts)
    }
}

/// Plays clips, cross-fading from the previous pose over the clip transition.
struct DashiiAnimator {
    let clips: DashiiClips
    private(set) var state: DashiiClip = .idle
    private(set) var started: Double = 0
    private var previous: DashiiPose = [:]
    private var changed: Double = -1

    init(clips: DashiiClips) { self.clips = clips }

    var clip: DashiiClips.Clip? { clips.clips[state.rawValue] }

    mutating func play(_ name: DashiiClip, at now: Double) {
        previous = pose(at: now)
        state = name
        started = now
        changed = now
    }

    /// Cross-fade length; Codex's 0.24 s, or longer for the softer desktop motion.
    var transition: Double?
    /// Spline keyframes instead of Codex's linear ones.
    var smoothKeys = false

    func pose(at now: Double) -> DashiiPose {
        guard let clip else { return previous }
        let next = DashiiMath.sample(clip, at: now - started, smooth: smoothKeys)
        let fade = (now - changed) / (transition ?? clips.transitionSeconds)
        return DashiiMath.blend(previous, next, smoothKeys ? DashiiMath.smoother(fade) : DashiiMath.smooth(fade))
    }
}

/// The rig, clips and atlas image, loaded once from the app bundle.
final class DashiiAssets: @unchecked Sendable {
    static let shared = DashiiAssets(bundle: .main)

    let rig: DashiiRig?
    let clips: DashiiClips?
    let atlas: DashiiAtlas?
    /// Each atlas region cut out once.
    let regions: [String: CGImage]
    /// The whole atlas, for the Metal renderer's texture.
    let atlasImage: CGImage?

    var isLoaded: Bool { rig != nil && clips != nil && !regions.isEmpty }

    init(bundle: Bundle) {
        func load<T: Decodable>(_ name: String) -> T? {
            guard let url = bundle.url(forResource: name, withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
        rig = load("rig")
        clips = load("animations")
        atlas = load("atlas")
        var regions: [String: CGImage] = [:]
        var whole: CGImage?
        if let atlas, let url = bundle.url(forResource: "atlas", withExtension: "png"),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            whole = image
            for (name, region) in atlas.regions {
                if let cut = image.cropping(to: region.rect) { regions[name] = cut }
            }
        }
        self.regions = regions
        atlasImage = whole
    }
}
