import SwiftUI

// Bauhaus Composition: an original geometric arrangement on cream paper in the
// app's palette. Each song gets its own deterministic layout from its seed:
// a large red disc, a blue square, a yellow triangle, one or two black bars,
// a half disc or quarter circle, thin ink lines, small dots and sometimes a
// thin ring, placed on a loose 3 x 3 grid.
//
// This is an audio-reactive ambience, not a signal display. Every moving part
// is bound to one measured driver: bass scales the red disc (up to +12 %), mid
// turns the blue square a few degrees, treble widens the line spacing and
// brightens the dots, a rising beat gives one element a short offset that
// relaxes in about a quarter second, and energy makes the whole composition
// breathe very slightly. Unavailable audio leaves every audio term at zero;
// only a slow seeded drift of a few points over tens of seconds remains.
// Animation time only advances while playing, active and without reduced
// motion, so paused, background and reduced-motion frames are fully frozen.

/// SplitMix64: a small, fully deterministic generator for layout decisions.
struct BauhausRandom: Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }

    mutating func range(_ lower: Double, _ upper: Double) -> Double {
        lower + (upper - lower) * unit()
    }

    mutating func index(_ count: Int) -> Int {
        guard count > 1 else { return 0 }
        return Int(next() % UInt64(count))
    }

    mutating func chance(_ probability: Double) -> Bool {
        unit() < probability
    }
}

struct BauhausPrimitive: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case disc, square, triangle, bar, halfDisc, quarterCircle, ring, lines, dots
    }

    enum Ink: Equatable, Sendable {
        case red, blue, yellow, ink
    }

    /// The single measured quantity that may move this primitive.
    enum Driver: Equatable, Sendable {
        case ambient, bass, mid, treble, beat
    }

    var kind: Kind
    var ink: Ink
    var driver: Driver
    /// Center in the unit square of the composition rect.
    var x: Double
    var y: Double
    /// Main dimension in multiples of the composition side: radius for discs,
    /// arcs, rings and dots; side for the square and triangle; length for bars
    /// and lines.
    var size: Double
    /// Bar thickness, ring and line width, in multiples of the composition side.
    var thickness: Double = 0
    /// Distance between repeated lines or dots, in multiples of the side.
    var spacing: Double = 0
    var count: Int = 1
    /// Radians.
    var rotation: Double = 0
    var driftPhase: Double = 0
    /// Seconds for one full ambient drift loop.
    var driftPeriod: Double = 40
    /// Direction of the beat offset, radians.
    var kickAngle: Double = 0
}

/// A faint fixed paper fibre in unit canvas coordinates.
struct BauhausGrainStroke: Equatable, Sendable {
    var x: Double
    var y: Double
    /// In multiples of the shorter canvas side.
    var length: Double
    var angle: Double
    var opacity: Double
}

/// Pure, seed-derived layout. Coordinates are size independent; the renderer
/// maps them into the canvas.
struct BauhausLayout: Equatable, Sendable {
    static let maximumPrimitives = 9
    static let grainCount = 32

    let seed: UInt64
    let primitives: [BauhausPrimitive]
    let grain: [BauhausGrainStroke]

    init(seed: UInt64) {
        var random = BauhausRandom(seed: seed)
        var cells = Array(0..<9)
        for index in stride(from: cells.count - 1, to: 0, by: -1) {
            cells.swapAt(index, random.index(index + 1))
        }
        // 0: triangle, 1: arc, 2: first bar.
        let kickTarget = random.index(3)

        let discSpot = Self.spot(cell: cells[0], random: &random)
        let disc = BauhausPrimitive(kind: .disc, ink: .red, driver: .bass, x: discSpot.x, y: discSpot.y,
                                    size: random.range(0.17, 0.23))

        let squareSpot = Self.spot(cell: cells[1], random: &random)
        let squareTurns = [0, 0.2618, -0.2618, Double.pi / 4]
        let square = BauhausPrimitive(kind: .square, ink: .blue, driver: .mid, x: squareSpot.x, y: squareSpot.y,
                                      size: random.range(0.19, 0.26), rotation: squareTurns[random.index(squareTurns.count)])

        let triangleSpot = Self.spot(cell: cells[2], random: &random)
        let triangleTurns = [0, Double.pi, Double.pi / 2, -Double.pi / 2]
        let triangleTurn = triangleTurns[random.index(triangleTurns.count)] + random.range(-0.08, 0.08)
        let triangle = BauhausPrimitive(kind: .triangle, ink: .yellow, driver: kickTarget == 0 ? .beat : .ambient,
                                        x: triangleSpot.x, y: triangleSpot.y, size: random.range(0.2, 0.28),
                                        rotation: triangleTurn)

        let arcSpot = Self.spot(cell: cells[3], random: &random)
        let arcKind: BauhausPrimitive.Kind = random.chance(0.5) ? .halfDisc : .quarterCircle
        let arcInks: [BauhausPrimitive.Ink] = [.yellow, .blue, .ink]
        let arcInk = arcInks[random.index(arcInks.count)]
        let arc = BauhausPrimitive(kind: arcKind, ink: arcInk, driver: kickTarget == 1 ? .beat : .ambient,
                                   x: arcSpot.x, y: arcSpot.y, size: random.range(0.11, 0.16),
                                   rotation: Double(random.index(4)) * Double.pi / 2)

        var bars: [BauhausPrimitive] = []
        let barTurns = [0, Double.pi / 2, Double.pi / 6, -Double.pi / 6, Double.pi / 4]
        let barCount = random.chance(0.5) ? 2 : 1
        for index in 0..<barCount {
            let driver: BauhausPrimitive.Driver = kickTarget == 2 && index == 0 ? .beat : .ambient
            bars.append(BauhausPrimitive(kind: .bar, ink: .ink, driver: driver,
                                         x: random.range(0.25, 0.75), y: random.range(0.2, 0.8),
                                         size: random.range(0.5, 0.85), thickness: random.range(0.02, 0.036),
                                         rotation: barTurns[random.index(barTurns.count)]))
        }

        let linesSpot = Self.spot(cell: cells[4], random: &random)
        let lineTurns = [0, Double.pi / 2, Double.pi / 4, -Double.pi / 4]
        let lines = BauhausPrimitive(kind: .lines, ink: .ink, driver: .treble, x: linesSpot.x, y: linesSpot.y,
                                     size: random.range(0.2, 0.32), thickness: 0.004, spacing: 0.024,
                                     count: 3 + random.index(3), rotation: lineTurns[random.index(lineTurns.count)])

        let dotsSpot = Self.spot(cell: cells[5], random: &random)
        let dotInks: [BauhausPrimitive.Ink] = [.red, .ink]
        let dots = BauhausPrimitive(kind: .dots, ink: dotInks[random.index(dotInks.count)], driver: .treble,
                                    x: dotsSpot.x, y: dotsSpot.y, size: random.range(0.011, 0.017),
                                    spacing: random.range(0.042, 0.055), count: 3 + random.index(3),
                                    rotation: random.chance(0.5) ? 0 : Double.pi / 2)

        let ringSpot = Self.spot(cell: cells[6], random: &random)
        let hasRing = random.chance(0.45)
        let ring = BauhausPrimitive(kind: .ring, ink: .ink, driver: .ambient, x: ringSpot.x, y: ringSpot.y,
                                    size: random.range(0.06, 0.1), thickness: 0.008)

        // Back to front. The disc and square trade places for half the songs.
        var shapes: [BauhausPrimitive] = [arc]
        if random.chance(0.5) {
            shapes.append(contentsOf: [disc, square])
        } else {
            shapes.append(contentsOf: [square, disc])
        }
        shapes.append(contentsOf: bars)
        shapes.append(triangle)
        if hasRing { shapes.append(ring) }
        shapes.append(lines)
        shapes.append(dots)
        for index in shapes.indices {
            shapes[index].driftPhase = random.range(0, 2 * Double.pi)
            shapes[index].driftPeriod = random.range(28, 64)
            shapes[index].kickAngle = random.range(0, 2 * Double.pi)
        }

        var strokes: [BauhausGrainStroke] = []
        strokes.reserveCapacity(Self.grainCount)
        for _ in 0..<Self.grainCount {
            strokes.append(BauhausGrainStroke(x: random.range(0.03, 0.97), y: random.range(0.03, 0.97),
                                              length: random.range(0.008, 0.03), angle: random.range(-0.4, 0.4),
                                              opacity: random.range(0.018, 0.04)))
        }

        self.seed = seed
        primitives = shapes
        grain = strokes
    }

    /// A jittered center of one cell of the loose 3 x 3 grid.
    private static func spot(cell: Int, random: inout BauhausRandom) -> (x: Double, y: Double) {
        let column = Double(cell % 3)
        let row = Double(cell / 3)
        let x = (column + 0.5) / 3 + random.range(-0.06, 0.06)
        let y = (row + 0.5) / 3 + random.range(-0.06, 0.06)
        return (x, y)
    }
}

/// The eased audio terms. Every value is in [0, 1]; all zero means the plain
/// ambient composition.
struct BauhausDrive: Equatable, Sendable {
    var bass = 0.0
    var mid = 0.0
    var treble = 0.0
    var energy = 0.0
    var kick = 0.0

    static let zero = BauhausDrive()

    static func unit(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    var sanitized: BauhausDrive {
        BauhausDrive(bass: Self.unit(bass), mid: Self.unit(mid), treble: Self.unit(treble),
                     energy: Self.unit(energy), kick: Self.unit(kick))
    }
}

/// Pure motion state between frames. `step` only changes anything for a
/// positive, finite animation-time delta, so frozen frames neither ease nor
/// decay. Unavailable audio clears every audio term instead of inventing one.
struct BauhausMotion: Sendable {
    /// Per-second easing rate of the scalar drivers (calm, about 0.2 s).
    static let followRate = 5.0
    static let kickAttack = 45.0
    /// Per-second release of the beat kick; under 0.1 after about 0.25 s.
    static let kickRelease = 12.0
    /// A rising beat must reach this before it counts, so tiny wobbles never kick.
    static let kickFloor = 0.08
    /// Beat value that gives a full kick. The incoming beat is already scaled
    /// by the player volume and eased by the clock (about 0.7 peak at full
    /// volume), so the kick fires on every rising edge, not above a fixed level.
    static let kickReference = 0.5

    private(set) var drive = BauhausDrive.zero
    /// True once real audio has shaped the drive since the last reset.
    private(set) var holdsSignal = false
    private var impulse = 0.0
    private var armed = true
    private var kicking = false
    private var previousBeat = 0.0

    mutating func reset() {
        self = BauhausMotion()
    }

    /// Reduced motion with playback: one real, static snapshot of the measured
    /// levels, without a kick. Later calls keep that snapshot.
    mutating func capture(_ audio: VisualizationAudio) {
        guard audio.available, !holdsSignal else { return }
        drive = BauhausDrive(bass: audio.bass, mid: audio.mid, treble: audio.treble,
                             energy: audio.energy, kick: 0).sanitized
        impulse = 0
        armed = false
        kicking = false
        previousBeat = BauhausDrive.unit(audio.beat)
        holdsSignal = true
    }

    @discardableResult
    mutating func step(dt rawDT: Double, audio: VisualizationAudio) -> BauhausDrive {
        let dt = rawDT.isFinite ? max(0, rawDT) : 0
        guard dt > 0 else { return drive }
        guard audio.available else {
            reset()
            return drive
        }
        let follow = 1 - exp(-dt * Self.followRate)
        drive.bass += (BauhausDrive.unit(audio.bass) - drive.bass) * follow
        drive.mid += (BauhausDrive.unit(audio.mid) - drive.mid) * follow
        drive.treble += (BauhausDrive.unit(audio.treble) - drive.treble) * follow
        drive.energy += (BauhausDrive.unit(audio.energy) - drive.energy) * follow

        // Each rising edge of the beat is one kick that follows the rise to
        // its peak. A held or decaying beat never retriggers; any fall rearms.
        impulse *= exp(-dt * Self.kickRelease)
        let beat = BauhausDrive.unit(audio.beat)
        if beat > previousBeat {
            if armed, beat >= Self.kickFloor {
                armed = false
                kicking = true
            }
            if kicking {
                impulse = max(impulse, min(1, beat / Self.kickReference))
            }
        } else if beat < previousBeat {
            armed = true
            kicking = false
        }
        previousBeat = beat
        drive.kick += (impulse - drive.kick) * (1 - exp(-dt * Self.kickAttack))
        drive = drive.sanitized
        holdsSignal = true
        return drive
    }
}

/// One primitive placed in canvas points for a given time and drive.
struct BauhausPose: Equatable, Sendable {
    var kind: BauhausPrimitive.Kind
    var ink: BauhausPrimitive.Ink
    var center: CGPoint
    var size: CGFloat
    var thickness: CGFloat
    var spacing: CGFloat
    var count: Int
    /// Radians.
    var rotation: Double
    var opacity: Double
    /// Radius of a circle around `center` that contains the whole primitive.
    var radius: CGFloat

    var bounds: CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}

enum BauhausCompositionRenderer {
    /// Bass scale headroom of the red disc.
    static let bassScale = 0.12
    /// Mid rotation of the blue square, radians (about 8 degrees).
    static let midTurn = 0.14
    /// Beat offset in multiples of the composition side.
    static let kickDistance = 0.035
    /// Upper bound of the ambient drift, in points.
    static let maximumDrift = 5.0

    /// The area the layout's unit square maps to.
    static func compositionRect(size: CGSize) -> CGRect {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return .zero }
        let margin = min(size.width, size.height) * 0.08
        return CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
    }

    /// Pure placement of every primitive. Malformed time or drive values are
    /// treated as zero; every pose is finite and stays inside the canvas.
    static func poses(layout: BauhausLayout, size: CGSize, time: Double, drive: BauhausDrive) -> [BauhausPose] {
        let rect = compositionRect(size: size)
        guard !rect.isEmpty else { return [] }
        let audio = drive.sanitized
        let clock = time.isFinite ? time : 0
        let side = Double(min(rect.width, rect.height))
        let drift = min(maximumDrift, 0.008 * Double(min(size.width, size.height)))
        return layout.primitives.prefix(BauhausLayout.maximumPrimitives).map { primitive in
            pose(for: primitive, rect: rect, canvas: size, side: side, time: clock, audio: audio, drift: drift)
        }
    }

    private static func pose(for primitive: BauhausPrimitive, rect: CGRect, canvas: CGSize, side: Double,
                             time: Double, audio: BauhausDrive, drift: Double) -> BauhausPose {
        func bounded(_ value: Double, _ upper: Double) -> Double {
            value.isFinite ? min(upper, max(0, value)) : 0
        }
        let breath = 1 + 0.02 * audio.energy
        let spread = 1 + 0.012 * audio.energy
        var size = bounded(primitive.size, 0.9) * side * breath
        var spacing = bounded(primitive.spacing, 0.1) * side * breath
        // Hairlines stay visible on large stages and inside tiny ones.
        let hairline = min(0.5, 0.01 * side)
        let thickness = max(hairline, bounded(primitive.thickness, 0.1) * side * breath)
        var rotation = primitive.rotation.isFinite ? primitive.rotation : 0
        var opacity = 1.0
        var offsetX = 0.0
        var offsetY = 0.0
        switch primitive.driver {
        case .bass:
            size *= 1 + bassScale * audio.bass
        case .mid:
            rotation += midTurn * audio.mid
        case .treble:
            if primitive.kind == .dots {
                opacity = 0.6 + 0.4 * audio.treble
            } else {
                spacing *= 1 + 0.5 * audio.treble
            }
        case .beat:
            let angle = primitive.kickAngle.isFinite ? primitive.kickAngle : 0
            offsetX = cos(angle) * kickDistance * side * audio.kick
            offsetY = sin(angle) * kickDistance * side * audio.kick
        case .ambient:
            break
        }

        // Ambient drift: a slow closed loop, phase and period from the seed.
        let period = primitive.driftPeriod.isFinite && primitive.driftPeriod > 1 ? primitive.driftPeriod : 40
        let cycle = (time / period).truncatingRemainder(dividingBy: 1)
        let phase = (primitive.driftPhase.isFinite ? primitive.driftPhase : 0) + 2 * Double.pi * cycle
        offsetX += drift * sin(phase)
        offsetY += drift * 0.7 * cos(phase)
        rotation += 0.006 * sin(phase)

        let count = min(8, max(1, primitive.count))
        let unitX = bounded(primitive.x, 1)
        let unitY = bounded(primitive.y, 1)
        let pivotX = Double(canvas.width) / 2
        let pivotY = Double(canvas.height) / 2
        let baseX = Double(rect.minX) + unitX * Double(rect.width)
        let baseY = Double(rect.minY) + unitY * Double(rect.height)
        let radius = boundingRadius(kind: primitive.kind, size: size, thickness: thickness, spacing: spacing, count: count)
        let x = clampCenter(pivotX + (baseX - pivotX) * spread + offsetX, radius: radius, extent: Double(canvas.width))
        let y = clampCenter(pivotY + (baseY - pivotY) * spread + offsetY, radius: radius, extent: Double(canvas.height))
        return BauhausPose(kind: primitive.kind, ink: primitive.ink, center: CGPoint(x: x, y: y),
                           size: CGFloat(size), thickness: CGFloat(thickness), spacing: CGFloat(spacing),
                           count: count, rotation: rotation, opacity: opacity, radius: CGFloat(radius))
    }

    static func boundingRadius(kind: BauhausPrimitive.Kind, size: Double, thickness: Double,
                               spacing: Double, count: Int) -> Double {
        let span = Double(max(0, count - 1)) * spacing / 2
        switch kind {
        case .disc, .halfDisc, .quarterCircle:
            return size
        case .square:
            return size * 2.0.squareRoot() / 2
        case .triangle:
            return size / 3.0.squareRoot()
        case .bar:
            return hypot(size / 2, thickness / 2)
        case .ring:
            return size + thickness / 2
        case .lines:
            return hypot(size / 2, span + thickness)
        case .dots:
            return span + size
        }
    }

    private static func clampCenter(_ value: Double, radius: Double, extent: Double) -> Double {
        let lower = radius + 1
        let upper = extent - radius - 1
        guard value.isFinite, radius.isFinite, lower <= upper else { return extent / 2 }
        return min(upper, max(lower, value))
    }

    /// Shared production/offscreen entry point.
    static func draw(in context: inout GraphicsContext, size: CGSize, layout: BauhausLayout,
                     time: Double, drive: BauhausDrive, glow: Bool) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(paper))
        drawGrain(in: &context, size: size, grain: layout.grain)
        let placed = poses(layout: layout, size: size, time: time, drive: drive)
        if glow { drawShadow(in: &context, poses: placed, size: size) }
        // Overlaps darken like overprinted ink rather than covering each other.
        context.blendMode = .multiply
        for pose in placed {
            drawPose(pose, in: &context)
        }
    }

    private static func drawGrain(in context: inout GraphicsContext, size: CGSize, grain: [BauhausGrainStroke]) {
        let shortSide = min(size.width, size.height)
        for mark in grain.prefix(BauhausLayout.grainCount) {
            guard mark.x.isFinite, mark.y.isFinite, mark.length.isFinite, mark.angle.isFinite, mark.opacity.isFinite else { continue }
            let start = CGPoint(x: CGFloat(mark.x) * size.width, y: CGFloat(mark.y) * size.height)
            let length = CGFloat(min(0.05, max(0, mark.length))) * shortSide
            let end = CGPoint(x: start.x + CGFloat(cos(mark.angle)) * length, y: start.y + CGFloat(sin(mark.angle)) * length)
            var fibre = Path()
            fibre.move(to: start)
            fibre.addLine(to: end)
            context.stroke(fibre, with: .color(ink.opacity(min(0.06, max(0, mark.opacity)))), lineWidth: 0.5)
        }
    }

    /// A faint soft shadow under the solid shapes, only with glow enabled.
    private static func drawShadow(in context: inout GraphicsContext, poses: [BauhausPose], size: CGSize) {
        let shortSide = min(size.width, size.height)
        let blur = max(1, shortSide * 0.014)
        let drop = max(0.5, shortSide * 0.006)
        let shade = ink.opacity(0.09)
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: blur))
            for pose in poses {
                guard let shape = Self.localPath(for: pose) else { continue }
                layer.fill(shape.applying(Self.placement(pose)).offsetBy(dx: 0, dy: drop), with: .color(shade))
            }
        }
    }

    private static func drawPose(_ pose: BauhausPose, in context: inout GraphicsContext) {
        let transform = placement(pose)
        let color = tone(pose.ink)
        if let shape = localPath(for: pose) {
            context.fill(shape.applying(transform), with: .color(color.opacity(0.95 * pose.opacity)))
            return
        }
        switch pose.kind {
        case .ring:
            let radius = pose.size
            let circle = Path(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
            context.stroke(circle.applying(transform), with: .color(color.opacity(0.85 * pose.opacity)),
                           lineWidth: pose.thickness)
        case .lines:
            var rules = Path()
            for index in 0..<pose.count {
                let offset = (CGFloat(index) - CGFloat(pose.count - 1) / 2) * pose.spacing
                rules.move(to: CGPoint(x: -pose.size / 2, y: offset))
                rules.addLine(to: CGPoint(x: pose.size / 2, y: offset))
            }
            context.stroke(rules.applying(transform), with: .color(color.opacity(0.85 * pose.opacity)),
                           lineWidth: pose.thickness)
        case .dots:
            var marks = Path()
            for index in 0..<pose.count {
                let offset = (CGFloat(index) - CGFloat(pose.count - 1) / 2) * pose.spacing
                marks.addEllipse(in: CGRect(x: offset - pose.size, y: -pose.size, width: pose.size * 2, height: pose.size * 2))
            }
            context.fill(marks.applying(transform), with: .color(color.opacity(0.95 * pose.opacity)))
        default:
            break
        }
    }

    /// Solid shapes around the origin; nil for stroked or repeated primitives.
    private static func localPath(for pose: BauhausPose) -> Path? {
        let size = pose.size
        switch pose.kind {
        case .disc:
            return Path(ellipseIn: CGRect(x: -size, y: -size, width: size * 2, height: size * 2))
        case .square:
            return Path(CGRect(x: -size / 2, y: -size / 2, width: size, height: size))
        case .triangle:
            var path = Path()
            let radius = size / CGFloat(3.0.squareRoot())
            for vertex in 0..<3 {
                let angle = -Double.pi / 2 + Double(vertex) * 2 * Double.pi / 3
                let point = CGPoint(x: radius * CGFloat(cos(angle)), y: radius * CGFloat(sin(angle)))
                if vertex == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            path.closeSubpath()
            return path
        case .bar:
            return Path(CGRect(x: -size / 2, y: -pose.thickness / 2, width: size, height: pose.thickness))
        case .halfDisc:
            return wedge(radius: size, degrees: 180)
        case .quarterCircle:
            return wedge(radius: size, degrees: 90)
        case .ring, .lines, .dots:
            return nil
        }
    }

    /// A circular sector with its corner at the origin.
    private static func wedge(radius: CGFloat, degrees: Double) -> Path {
        var path = Path()
        path.move(to: .zero)
        path.addRelativeArc(center: .zero, radius: radius, startAngle: .degrees(0), delta: .degrees(degrees))
        path.closeSubpath()
        return path
    }

    private static func placement(_ pose: BauhausPose) -> CGAffineTransform {
        CGAffineTransform(rotationAngle: CGFloat(pose.rotation))
            .concatenating(CGAffineTransform(translationX: pose.center.x, y: pose.center.y))
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }

    private static var paper: Color { hex(0xF1EBDD) }
    private static var ink: Color { hex(0x202020) }

    private static func tone(_ ink: BauhausPrimitive.Ink) -> Color {
        switch ink {
        case .red: hex(0xB83228)
        case .blue: hex(0x245CA8)
        case .yellow: hex(0xE4BC35)
        case .ink: hex(0x202020)
        }
    }
}

struct BauhausFrame: Equatable, Sendable {
    var time: Double
    var drive: BauhausDrive
}

/// Per-stage frame state: the shared visualization clock (frozen frames have
/// no time delta) plus the eased drivers, advanced by animation time only.
@MainActor final class BauhausCompositionStageModel {
    private let clock = VisualizationClock()
    private var motion = BauhausMotion()
    private var lastTime: Double?
    private var cachedLayout: BauhausLayout?
    private var started = false
    private var trackID: String?

    func resetFrameDate() { clock.resetFrameDate() }

    func reset() {
        clock.resetSignal()
        motion.reset()
        lastTime = nil
    }

    func layout(seed: UInt64) -> BauhausLayout {
        if let cached = cachedLayout, cached.seed == seed { return cached }
        let layout = BauhausLayout(seed: seed)
        cachedLayout = layout
        return layout
    }

    /// A changed track resets inside the frame itself, so even a frozen
    /// (paused, background or reduced-motion) render never shows the new
    /// song's layout shaped by the previous song's drive.
    func frame(at date: Date, trackID: String?, animated: Bool, levels: AudioLevels, playing: Bool,
               captureStaticSignal: Bool) -> BauhausFrame {
        if !started || trackID != self.trackID {
            started = true
            self.trackID = trackID
            reset()
        }
        let frame = clock.frame(at: date, animated: animated, levels: levels, playing: playing,
                                captureStaticSignal: captureStaticSignal)
        let dt = animated ? max(0, frame.time - (lastTime ?? frame.time)) : 0
        lastTime = frame.time
        if !animated, captureStaticSignal { motion.capture(frame.audio) }
        let drive = motion.step(dt: dt, audio: frame.audio)
        return BauhausFrame(time: frame.time, drive: drive)
    }
}

struct BauhausCompositionStage: View {
    let isPlaying: Bool
    let isActive: Bool
    let reduceMotion: Bool
    let lowPower: Bool
    let glow: Bool
    let seed: UInt64
    let trackID: String?
    let signal: @MainActor () -> AudioLevels
    @State private var model = BauhausCompositionStageModel()

    private var animate: Bool { isPlaying && isActive && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: lowPower ? 1.0 / 30 : 1.0 / 60, paused: !animate)) { timeline in
            let levels = isPlaying && isActive ? signal() : AudioLevels()
            let frame = model.frame(at: timeline.date, trackID: trackID, animated: animate, levels: levels,
                                    playing: isPlaying, captureStaticSignal: reduceMotion && isPlaying && isActive)
            let layout = model.layout(seed: seed)
            Canvas(opaque: true, rendersAsynchronously: false) { context, size in
                BauhausCompositionRenderer.draw(in: &context, size: size, layout: layout, time: frame.time,
                                                drive: frame.drive, glow: glow)
            }
            .allowsHitTesting(false)
        }
        .onChange(of: animate) { _, _ in model.resetFrameDate() }
    }
}
