import SwiftUI

/// How the host moves Dashii around the screen, read every frame (not observed): the root's
/// velocity drives leaning and ear flop, `squash` a landing bounce.
final class DashiiMotion {
    /// Rig points per second, y down.
    var velocity = CGVector.zero
    /// Set when Dashii lands; decays on its own.
    var landedAt: Double?
    /// Hopping between windows: arms up, thruster boost.
    var airborne = false
}

/// What Dashii is doing, as decided by its host (the mascot overlay or the desktop perch).
struct DashiiDirection: Equatable {
    var clip: DashiiClip = .idle
    /// The pointer relative to Dashii's root, in rig points (y down). Nil: look ahead.
    var cursor: CGPoint?
    /// Hand goals relative to the root, in rig points, while gripping a window edge.
    var contacts: [DashiiPlacement.Contact] = []
    /// A tip just arrived: hop for attention.
    var attention = false
    /// Long idle: eyes closed, slow breathing.
    var sleepy = false
    /// A bubble is showing an answer or tip: nod and gesture while "speaking".
    var talking = false
    /// The pointer rests on Dashii: happy eyes, ear wiggle, a little nuzzle.
    var petted = false
    /// Idle fidgets (waves, look-arounds, spins) now and then.
    var fidgets = true
    var motion: DashiiMotion?
    /// Forces the head yaw (degrees), like Codex's preview slider; nil follows the pointer.
    var yaw: Double?

    static func == (a: DashiiDirection, b: DashiiDirection) -> Bool {
        a.clip == b.clip && a.cursor == b.cursor && a.contacts == b.contacts && a.attention == b.attention && a.sleepy == b.sleepy
            && a.talking == b.talking && a.petted == b.petted && a.fidgets == b.fidgets && a.motion === b.motion
            && a.yaw == b.yaw
    }
}

/// Codex's Dashii rig drawn natively: atlas sprites on bones, clip blending, gaze tracking,
/// two-bone IK for gripping edges, drawn eye expressions and clip props (a port of
/// PersonaCat/runtime/render.mjs), plus a procedural layer Codex's web preview doesn't have:
/// spline keyframes, breathing, ear follow-through, leaning into motion, fidgets, talking and
/// petting reactions, and squash on landing.
struct DashiiView: View {
    var direction: DashiiDirection
    var scale: CGFloat = 0.55

    /// The canvas covers the rig plus its props: x -95…160, y -175…75 around the root.
    static let rigBox = CGRect(x: -95, y: -175, width: 255, height: 250)

    static func size(scale: CGFloat) -> CGSize { CGSize(width: rigBox.width * scale, height: rigBox.height * scale) }
    /// The root bone (torso centre) in the view, from its top-left corner.
    static func root(scale: CGFloat) -> CGPoint { CGPoint(x: -rigBox.minX * scale, y: -rigBox.minY * scale) }

    @State private var player = DashiiPlayer()

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSince(player.epoch)
            // Rasterized by Metal off the main thread: the rig's sprites, face and props are
            // flattened into one GPU layer each frame instead of separate Core Animation draws.
            Canvas(rendersAsynchronously: true) { context, _ in
                player.render(into: &context, time: time, direction: direction, scale: scale)
            }
            .drawingGroup()
        }
        .frame(width: Self.size(scale: scale).width, height: Self.size(scale: scale).height)
        .background {
            // The halo while busy, centred on the body.
            let root = Self.root(scale: scale)
            DashiiAura(active: direction.clip == .thinking || direction.clip == .working)
                .frame(width: 150 * scale * 2, height: 150 * scale * 2)
                .position(x: root.x, y: root.y - 30 * scale)
        }
        .accessibilityHidden(true)
    }
}

/// An idle fidget: a short additive animation layered over the idle clip.
private enum Fidget: CaseIterable {
    case wave, lookAround, spin, hop, earTwitch, stretch

    var duration: Double {
        switch self {
        case .wave: 2.4
        case .lookAround: 3.2
        case .spin: 1.5
        case .hop: 0.9
        case .earTwitch: 0.7
        case .stretch: 2.2
        }
    }
}

/// One time base for every Dashii view and the desktop perch (landing squash timestamps).
enum DashiiClock {
    static let epoch = Date()
}

/// The animator, smoothed gaze, springs and fidget schedule carried from frame to frame.
final class DashiiPlayer {
    let epoch = DashiiClock.epoch
    private let assets = DashiiAssets.shared
    private var animator: DashiiAnimator?
    private var gazeNow = DashiiMath.Gaze()
    private var lastTime = 0.0
    private var headView = DashiiMath.View.front
    /// The head's turn in degrees, easing toward the angle its current sprite shows.
    private var turn = 0.0
    private var bodyView = DashiiMath.View.front
    /// Ear springs (angle, angular velocity) driven by the head's motion and the body's velocity.
    private var ears = (angle: 0.0, velocity: 0.0)
    private var lastHeadRotation = 0.0
    private var lean = 0.0
    private var fidget: (kind: Fidget, started: Double)?
    private var nextFidget = Double.random(in: 5...9)
    private var thinkingSince: Double?
    private var pettedAmount = 0.0
    private var talkAmount = 0.0

    init() {
        if var animator = assets.clips.map(DashiiAnimator.init) {
            animator.transition = 0.45
            animator.smoothKeys = true
            self.animator = animator
        }
    }

    func render(into context: inout GraphicsContext, time t: Double, direction: DashiiDirection, scale: CGFloat) {
        guard var animator, let rig = assets.rig, let clips = assets.clips else {
            // Assets missing from the bundle: a plain placeholder rather than nothing.
            let root = DashiiView.root(scale: scale)
            context.fill(Path(ellipseIn: CGRect(x: root.x - 30, y: root.y - 60, width: 60, height: 60)), with: .color(.purple))
            return
        }
        let dt = DashiiMath.clamp(t - lastTime, 0, 0.1)
        lastTime = t
        let ease = { (rate: Double) in 1 - exp(-dt * rate) }

        // Long thinking turns into busy work at the keyboard.
        var wanted = direction.clip
        if wanted == .thinking {
            if thinkingSince == nil { thinkingSince = t }
            if let since = thinkingSince, t - since > 4 { wanted = .working }
        } else {
            thinkingSince = nil
        }
        if animator.state != wanted { animator.play(wanted, at: t) }
        self.animator = animator
        let age = t - animator.started
        guard let clip = clips.clips[animator.state.rawValue] else { return }
        var pose = animator.pose(at: t)
        func add(_ bone: String, _ property: String, _ value: Double) { pose[bone, default: [:]][property, default: 0] += value }

        // Breathing and hover: always on, slower when sleepy.
        let breath = direction.sleepy ? 0.9 : 1.7
        add("root", "y", sin(t * breath) * (direction.sleepy ? 1.5 : 2.2))
        add("head", "y", sin(t * breath - 0.7) * 1.2)
        add("upperL", "rotation", sin(t * breath - 0.4) * 2.5)
        add("upperR", "rotation", -sin(t * breath - 0.4) * 2.5)
        if direction.sleepy { add("head", "rotation", 7 + sin(t * 0.9) * 2) }

        // Talking: nods and an open-hand gesture, eased in and out.
        talkAmount = DashiiMath.mix(talkAmount, direction.talking ? 1 : 0, ease(5))
        if talkAmount > 0.01 {
            add("head", "rotation", sin(t * 4.2) * 3.5 * talkAmount)
            add("head", "y", abs(sin(t * 4.2)) * -1.5 * talkAmount)
            add("upperR", "rotation", (-38 - sin(t * 2.1) * 14) * talkAmount)
            add("foreR", "rotation", (-30 + sin(t * 2.1 + 0.8) * 18) * talkAmount)
        }

        // Petting: happy wiggle.
        pettedAmount = DashiiMath.mix(pettedAmount, direction.petted ? 1 : 0, ease(6))
        if pettedAmount > 0.01 {
            add("head", "rotation", sin(t * 3.2) * 6 * pettedAmount)
            add("earL", "rotation", sin(t * 13) * 7 * pettedAmount)
            add("earR", "rotation", -sin(t * 13 + 1) * 7 * pettedAmount)
            add("root", "y", -2 * pettedAmount)
        }

        // Attention: a couple of springy hops with arms up.
        if direction.attention {
            let hop = abs(sin(t * 6.5))
            add("root", "y", -hop * 13)
            add("upperL", "rotation", 35 * hop)
            add("upperR", "rotation", -35 * hop)
        }

        // Fidgets while idle and left alone.
        var yawOverride: (yaw: Double, weight: Double)?
        let calm = animator.state == .idle && !direction.talking && !direction.attention && direction.contacts.isEmpty
            && direction.fidgets && !direction.sleepy && !(direction.motion?.airborne ?? false)
        if fidget == nil, calm, t > nextFidget {
            fidget = (Fidget.allCases.randomElement() ?? .wave, t)
        }
        if let current = fidget {
            let p = (t - current.started) / current.kind.duration
            if p >= 1 || !calm {
                fidget = nil
                nextFidget = t + Double.random(in: 7...15)
            } else {
                let envelope = DashiiMath.smoother(min(p / 0.2, 1)) * DashiiMath.smoother(min((1 - p) / 0.2, 1))
                switch current.kind {
                case .wave:
                    add("upperR", "rotation", -150 * envelope)
                    add("foreR", "rotation", (-25 + sin(p * 30) * 28) * envelope)
                    add("head", "rotation", 5 * envelope)
                case .lookAround:
                    yawOverride = (sin(p * .pi * 2) * 42, envelope)
                case .spin:
                    // A full pirouette through the side and back views.
                    let angle = DashiiMath.smoother(p) * 360
                    yawOverride = (angle > 180 ? angle - 360 : angle, 1)
                    add("root", "y", -sin(p * .pi) * 8)
                case .hop:
                    let arc = sin(p * .pi)
                    add("root", "y", -arc * 18)
                    add("upperL", "rotation", 40 * arc)
                    add("upperR", "rotation", -40 * arc)
                case .earTwitch:
                    add("earR", "rotation", sin(p * 40) * 14 * (1 - p))
                case .stretch:
                    add("upperL", "rotation", 150 * envelope)
                    add("upperR", "rotation", -150 * envelope)
                    add("head", "rotation", -6 * envelope)
                    add("root", "y", -4 * envelope)
                }
            }
        }

        // Leaning into motion when the host moves Dashii (window rides, hops), ears trailing.
        let velocity = direction.motion?.velocity ?? .zero
        lean = DashiiMath.mix(lean, DashiiMath.clamp(Double(velocity.dx) * 0.012, -14, 14), ease(6))
        add("torso", "rotation", lean)
        if direction.motion?.airborne == true {
            add("upperL", "rotation", 55)
            add("upperR", "rotation", -55)
        }

        // Gaze follows the pointer, softly and smoothed.
        var target = direction.cursor.map { DashiiMath.softGaze(cursor: $0, head: CGPoint(x: 0, y: -68)) } ?? DashiiMath.Gaze()
        if let yawOverride { target.yaw = DashiiMath.mix(target.yaw, yawOverride.yaw, yawOverride.weight) }
        if let forced = direction.yaw { target.yaw = forced }
        let spinning = fidget?.kind == .spin
        if spinning { gazeNow.yaw = target.yaw }
        gazeNow.approach(target, damp: ease(spinning ? 60 : 5))
        let yaw = gazeNow.yaw
        let bodyYaw = spinning ? yaw : yaw * 0.48
        add("head", "rotation", gazeNow.pitch * 0.12)
        add("head", "y", gazeNow.pitch * 0.08)
        add("torso", "rotation", bodyYaw * 0.045)

        // Ears: a damped spring kicked by the head's rotation and the body's sideways motion.
        let headRotation = pose["head"]?["rotation"] ?? 0
        let headSpeed = dt > 0 ? (headRotation - lastHeadRotation) / dt : 0
        lastHeadRotation = headRotation
        let force = -headSpeed * 0.9 - Double(velocity.dx) * 0.02 - ears.angle * 120 - ears.velocity * 14
        ears.velocity += force * dt
        ears.angle = DashiiMath.clamp(ears.angle + ears.velocity * dt, -20, 20)
        add("earL", "rotation", ears.angle)
        add("earR", "rotation", ears.angle * 0.85)

        headView = DashiiMath.view(forYaw: yaw, current: headView)
        bodyView = DashiiMath.view(forYaw: bodyYaw, current: bodyView)
        // Parts follow the actual yaw, not the sprite's view, so they glide as the head turns
        // (the concept sheet shifts ears and discs even at ±15° on the front sprite).
        turn = yaw

        // The headset discs and cat ears sit on the head's ring, so they swing round with it.
        var depth: [String: Double] = [:]
        for (bone, angle, radius) in [("discL", -90.0, 72.0), ("discR", 90.0, 72.0), ("earL", -44.0, 56.0), ("earR", 44.0, 56.0)] {
            guard let rest = rig.bones.first(where: { $0.name == bone }) else { continue }
            let point = DashiiMath.ring(angle: angle, radius: radius, turn: turn)
            add(bone, "x", point.x - rest.x)
            depth[bone] = point.depth
        }

        var bones = DashiiMath.worldBones(rig.bones, pose: pose)
        for contact in direction.contacts {
            guard let shoulder = bones["upper" + contact.side], let torso = bones["torso"] else { continue }
            let arm = DashiiMath.solveIK(from: CGPoint(x: shoulder.x, y: shoulder.y), to: contact.goal,
                                         upper: rig.ik.upperLength, lower: rig.ik.lowerLength, bend: contact.side == "L" ? -1 : 1)
            pose["upper" + contact.side] = ["rotation": arm.upper - torso.rotation]
            pose["fore" + contact.side] = ["rotation": arm.lower]
            bones = DashiiMath.worldBones(rig.bones, pose: pose)
        }

        var stage = context
        let root = DashiiView.root(scale: scale)
        stage.translateBy(x: root.x, y: root.y)
        stage.scaleBy(x: scale, y: scale)
        // Squash on landing: wide and short, springing back, anchored at the thruster.
        if let landed = direction.motion?.landedAt, t - landed >= 0, t - landed < 0.6 {
            let k = t - landed
            let squash = exp(-k * 7) * cos(k * 22) * 0.12
            stage.translateBy(x: 0, y: 60)
            stage.scaleBy(x: 1 + squash, y: 1 - squash)
            stage.translateBy(x: 0, y: -60)
        }
        let thrust = direction.motion?.airborne == true ? 1.5 : 1
        // A disc turned toward the viewer draws over the head (z 6), one turned away under it.
        func z(_ attachment: DashiiRig.Attachment) -> Double {
            guard attachment.bone.hasPrefix("disc"), let d = depth[attachment.bone] else { return attachment.z }
            return d > -0.05 ? 7 + d : 5 + d
        }
        for attachment in rig.attachments.sorted(by: { z($0) < z($1) }) {
            draw(attachment, bones: bones, rig: rig, headYaw: yaw, bodyYaw: bodyYaw, time: t, thrust: thrust,
                 depth: depth[attachment.bone], in: stage)
        }
        if let head = bones["head"] {
            let expression = direction.sleepy ? "thinking" : (pettedAmount > 0.5 ? "happy" : clip.expression)
            face(head, yaw: yaw, time: t, expression: expression, in: stage)
        }
        if let prop = clip.prop, let rootBone = bones["root"] { props(prop, root: rootBone, time: age, in: stage) }
    }

    private func sprite(_ region: String, at point: CGPoint, size: CGSize, pivot: CGPoint = CGPoint(x: 0.5, y: 0.5), in context: GraphicsContext) {
        guard let image = assets.regions[region] else { return }
        context.draw(Image(decorative: image, scale: 1),
                     in: CGRect(x: point.x - size.width * pivot.x, y: point.y - size.height * pivot.y, width: size.width, height: size.height))
    }

    private func draw(_ attachment: DashiiRig.Attachment, bones: [String: DashiiBone], rig: DashiiRig,
                      headYaw: Double, bodyYaw: Double, time: Double, thrust: Double, depth: Double?,
                      in parent: GraphicsContext) {
        guard let bone = bones[attachment.bone] else { return }
        var context = parent
        context.translateBy(x: bone.x, y: bone.y)
        context.rotate(by: .degrees(bone.rotation + attachment.rotation))
        var region = attachment.region
        var width = attachment.size[0]
        var height = attachment.size[1]
        switch attachment.bone {
        case "head":
            region = rig.directions.head[headView.rawValue] ?? region
            // Front views are symmetric artwork: mirroring them only flips the highlights.
            context.scaleBy(x: headYaw < 0 && headView != .front ? -1 : 1, y: 1 - abs(gazeNow.pitch) * 0.0015)
        case "torso":
            region = rig.directions.torso[bodyView.rawValue] ?? region
            // Never mirror the front torso: its "P" logo would read as "q".
            context.scaleBy(x: bodyYaw < 0 && bodyView != .front ? -1 : 1, y: 1)
        case "thruster":
            context.opacity = 0.82 + 0.18 * sin(time * 11)
            height *= (1 + 0.09 * sin(time * 13)) * thrust
        case "discL", "discR":
            // Edge-on at the sides (front view), face-on when turned toward the viewer.
            let facing = abs(depth ?? 0)
            width *= 1 + 0.45 * facing
            // The disc art's rim faces outward: point it away from the head's centre.
            if bone.x - (bones["head"]?.x ?? 0) > 0 { context.scaleBy(x: -1, y: 1) }
        default:
            break
        }
        sprite(region, at: .zero, size: CGSize(width: width, height: height),
               pivot: CGPoint(x: attachment.pivot[0], y: attachment.pivot[1]), in: context)
    }

    private func face(_ head: DashiiBone, yaw: Double, time: Double, expression: String, in parent: GraphicsContext) {
        let view = headView
        guard view != .back else { return }
        var context = parent
        context.translateBy(x: head.x, y: head.y)
        context.rotate(by: .degrees(head.rotation))
        context.scaleBy(x: yaw < 0 ? -1 : 1, y: 1)
        let flip = yaw < 0 ? -1.0 : 1.0
        let cx = (view == .profile ? 48 : view == .threequarter ? 15 : 0) + gazeNow.eyeX * flip
        let cy = 13 + gazeNow.eyeY + gazeNow.pitch * 0.13
        let separation = view == .threequarter ? 21.0 : 27.0
        let phase = time.truncatingRemainder(dividingBy: 4.7)
        let blink = phase > 4.48 && phase < 4.64
        let eyes = view == .profile ? [cx] : [cx - separation, cx + separation]
        let style = StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
        let color = expression == "error" ? Color(hex: 0xff6e86) : Color(hex: 0xc4faff)
        var glow = context
        glow.addFilter(.shadow(color: Color(hex: 0x22d3ee), radius: 3.5))
        for x in eyes {
            var path = Path()
            if expression == "error" {
                path.move(to: CGPoint(x: x - 5, y: cy - 6)); path.addLine(to: CGPoint(x: x + 5, y: cy + 6))
                path.move(to: CGPoint(x: x + 5, y: cy - 6)); path.addLine(to: CGPoint(x: x - 5, y: cy + 6))
            } else if blink || expression == "thinking" {
                path.move(to: CGPoint(x: x - 6, y: cy + 2))
                path.addQuadCurve(to: CGPoint(x: x + 6, y: cy + 2), control: CGPoint(x: x, y: cy + 5))
            } else if expression == "happy" {
                path.move(to: CGPoint(x: x - 9, y: cy + 5))
                path.addQuadCurve(to: CGPoint(x: x + 9, y: cy + 5), control: CGPoint(x: x, y: cy - 14))
            } else if expression == "focused" {
                path.move(to: CGPoint(x: x - 7, y: cy - 5))
                path.addLine(to: CGPoint(x: x + 3, y: cy))
                path.addLine(to: CGPoint(x: x - 7, y: cy + 5))
            } else {
                sprite("eye", at: CGPoint(x: x, y: cy),
                       size: CGSize(width: view == .profile ? 9 : 12, height: expression == "curious" ? 25 : 23), in: context)
                continue
            }
            glow.stroke(path, with: .color(color), style: style)
        }
    }

    private func props(_ kind: String, root: DashiiBone, time: Double, in parent: GraphicsContext) {
        let x = root.x, y = root.y
        let font = Font.system(size: 20, weight: .semibold)
        switch kind {
        case "work":
            var context = parent
            context.translateBy(x: x + 8, y: y + 27)
            context.rotate(by: .radians(-0.07))
            let card = Path(roundedRect: CGRect(x: -41, y: -20, width: 82, height: 43), cornerRadius: 7)
            var glow = context
            glow.addFilter(.shadow(color: Color(hex: 0x22d3ee), radius: 6))
            glow.fill(card, with: .color(Color(hex: 0x0c8fc4, opacity: 0xaa / 255)))
            glow.stroke(card, with: .color(Color(hex: 0x9df2ff)), lineWidth: 2)
            context.draw(Text("</>").font(font).foregroundStyle(Color(hex: 0xe8fbff)), at: CGPoint(x: 0, y: -1))
            context.fill(Path(CGRect(x: -27, y: 13, width: 30 + 12 * sin(time * 4), height: 2)), with: .color(Color(hex: 0xbcf8ff)))
        case "delegation":
            let ox = x + 112, oy = y - 70
            var wire = Path()
            wire.move(to: CGPoint(x: x + 65, y: y - 5)); wire.addLine(to: CGPoint(x: ox - 15, y: y - 5))
            wire.addLine(to: CGPoint(x: ox - 15, y: oy)); wire.addLine(to: CGPoint(x: ox - 15, y: oy + 72))
            parent.stroke(wire, with: .color(Color(hex: 0x9e92ff)), lineWidth: 2)
            let fills: [UInt32] = [0x5c4aa0, 0x147e9d, 0x22766b]
            for index in 0..<3 {
                let py = oy + Double(index) * 36
                var branch = Path()
                branch.move(to: CGPoint(x: ox - 15, y: py)); branch.addLine(to: CGPoint(x: ox, y: py))
                parent.stroke(branch, with: .color(Color(hex: 0x9e92ff)), lineWidth: 2)
                let box = Path(roundedRect: CGRect(x: ox, y: py - 13, width: 39, height: 26), cornerRadius: 9)
                parent.fill(box, with: .color(Color(hex: fills[index])))
                parent.stroke(box, with: .color(Color(hex: 0xa6edff)), lineWidth: 2)
                let active = Int(floor(time * 2)) % 3 == index
                let eye = Color(hex: active ? 0xffffff : 0x8be7f5)
                parent.fill(Path(CGRect(x: ox + 10, y: py - 4, width: 4, height: 8)), with: .color(eye))
                parent.fill(Path(CGRect(x: ox + 25, y: py - 4, width: 4, height: 8)), with: .color(eye))
                if active { parent.fill(Path(ellipseIn: CGRect(x: ox - 10, y: py - 3, width: 6, height: 6)), with: .color(eye)) }
            }
        default:
            let symbols = ["question": "?", "thought": "···", "success": "✓", "error": "!"]
            let bx = x + 87, by = y - 147 + sin(time * 2) * 2
            let bubble = Path(roundedRect: CGRect(x: bx - 21, y: by - 19, width: 42, height: 38), cornerRadius: 14)
            parent.fill(bubble, with: .color(Color(hex: kind == "error" ? 0x702a4b : 0xf6f1ff)))
            parent.stroke(bubble, with: .color(Color(hex: 0x9471df)), lineWidth: 2)
            parent.draw(Text(symbols[kind] ?? "").font(font).foregroundStyle(Color(hex: kind == "error" ? 0xffafbf : 0x7c3aed)),
                        at: CGPoint(x: bx, y: by))
        }
    }
}

/// Dashii's head alone, for small spots like the chat header. Eyes close while thinking.
struct DashiiAvatar: View {
    var thinking = false

    var body: some View {
        Canvas { context, size in
            let assets = DashiiAssets.shared
            guard let head = assets.regions["head_front"] else { return }
            // The head sprite is 158 x 130 rig points; the eyes sit 13 below its centre, 27 apart.
            let scale = min(size.width / 158, size.height / 130)
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.scaleBy(x: scale, y: scale)
            context.draw(Image(decorative: head, scale: 1), in: CGRect(x: -79, y: -65, width: 158, height: 130))
            for x in [-27.0, 27.0] {
                if thinking {
                    var path = Path()
                    path.move(to: CGPoint(x: x - 6, y: 15))
                    path.addQuadCurve(to: CGPoint(x: x + 6, y: 15), control: CGPoint(x: x, y: 18))
                    context.stroke(path, with: .color(Color(hex: 0xc4faff)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                } else if let eye = assets.regions["eye"] {
                    context.draw(Image(decorative: eye, scale: 1), in: CGRect(x: x - 6, y: 13 - 11.5, width: 12, height: 23))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: opacity)
    }
}
