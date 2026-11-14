import SwiftUI

/// Harmonograph, "song figure, measured swing": a two-pendulum harmonograph
/// whose figure belongs to the song and whose swing is the music.
///
/// This effect leaves the app's "plot only measured audio" rule in two
/// declared places. Invented, fixed for the song: which figure the two
/// pendulums draw (an eight on its side, a pretzel or a ribbon of three
/// loops), how it leans, and where its slow sway starts, all from the song's
/// seed. The phase between the pendulums never leaves the range in which the
/// figure is open. Also invented: the small resting figure shown before a
/// song's first samples arrive (one fixed small size and a slowly moving pen).
///
/// Measured, every frame: how far the pendulums swing, from the levels the
/// analyser measured (not the clock's eased ones). The sideways reach is the
/// bass level and the upright reach the mid level, on fixed square-root
/// scales. A swing is thrown when a level rises about 2 dB above the swing's
/// own lowest point, and inside one swing the reach only falls as far as the
/// level fell. Each time it has fallen one step, a loop stays where the
/// newest loop stood, so the fan of loops is the level's way down.
///
/// What each mark means, back to front:
/// - the bars' disc: the paper. Its top and bottom are a full upright swing,
///   and ink is brighter on it.
/// - pale-blue kept loops: where the newest loop stood, one for every step the
///   level has fallen in the last 1.2 s, fainter the more loops are newer.
/// - the newest loop, brightest: the song's figure at the reach measured now.
/// - yellow ends of the newest loop: a hit is arriving now. Far left and right
///   when the bass was hit, top and bottom when the mids were; when both were,
///   only the harder hit shows. Treble has no mark.
/// - four soft-red ticks: the furthest recent reach on each axis.
/// - a pale-blue dot in a small ring: the pen, at rest in the middle while the
///   sound is silent.
struct HarmonographSongFigure: Sendable {
    // MARK: Fixed scales and display choices. None of these is a measurement.

    /// Full sideways reach is bass level 1. Full upright reach is this mid level.
    static let fullMid = 0.6
    /// Music without low end keeps an open figure: the sideways reach never
    /// uses less than this share of the full-band level.
    static let widthFloor = 0.30
    /// A level follows a rise within about three frames and a fall over about a tenth of a second.
    private static let attack = 60.0, release = 9.0
    /// A reach this much above the swing's lowest point (2 dB of level) throws a new swing; with a detected beat, less.
    private static let riseMargin = 1.122, beatMargin = 1.03
    private static let refractory = 0.12, longestRise = 0.20
    /// One step of the fan, as a share of full reach.
    static let stepX = 0.05, stepY = 0.08
    /// Seconds a kept loop lasts, and how much faster it ages once a new swing has been thrown.
    static let inkLife = 1.2
    private static let liftedAgeing = 3.0
    /// The held reach (the soft-red ticks) stands for this long after it was
    /// last reached, then falls to 37% in `holdRelease`, so it stays outside
    /// the fan it belongs to.
    private static let holdTime = 0.7, holdRelease = 0.5
    /// A hit: a band's level against its own short average, an average that
    /// falls quickly and rises slowly. Yellow starts at `hitFrom` times the
    /// average and is full at `hitFull` (bass first, then mid).
    private static let hitFrom = [1.4, 1.6], hitFull = [1.85, 2.1]
    private static let averageFall = 0.05, averageRise = 0.20
    /// The resting figure's fixed size as a share of full reach, and the seconds the pen takes for one pass.
    private static let idleX = 0.26, idleY = 0.34, idlePass = 14.0

    // MARK: The song's figure

    /// `across` sideways swings against `up` upright swings in one pass.
    struct Figure: Equatable, Sendable {
        let across: Double, up: Double
        /// How far the phase between the pendulums may ever be from the most open figure.
        let range: Double
        let points: Int
        /// The phase at which the figure is most open.
        var open: Double { (.pi / 2 - across * .pi / (2 * up) + .pi / (2 * up)).truncatingRemainder(dividingBy: .pi / up) }
    }
    /// Three figures that stay open and readable both wide (a kick) and narrow (no low end).
    static let figures = [
        Figure(across: 1, up: 2, range: .pi / 12, points: 84),      // an eight on its side
        Figure(across: 2, up: 3, range: .pi / 18, points: 120),     // a pretzel
        Figure(across: 1, up: 3, range: .pi / 18, points: 132)      // a ribbon of three loops
    ]

    private struct Dice {
        var state: UInt64
        init(_ seed: UInt64) { state = seed ^ 0xA5A5_5A5A_C3C3_3C3C }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func index(_ count: Int) -> Int { Int(next() % UInt64(count)) }
    }

    let figure: Figure
    private let lean: Double        // the song's own phase, away from the symmetric figure
    private let sway: Double        // how far the phase moves around it as the music plays

    // MARK: State

    /// A loop left where the newest loop stood.
    private struct Kept: Sendable {
        var x: Double, y: Double
        var phase: Double
        var heatX: Double, heatY: Double
        var age = 0.0
        var lifted = false
        var tone = 1.0
        var wiped = false
        var wipe = 1.0
    }

    /// Some audio has been shown since the song started.
    private(set) var measured = false
    /// Samples are arriving.
    private(set) var live = false
    private var followed = [0.0, 0.0, 0.0]          // bass, mid, full band
    private var average = [0.0, 0.0]
    private(set) var swinging = false
    /// The newest loop's reach, as shares of a full swing.
    private(set) var reachX = 0.0, reachY = 0.0
    private var risingX = false, risingY = false
    private var sinceThrow = 1.0
    private var lastBeat = 0.0, beatWindow = 0.0
    private(set) var hitX = 0.0, hitY = 0.0
    /// The soft-red ticks: the furthest recent reach on each axis.
    private(set) var holdX = 0.0, holdY = 0.0
    private var heldX = 0.0, heldY = 0.0
    private var loops: [Kept] = []
    private var turn: Double
    /// How much of the resting figure shows: only before the song's first samples.
    private(set) var idle = 1.0
    private var pen: Double

    init(seed: UInt64) {
        var dice = Dice(seed)
        figure = Self.figures[dice.index(Self.figures.count)]
        let side: Double = dice.unit() < 0.5 ? -1 : 1
        let amount = 0.35 + 0.30 * dice.unit()
        turn = dice.unit()
        pen = dice.unit() * 2 * .pi
        lean = side * amount * figure.range
        sway = 0.22 * figure.range
    }

    /// The phase between the two pendulums now: the song's lean, moving a little either way as sound goes by.
    var phase: Double {
        let position = turn - turn.rounded(.down)
        return figure.open + lean + sway * (4 * abs(position - 0.5) - 1)
    }

    /// Kept loops strong enough to draw, the newest loop not included.
    var drawnKeptLoops: Int {
        let depths = keptDepths()
        return loops.indices.filter { strength(of: loops[$0], depth: depths[$0]) > 0.16 }.count
    }

    private static func unit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }

    private func steps(from loop: Kept) -> Double {
        max(abs(loop.x - reachX) / Self.stepX, abs(loop.y - reachY) / Self.stepY)
    }

    /// A kept loop's strength by how many loops are newer than it. It comes up as the newest loop moves off it.
    private static func grade(_ depth: Double) -> Double {
        let rise = min(1, max(0, depth))
        let fall = 0.80 * exp(-max(0, depth - 1) / 5.5)
        let end = min(1, max(0, (8.6 - depth) / 1.2))
        return rise * rise * (3 - 2 * rise) * fall * end
    }

    /// How far the newest loop has moved from the last kept loop of this swing, in steps (1 when there is none).
    private var lead: Double {
        guard let newest = loops.last(where: { !$0.lifted }) else { return 1 }
        return min(1, steps(from: newest))
    }

    private func keptDepths() -> [Double] {
        let ahead = lead
        var depths = [Double](repeating: 0, count: loops.count)
        var newer = 0.0
        for index in loops.indices.reversed() where !loops[index].lifted {
            depths[index] = newer + ahead
            newer += 1
        }
        return depths
    }

    private func strength(of loop: Kept, depth: Double) -> Double {
        let byAge = max(0, 1 - loop.age / Self.inkLife)
        return loop.lifted ? loop.tone * loop.wipe * byAge * byAge.squareRoot() : Self.grade(depth) * byAge
    }

    /// A new swing is being thrown, or the swing is over: the loops on the paper keep the strength they have and age faster.
    private mutating func lift(keepingNewest: Bool) {
        let ahead = lead
        var newer = 0.0
        for index in loops.indices.reversed() where !loops[index].lifted {
            loops[index].tone = 0.85 * Self.grade(newer + ahead)
            loops[index].lifted = true
            newer += 1
        }
        if keepingNewest, ahead >= 0.6, max(reachX, reachY) > 0.03 {
            loops.append(Kept(x: reachX, y: reachY, phase: phase, heatX: hitX, heatY: hitY, lifted: true, tone: 0.68))
        }
    }

    private mutating func ageInk(_ dt: Double) {
        let settled = swinging && !risingX && !risingY
        for index in loops.indices {
            loops[index].age += dt * (loops[index].lifted ? Self.liftedAgeing : 1)
            loops[index].heatX *= exp(-dt / 0.07); loops[index].heatY *= exp(-dt / 0.07)
            if loops[index].lifted, settled, !loops[index].wiped,
               abs(loops[index].x - reachX) < 0.8 * Self.stepX, abs(loops[index].y - reachY) < 0.8 * Self.stepY {
                loops[index].wiped = true
            }
            if loops[index].wiped { loops[index].wipe *= exp(-dt / 0.05) }
        }
        loops.removeAll { $0.age >= Self.inkLife || $0.wipe < 0.02 }
        let kept = loops.reduce(0) { $0 + ($1.lifted ? 0 : 1) }
        if kept > 10, let oldest = loops.firstIndex(where: { !$0.lifted }) { loops.remove(at: oldest) }
    }

    /// Advances by `dt` seconds of animation time on the analyser's measured
    /// levels. A paused or Reduce Motion frame passes `dt == 0`: nothing moves,
    /// except that a song with nothing shown yet shows its one snapshot still.
    mutating func advance(dt rawDT: Double, measured audio: VisualizationAudio) {
        let dt = rawDT.isFinite ? min(0.08, max(0, rawDT)) : 0
        guard dt > 0 else {
            if audio.available, !measured {
                measured = true; live = true; idle = 0
                followed = [Self.unit(audio.bass), Self.unit(audio.mid), Self.unit(audio.amplitude)]
                reachX = max(followed[0], Self.widthFloor * followed[2]).squareRoot()
                reachY = min(1, followed[1] / Self.fullMid).squareRoot()
                swinging = max(reachX, reachY) > 0.03
                holdX = reachX; holdY = reachY
                average = [followed[0], followed[1]]
            }
            return
        }
        guard audio.available else {
            // No samples. The swing is over and its ink fades on; nothing is measured.
            if live {
                live = false
                lift(keepingNewest: swinging)
                swinging = false; reachX = 0; reachY = 0; risingX = false; risingY = false
                followed = [0, 0, 0]; average = [0, 0]
                hitX = 0; hitY = 0; lastBeat = 0; beatWindow = 0
            }
            ageInk(dt)
            holdX *= exp(-dt / 0.2); holdY *= exp(-dt / 0.2)
            // The resting figure belongs to the moment before a song's first
            // samples; once the song has been heard it does not come back.
            if !measured {
                pen = (pen + dt * 2 * .pi / Self.idlePass).truncatingRemainder(dividingBy: 2 * .pi)
            }
            return
        }

        idle = 0
        measured = true; live = true

        let levels = [Self.unit(audio.bass), Self.unit(audio.mid), Self.unit(audio.amplitude)]
        for index in followed.indices {
            let rate = levels[index] > followed[index] ? Self.attack : Self.release
            followed[index] += (levels[index] - followed[index]) * (1 - exp(-dt * rate))
            if followed[index] < 0.000_2, levels[index] == 0 { followed[index] = 0 }
        }
        let targetX = max(followed[0], Self.widthFloor * followed[2]).squareRoot()
        let targetY = min(1, followed[1] / Self.fullMid).squareRoot()

        // A hit: a band standing well above its own short average. It cools in about a tenth of a second.
        var strikes = [0.0, 0.0]
        for band in 0..<2 {
            let level = followed[band]
            if level > 0.04 {
                strikes[band] = min(1, max(0, (level / (average[band] + 0.02) - Self.hitFrom[band]) / (Self.hitFull[band] - Self.hitFrom[band])))
            }
            average[band] += (level - average[band]) * (1 - exp(-dt / (level < average[band] ? Self.averageFall : Self.averageRise)))
        }
        hitX = max(strikes[0], hitX * exp(-dt / 0.05))
        hitY = max(strikes[1], hitY * exp(-dt / 0.05))

        // A new swing is thrown on a measured rise; a detected beat lowers the rise needed for a moment.
        sinceThrow += dt
        let beat = Self.unit(audio.beat)
        let beatRise = (beat - lastBeat) / dt
        lastBeat = beat
        if beatRise > 4, beat > 0.15 { beatWindow = 0.12 } else { beatWindow = max(0, beatWindow - dt) }
        let margin = beatWindow > 0 ? Self.beatMargin : Self.riseMargin
        var thrown = false
        if !swinging {
            thrown = max(targetX, targetY) > 0.03
        } else if sinceThrow >= Self.refractory {
            thrown = (!risingX && targetX > reachX * margin + 0.004) || (!risingY && targetY > reachY * margin + 0.004)
        }
        if thrown {
            lift(keepingNewest: swinging)
            reachX = targetX; reachY = targetY
            risingX = true; risingY = true; swinging = true; sinceThrow = 0
        }
        if swinging {
            // While a swing is thrown its reach follows the level up. After that it only falls, as far as the level fell.
            if risingX {
                reachX = max(reachX, targetX)
                if targetX < reachX * 0.99 || sinceThrow > Self.longestRise { risingX = false }
            } else {
                reachX = min(reachX, targetX)
            }
            if risingY {
                reachY = max(reachY, targetY)
                if targetY < reachY * 0.99 || sinceThrow > Self.longestRise { risingY = false }
            } else {
                reachY = min(reachY, targetY)
            }
            if max(reachX, reachY) < 0.02 {
                lift(keepingNewest: false)
                swinging = false; reachX = 0; reachY = 0; risingX = false; risingY = false
            }
        }
        // Each time the reach has fallen one step, a loop stays where the newest loop stood.
        if swinging, !risingX, !risingY {
            if let newest = loops.last(where: { !$0.lifted }) {
                if steps(from: newest) >= 1 { loops.append(Kept(x: reachX, y: reachY, phase: phase, heatX: hitX, heatY: hitY)) }
            } else {
                loops.append(Kept(x: reachX, y: reachY, phase: phase, heatX: hitX, heatY: hitY))
            }
        }
        ageInk(dt)

        // The furthest recent reach on each axis stands for a moment, then lets go; at once when the swing is over.
        if reachX >= holdX { holdX = reachX; heldX = 0 } else {
            heldX += dt
            if !swinging { holdX *= exp(-dt / 0.2) } else if heldX > Self.holdTime { holdX = max(reachX, holdX * exp(-dt / Self.holdRelease)) }
        }
        if reachY >= holdY { holdY = reachY; heldY = 0 } else {
            heldY += dt
            if !swinging { holdY *= exp(-dt / 0.2) } else if heldY > Self.holdTime { holdY = max(reachY, holdY * exp(-dt / Self.holdRelease)) }
        }
        turn += dt * followed[2] / 30
    }

    // MARK: Drawing

    /// Centred on the scene: a full swing reaches as wide as the bars (36.5% of
    /// the width each side) and as tall as the disc (40% of the height).
    struct Layout: Equatable, Sendable {
        var centre: CGPoint
        var halfWidth: CGFloat, halfHeight: CGFloat
        var disc: CGRect
    }

    static func layout(size: CGSize) -> Layout {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.height * 0.40, size.width * 0.24)
        return Layout(centre: centre, halfWidth: size.width * 0.365, halfHeight: size.height * 0.40,
                      disc: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
    }

    private func point(at angle: Double, x: CGFloat, y: CGFloat, phase: Double, centre: CGPoint) -> CGPoint {
        CGPoint(x: centre.x + x * CGFloat(sin(figure.across * angle + phase)), y: centre.y - y * CGFloat(sin(figure.up * angle)))
    }

    /// The points of one closed pass with half-extents `x` and `y`.
    func outline(x: CGFloat, y: CGFloat, phase: Double, centre: CGPoint) -> [CGPoint] {
        (0..<figure.points).map { index in
            point(at: 2 * Double.pi * Double(index) / Double(figure.points), x: x, y: y, phase: phase, centre: centre)
        }
    }

    /// A smooth closed line through `points`: quadratic arcs from midpoint to midpoint.
    private static func closedCurve(_ points: [CGPoint]) -> Path {
        var path = Path()
        let count = points.count
        guard count >= 3 else { return path }
        func middle(_ first: CGPoint, _ second: CGPoint) -> CGPoint { CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2) }
        path.move(to: middle(points[count - 1], points[0]))
        for index in 0..<count {
            path.addQuadCurve(to: middle(points[index], points[(index + 1) % count]), control: points[index])
        }
        path.closeSubpath()
        return path
    }

    func draw(in context: inout GraphicsContext, size: CGSize, place: EffectPlace) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        let layout = Self.layout(size: size)
        let centre = layout.centre, halfW = layout.halfWidth, halfH = layout.halfHeight
        let radius = layout.disc.width / 2
        let paleBlue = SpectrumBarsRenderer.paleBlue, yellowInk = SpectrumBarsRenderer.yellow
        context.fill(Path(ellipseIn: layout.disc), with: .color(place == .room ? SpectrumBarsRenderer.roomDisc : SpectrumBarsRenderer.stageDisc))
        // Ink is brighter where it crosses the disc, as the oscilloscope's trace is: one stroke, two tones.
        let far = max(size.width, size.height)
        func ink(_ path: Path, _ color: Color, _ strength: Double, _ width: CGFloat, in target: inout GraphicsContext) {
            guard strength > 0.004 else { return }
            let inner = color.opacity(min(1, strength)), outer = color.opacity(strength * 0.80)
            let edge = radius / far
            let tones = Gradient(stops: [.init(color: inner, location: 0), .init(color: inner, location: edge),
                                         .init(color: outer, location: edge), .init(color: outer, location: 1)])
            target.stroke(path, with: .radialGradient(tones, center: centre, startRadius: 0, endRadius: far),
                          style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
        /// A loop in pale blue. While a hit is arriving its ends are yellow on
        /// the axis that was hit harder; as the hit cools the yellow draws back
        /// to the very ends and is gone. Two inks side by side, never one over the other.
        func inkLoop(_ points: [CGPoint], x: CGFloat, y: CGFloat, strength: Double, heatX: Double, heatY: Double, width: CGFloat) {
            guard strength > 0.004 else { return }
            let path = Self.closedCurve(points)
            var ends = Path()
            let (heat, sideways) = heatX >= heatY ? (heatX, true) : (heatY, false)
            if heat > 0.15 {
                let warm = min(1, (heat - 0.15) / 0.45)
                let beyond = CGFloat(1 - 0.08 * warm * warm * (3 - 2 * warm))
                for side in [-1.0, 1.0] as [CGFloat] {
                    if sideways {
                        ends.addRect(CGRect(x: side > 0 ? centre.x + beyond * x : 0, y: 0,
                                            width: side > 0 ? size.width : centre.x - beyond * x, height: size.height))
                    } else {
                        ends.addRect(CGRect(x: 0, y: side > 0 ? centre.y + beyond * y : 0,
                                            width: size.width, height: side > 0 ? size.height : centre.y - beyond * y))
                    }
                }
            }
            guard !ends.isEmpty else {
                ink(path, paleBlue, strength, width, in: &context)
                return
            }
            var blue = context, yellow = context
            blue.clip(to: ends, options: .inverse)
            yellow.clip(to: ends)
            ink(path, paleBlue, strength, width, in: &blue)
            ink(path, yellowInk, min(1, strength * 1.15), width, in: &yellow)
        }

        // The kept loops, oldest first. No ghosts: a loop is a line or it is gone.
        let depths = keptDepths()
        for (index, loop) in loops.enumerated() {
            let strength = strength(of: loop, depth: depths[index])
            guard strength > 0.16 else { continue }
            let width = loop.lifted ? 1.3 : 1.3 + 0.2 * max(0, 1 - max(0, depths[index] - 1) / 3)
            let loopX = CGFloat(loop.x) * halfW, loopY = CGFloat(loop.y) * halfH
            inkLoop(outline(x: loopX, y: loopY, phase: loop.phase, centre: centre),
                    x: loopX, y: loopY, strength: strength, heatX: loop.heatX, heatY: loop.heatY, width: width)
        }

        // The newest loop: the figure at the reach measured now.
        let x = CGFloat(reachX) * halfW, y = CGFloat(reachY) * halfH
        let presence = swinging ? Double(min(1, max(x, y) / 10)) : 0
        if presence > 0 {
            inkLoop(outline(x: x, y: y, phase: phase, centre: centre), x: x, y: y,
                    strength: 0.95 * presence, heatX: hitX, heatY: hitY, width: 1.6)
        }

        // Soft red: the furthest recent reach on each axis.
        let softRed = SpectrumBarsRenderer.softRed.opacity(0.9)
        if holdX > 0.05 {
            for side in [-1.0, 1.0] as [CGFloat] {
                let tickX = centre.x + side * (CGFloat(holdX) * halfW + 9)
                context.fill(Path(roundedRect: CGRect(x: tickX - 1, y: centre.y - 7, width: 2, height: 14), cornerRadius: 1), with: .color(softRed))
            }
        }
        if holdY > 0.05 {
            for side in [-1.0, 1.0] as [CGFloat] {
                let tickY = centre.y + side * (CGFloat(holdY) * halfH + 9)
                context.fill(Path(roundedRect: CGRect(x: centre.x - 7, y: tickY - 1, width: 14, height: 2), cornerRadius: 1), with: .color(softRed))
            }
        }

        func drawPen(at point: CGPoint, strength: Double) {
            guard strength > 0.01 else { return }
            context.fill(Path(ellipseIn: CGRect(x: point.x - 2.6, y: point.y - 2.6, width: 5.2, height: 5.2)), with: .color(paleBlue.opacity(0.9 * strength)))
            context.stroke(Path(ellipseIn: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)), with: .color(paleBlue.opacity(0.45 * strength)), lineWidth: 1)
        }

        // Before the song's first samples: its figure at one fixed small size,
        // dim, and the pen going slowly round it. Nothing here is measured.
        if idle > 0.01 {
            let idleX = CGFloat(Self.idleX) * halfW, idleY = CGFloat(Self.idleY) * halfH
            ink(Self.closedCurve(outline(x: idleX, y: idleY, phase: phase, centre: centre)), paleBlue, 0.36 * idle, 1.3, in: &context)
            func spot(_ angle: Double) -> CGPoint {
                CGPoint(x: centre.x + idleX * CGFloat(sin(figure.across * angle + phase)), y: centre.y - idleY * CGFloat(sin(figure.up * angle)))
            }
            let parts = 4, piece = 0.16
            for part in 0..<parts {
                var trail = Path()
                let from = pen - piece * Double(parts - part), steps = 8
                trail.move(to: spot(from))
                for step in 1...steps { trail.addLine(to: spot(from + piece * Double(step) / Double(steps))) }
                ink(trail, paleBlue, 0.17 * Double(part + 1) * idle, 1.5, in: &context)
            }
            drawPen(at: spot(pen), strength: idle)
        }

        // The pen at rest in the middle, when samples arrive but are silent: the swing has closed on it.
        drawPen(at: centre, strength: (1 - presence) * (live ? 1 : measured ? 0.5 : 0))
    }
}

/// Per-stage state: the shared signal clock (for the measured levels and
/// animation time) and the song's figure, made again for each song.
@MainActor final class HarmonographStageModel {
    private let clock = VisualizationClock()
    private(set) var figure = HarmonographSongFigure(seed: 0)
    private var lastTime: Double?
    private var started = false
    private var trackID: String?

    func resetFrameDate() { clock.resetFrameDate() }

    /// Starts over inline on a track change so a paused or frozen stage never
    /// keeps drawing the previous song's figure (`onChange` runs after the frame).
    func figure(at date: Date, trackID: String?, seed: UInt64, animated: Bool, levels: AudioLevels, playing: Bool,
                captureStaticSignal: Bool) -> HarmonographSongFigure {
        if !started || trackID != self.trackID {
            started = true
            self.trackID = trackID
            clock.resetSignal()
            figure = HarmonographSongFigure(seed: seed)
            lastTime = nil
        }
        let frame = clock.frame(at: date, animated: animated, levels: levels, playing: playing,
                                captureStaticSignal: captureStaticSignal)
        let dt = animated ? max(0, frame.time - (lastTime ?? frame.time)) : 0
        lastTime = frame.time
        figure.advance(dt: dt, measured: frame.measured)
        return figure
    }
}

struct HarmonographStage: View {
    let isPlaying: Bool
    let isActive: Bool
    let reduceMotion: Bool
    let lowPower: Bool
    let seed: UInt64
    let trackID: String?
    var place: EffectPlace = .room
    let signal: @MainActor () -> AudioLevels
    @State private var model = HarmonographStageModel()

    private var animate: Bool { isPlaying && isActive && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: lowPower ? 1.0 / 30 : 1.0 / 60, paused: !animate)) { timeline in
            let levels = isPlaying && isActive ? signal() : AudioLevels()
            let figure = model.figure(at: timeline.date, trackID: trackID, seed: seed, animated: animate,
                                      levels: levels, playing: isPlaying,
                                      captureStaticSignal: reduceMotion && isPlaying && isActive)
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                figure.draw(in: &context, size: size, place: place)
            }
            .allowsHitTesting(false)
        }
        .onChange(of: animate) { _, _ in model.resetFrameDate() }
    }
}
