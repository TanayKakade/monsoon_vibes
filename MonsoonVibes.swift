// MonsoonVibes — a living rain season on your Mac desktop.
//  🌧️ Rain in three depth layers that splashes on your window tops and ripples in puddles at the bottom
//  ⛈️ A weather system: clear → drizzle → steady rain → downpour → thunderstorm (or pick one from the menu)
//  ⚡ Lightning flashes and bolts in storms
//  ☁️ Dark rolling clouds, drifting mist, puddles that fill up with little paper boats floating on them
//  🌈 A rainbow after the rain ends, in daylight
//  🐸 Frogs that sit on your windows, hop around and ribbit (more active in rain and at night)
//  ☂️ An umbrella that follows your mouse and keeps the rain off. Swipe the mouse quickly to gust the rain sideways.
//  🌗 It follows the real time of day: grey day, warm golden hour, deep blue night (computed from your location)
// Build: use make_app.sh to get a double-clickable app.

import Cocoa
import SpriteKit
import CoreLocation

// MARK: - Settings

enum Feature: Int, CaseIterable { case lightning, clouds, mist, puddles, rainbow, frogs, umbrella, mouse, tint }

enum Cfg {
    static var enabled = [Bool](repeating: true, count: Feature.allCases.count)
    static var mode = 0                       // 0 real time, 1 time lapse, 2 noon, 3 golden hour, 4 night
    static var weather = 0                    // 0 auto, 1 drizzle, 2 steady rain, 3 downpour, 4 thunderstorm, 5 clear
    static let weatherTargets: [CGFloat] = [0, 0.25, 0.55, 0.85, 1.0, 0.0]
    static var lat = 20.0                     // replaced by your real location when you allow it
    static var lon = 78.0
    static let maxDrops = 650
    static let frogCount = 4
    static let boatCount = 3
    static let cloudCount = 7
    static let mistCount = 4
    static let starCount = 60
    static let lapseSpeed = 720.0             // time lapse: 1 day in 2 minutes
    static let pollInterval = 1.0 / 30.0
    static func on(_ f: Feature) -> Bool { enabled[f.rawValue] }
}

@inline(__always) func rnd(_ a: CGFloat, _ b: CGFloat) -> CGFloat { CGFloat.random(in: a...b) }
@inline(__always) func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }

typealias RGB = (CGFloat, CGFloat, CGFloat)
func mixRGB(_ a: RGB, _ b: RGB, _ t: CGFloat) -> RGB { (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t) }
func ns(_ c: RGB, _ alpha: CGFloat = 1) -> NSColor { NSColor(calibratedRed: c.0, green: c.1, blue: c.2, alpha: alpha) }

struct DropLayer {
    let len: ClosedRange<CGFloat>
    let width: CGFloat
    let alpha: ClosedRange<CGFloat>
    let speed: ClosedRange<CGFloat>
    let wind: CGFloat
}

// far = short and faint, near = long, bright and fast
let dropLayers: [DropLayer] = [
    DropLayer(len: 14...22, width: 1.1, alpha: 0.30...0.45, speed: 650...800, wind: 0.6),
    DropLayer(len: 26...38, width: 1.6, alpha: 0.45...0.65, speed: 900...1100, wind: 0.9),
    DropLayer(len: 42...60, width: 2.3, alpha: 0.60...0.80, speed: 1250...1500, wind: 1.2),
]

let boatColors: [RGB] = [(0.90, 0.25, 0.25), (0.25, 0.55, 0.90), (0.95, 0.75, 0.20)]

// MARK: - Sun position (used to know whether it is day, golden hour, dusk or night)

struct SkyState {
    var sunAlt = 0.0                          // radians
    var morning = true
}

func skyState(_ date: Date, lat: Double, lon: Double) -> SkyState {
    let rad = Double.pi / 180
    let jd = date.timeIntervalSince1970 / 86400 + 2440587.5
    let n = jd - 2451545.0
    func norm(_ x: Double, _ m: Double) -> Double { let r = x.truncatingRemainder(dividingBy: m); return r < 0 ? r + m : r }
    func wrap(_ a: Double) -> Double { atan2(sin(a), cos(a)) }

    let L = norm(280.460 + 0.9856474 * n, 360)
    let g = norm(357.528 + 0.9856003 * n, 360) * rad
    let lam = (L + 1.915 * sin(g) + 0.020 * sin(2 * g)) * rad
    let eps = (23.439 - 0.0000004 * n) * rad
    let dec = asin(sin(eps) * sin(lam))
    let ra = atan2(cos(eps) * sin(lam), cos(lam))
    let lst = (norm(280.46061837 + 360.98564736629 * n, 360) + lon) * rad
    let la = lat * rad
    let h = wrap(lst - ra)

    var s = SkyState()
    s.sunAlt = asin(sin(la) * sin(dec) + cos(la) * cos(dec) * cos(h))
    s.morning = h < 0
    return s
}

// MARK: - Textures (all drawn in code)

@MainActor func radialTexture(_ s: CGFloat, _ stops: [(CGFloat, CGFloat, CGFloat, CGFloat)], _ locs: [CGFloat]) -> SKTexture {
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        let cols = stops.map { NSColor(calibratedRed: $0.0, green: $0.1, blue: $0.2, alpha: $0.3) }
        if let g = NSGradient(colors: cols, atLocations: locs, colorSpace: .deviceRGB) {
            let c = NSPoint(x: s / 2, y: s / 2)
            g.draw(fromCenter: c, radius: 0, toCenter: c, radius: s / 2, options: [])
        }
        return true
    }
    return SKTexture(image: img)
}

@MainActor func makeDropTexture() -> SKTexture {          // a streak: bright head at the bottom, faded tail on top
    let img = NSImage(size: NSSize(width: 8, height: 64), flipped: false) { _ in
        let cols = [NSColor(calibratedRed: 0.55, green: 0.70, blue: 0.90, alpha: 0.9),
                    NSColor(calibratedRed: 0.70, green: 0.82, blue: 0.95, alpha: 0)]
        if let g = NSGradient(colors: cols) { g.draw(in: NSRect(x: 2, y: 0, width: 4, height: 64), angle: 90) }
        return true
    }
    return SKTexture(image: img)
}

@MainActor func makeSplashTexture() -> SKTexture {        // a little water crown
    let img = NSImage(size: NSSize(width: 64, height: 40), flipped: false) { _ in
        let c = CGPoint(x: 32, y: 4)
        let col = NSColor(calibratedRed: 0.72, green: 0.84, blue: 1.0, alpha: 0.95)
        let p = NSBezierPath()
        p.lineWidth = 2
        p.lineCapStyle = .round
        var tips: [CGPoint] = []
        for i in 0..<7 {
            let a = CGFloat.pi * (0.16 + 0.68 * CGFloat(i) / 6)
            let r: CGFloat = i % 2 == 0 ? 26 : 17
            p.move(to: CGPoint(x: c.x + cos(a) * 6, y: c.y + sin(a) * 4))
            let tip = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
            p.line(to: tip)
            tips.append(tip)
        }
        col.setStroke()
        p.stroke()
        col.setFill()
        for t in tips { NSBezierPath(ovalIn: CGRect(x: t.x - 2.4, y: t.y - 2.4, width: 4.8, height: 4.8)).fill() }
        return true
    }
    return SKTexture(image: img)
}

@MainActor func makeRippleTexture() -> SKTexture {        // a flat ring on the water
    let img = NSImage(size: NSSize(width: 64, height: 24), flipped: false) { _ in
        let ring = NSBezierPath(ovalIn: CGRect(x: 4, y: 4, width: 56, height: 16))
        ring.lineWidth = 2
        NSColor(calibratedRed: 0.85, green: 0.93, blue: 1.0, alpha: 0.95).setStroke()
        ring.stroke()
        return true
    }
    return SKTexture(image: img)
}

@MainActor func makeWaterTexture() -> SKTexture {         // puddle band: lighter on top
    let img = NSImage(size: NSSize(width: 4, height: 64), flipped: false) { _ in
        let cols = [NSColor(calibratedRed: 0.30, green: 0.48, blue: 0.70, alpha: 0.40),
                    NSColor(calibratedRed: 0.72, green: 0.86, blue: 1.00, alpha: 0.55)]
        if let g = NSGradient(colors: cols) { g.draw(in: NSRect(x: 0, y: 0, width: 4, height: 64), angle: 90) }
        return true
    }
    return SKTexture(image: img)
}

@MainActor func makeBandTexture() -> SKTexture {          // dark at the top, clear at the bottom
    let img = NSImage(size: NSSize(width: 4, height: 64), flipped: false) { _ in
        let cols = [NSColor(calibratedWhite: 1, alpha: 0), NSColor(calibratedWhite: 1, alpha: 1)]
        if let g = NSGradient(colors: cols) { g.draw(in: NSRect(x: 0, y: 0, width: 4, height: 64), angle: 90) }
        return true
    }
    return SKTexture(image: img)
}

@MainActor func makeCloudTexture() -> SKTexture {
    let w: CGFloat = 256, h: CGFloat = 128
    let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
        let blobs: [(CGFloat, CGFloat, CGFloat)] = [(60, 48, 38), (100, 62, 50), (150, 60, 46), (195, 48, 36), (125, 42, 40), (85, 40, 32), (170, 40, 32)]
        let cols = [NSColor(calibratedWhite: 1, alpha: 0.95), NSColor(calibratedWhite: 1, alpha: 0.6), NSColor(calibratedWhite: 1, alpha: 0)]
        if let g = NSGradient(colors: cols, atLocations: [0, 0.55, 1], colorSpace: .deviceRGB) {
            for (x, y, r) in blobs {
                g.draw(fromCenter: NSPoint(x: x, y: y), radius: 0, toCenter: NSPoint(x: x, y: y), radius: r, options: [])
            }
        }
        return true
    }
    return SKTexture(image: img)
}

@MainActor func makeRainbowTexture() -> SKTexture {
    let img = NSImage(size: NSSize(width: 600, height: 300), flipped: false) { _ in
        let colors: [RGB] = [(0.95, 0.25, 0.25), (1.0, 0.6, 0.2), (1.0, 0.9, 0.3), (0.4, 0.8, 0.4),
                             (0.3, 0.6, 0.95), (0.35, 0.35, 0.8), (0.6, 0.35, 0.8)]
        for (i, c) in colors.enumerated() {
            let p = NSBezierPath()
            p.appendArc(withCenter: NSPoint(x: 300, y: 0), radius: 285 - CGFloat(i) * 13, startAngle: 0, endAngle: 180)
            p.lineWidth = 13
            ns(c, 0.55).setStroke()
            p.stroke()
        }
        return true
    }
    return SKTexture(image: img)
}

@MainActor func makeBoatTexture(_ rgb: RGB) -> SKTexture {
    let img = NSImage(size: NSSize(width: 48, height: 40), flipped: false) { _ in
        let paper = NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.90, alpha: 1)
        let dark = NSColor(calibratedWhite: 0.25, alpha: 1)
        let hull = NSBezierPath()
        hull.move(to: CGPoint(x: 3, y: 12))
        hull.line(to: CGPoint(x: 45, y: 12))
        hull.line(to: CGPoint(x: 37, y: 3))
        hull.line(to: CGPoint(x: 11, y: 3))
        hull.close()
        paper.setFill()
        hull.fill()
        dark.setStroke()
        hull.lineWidth = 1.2
        hull.stroke()
        let sail = NSBezierPath()
        sail.move(to: CGPoint(x: 24, y: 12))
        sail.line(to: CGPoint(x: 24, y: 37))
        sail.line(to: CGPoint(x: 41, y: 12))
        sail.close()
        ns(rgb).setFill()
        sail.fill()
        sail.lineWidth = 1.2
        sail.stroke()
        let sail2 = NSBezierPath()
        sail2.move(to: CGPoint(x: 24, y: 12))
        sail2.line(to: CGPoint(x: 24, y: 30))
        sail2.line(to: CGPoint(x: 9, y: 12))
        sail2.close()
        ns(mixRGB(rgb, (1, 1, 1), 0.45)).setFill()
        sail2.fill()
        sail2.lineWidth = 1.2
        sail2.stroke()
        return true
    }
    return SKTexture(image: img)
}

@MainActor func makeFrogTexture() -> SKTexture {
    let s: CGFloat = 64
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        let green = NSColor(calibratedRed: 0.33, green: 0.70, blue: 0.27, alpha: 1)
        let dark = NSColor(calibratedRed: 0.17, green: 0.42, blue: 0.16, alpha: 1)
        let belly = NSColor(calibratedRed: 0.78, green: 0.92, blue: 0.55, alpha: 1)
        func oval(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ fill: NSColor, _ outline: Bool) {
            let p = NSBezierPath(ovalIn: CGRect(x: x - rx, y: y - ry, width: 2 * rx, height: 2 * ry))
            fill.setFill()
            p.fill()
            if outline {
                dark.setStroke()
                p.lineWidth = 1.4
                p.stroke()
            }
        }
        oval(13, 10, 10, 5, green, true)          // feet
        oval(51, 10, 10, 5, green, true)
        oval(32, 24, 22, 16, green, true)         // body
        oval(32, 19, 13, 9, belly, false)
        oval(21, 40, 8, 8, green, true)           // eye bumps
        oval(43, 40, 8, 8, green, true)
        oval(21, 41, 5.2, 5.2, NSColor.white, false)
        oval(43, 41, 5.2, 5.2, NSColor.white, false)
        oval(22, 41, 2.6, 2.6, NSColor.black, false)
        oval(42, 41, 2.6, 2.6, NSColor.black, false)
        let mouth = NSBezierPath()
        mouth.lineWidth = 1.6
        mouth.lineCapStyle = .round
        mouth.move(to: CGPoint(x: 20, y: 27))
        mouth.curve(to: CGPoint(x: 44, y: 27), controlPoint1: CGPoint(x: 26, y: 20), controlPoint2: CGPoint(x: 38, y: 20))
        dark.setStroke()
        mouth.stroke()
        return true
    }
    return SKTexture(image: img)
}

@MainActor func makeUmbrellaTexture() -> SKTexture {     // canopy base sits at y = 70
    let s: CGFloat = 128
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        let teal = NSColor(calibratedRed: 0.13, green: 0.58, blue: 0.68, alpha: 1)
        let dark = NSColor(calibratedRed: 0.06, green: 0.30, blue: 0.38, alpha: 1)
        let handle = NSBezierPath()                         // handle with a hook
        handle.lineWidth = 3.4
        handle.lineCapStyle = .round
        handle.move(to: CGPoint(x: 64, y: 70))
        handle.line(to: CGPoint(x: 64, y: 28))
        handle.curve(to: CGPoint(x: 50, y: 30), controlPoint1: CGPoint(x: 64, y: 10), controlPoint2: CGPoint(x: 50, y: 10))
        NSColor(calibratedRed: 0.35, green: 0.22, blue: 0.12, alpha: 1).setStroke()
        handle.stroke()

        let canopy = NSBezierPath()
        canopy.move(to: CGPoint(x: 8, y: 70))
        canopy.curve(to: CGPoint(x: 120, y: 70), controlPoint1: CGPoint(x: 8, y: 130), controlPoint2: CGPoint(x: 120, y: 130))
        for k in 0..<4 {                                    // scalloped edge
            let x0 = 120 - 28 * CGFloat(k), x1 = x0 - 28
            canopy.curve(to: CGPoint(x: x1, y: 70), controlPoint1: CGPoint(x: x0 - 4, y: 61), controlPoint2: CGPoint(x: x1 + 4, y: 61))
        }
        canopy.close()
        teal.setFill()
        canopy.fill()
        let ribs = NSBezierPath()
        ribs.lineWidth = 1.4
        for k in 0...4 {
            ribs.move(to: CGPoint(x: 64, y: 115))
            ribs.line(to: CGPoint(x: 8 + 28 * CGFloat(k), y: 70))
        }
        NSColor(calibratedWhite: 1, alpha: 0.45).setStroke()
        ribs.stroke()
        dark.setStroke()
        canopy.lineWidth = 1.6
        canopy.stroke()
        return true
    }
    return SKTexture(image: img)
}

// MARK: - Things that move

@MainActor final class Drop {
    let node: SKSpriteNode
    var vx: CGFloat = 0, vy: CGFloat = -900
    var layer = 1
    var inFront = false                   // far drops ignore windows and fall to the bottom of the screen
    init(texture: SKTexture) { node = SKSpriteNode(texture: texture) }
}

@MainActor final class Frog {
    let node: SKSpriteNode
    var active = false, act: CGFloat = 0
    var perchID = -1, perchOff: CGFloat = 0, groundX: CGFloat = 0
    var hopping = false
    var hopT: CGFloat = 0, hopDur: CGFloat = 0.6, hopH: CGFloat = 50
    var from = CGPoint.zero
    var toID = -1, toOff: CGFloat = 0, toGroundX: CGFloat = 0
    var nextHop: CGFloat = 0, nextCroak: CGFloat = 0, phase: CGFloat = 0
    init(texture: SKTexture) { node = SKSpriteNode(texture: texture) }
}

// MARK: - Scene

final class RainScene: SKScene {
    // layers, back to front
    let tintNode = SKSpriteNode(color: .clear, size: .zero)
    let flashNode = SKSpriteNode(color: NSColor(calibratedRed: 0.85, green: 0.9, blue: 1, alpha: 1), size: .zero)
    let bandNode = SKSpriteNode(color: .clear, size: .zero)
    let starLayer = SKNode(), cloudLayer = SKNode(), rainbowLayer = SKNode(), mistLayer = SKNode()
    let dropLayer = SKNode(), waterLayer = SKNode(), boatLayer = SKNode(), splashLayer = SKNode()
    let frogLayer = SKNode(), umbrellaLayer = SKNode(), boltLayer = SKNode()

    var waterNode: SKSpriteNode!
    var rainbow: SKSpriteNode!
    var umbrella: SKSpriteNode!
    var splashTex: SKTexture!, rippleTex: SKTexture!, dropTex: SKTexture!, frogTex: SKTexture!

    var drops: [Drop] = [], pool: [Drop] = []
    var frogs: [Frog] = []
    var clouds: [(node: SKSpriteNode, speed: CGFloat)] = []
    var mists: [(node: SKSpriteNode, speed: CGFloat)] = []
    var boats: [(node: SKSpriteNode, speed: CGFloat, phase: CGFloat)] = []
    var stars: [(node: SKSpriteNode, base: CGFloat, speed: CGFloat, phase: CGFloat)] = []

    var order: [(id: Int, rect: CGRect)] = []        // windows, front to back
    var lastRect: [Int: CGRect] = [:]
    let myPID = getpid()
    var built = false
    var lastT: TimeInterval = 0
    var t: CGFloat = 0
    var pollAcc: CGFloat = 0
    var statusAcc: CGFloat = 99
    var groundAcc: CGFloat = 99
    var groundY: CGFloat = 0
    var water: CGFloat = 0                           // how full the puddles are, 0...1
    var waterH: CGFloat { water * 26 }

    var mouse = NSEvent.mouseLocation
    var mouseSpeed: CGFloat = 0
    var mouseVX: CGFloat = 0, mouseVY: CGFloat = 0

    var sky = SkyState()
    var lapseOffset = 0.0
    var presetDate = Date()
    var dayW: CGFloat = 1, goldenW: CGFloat = 0, duskW: CGFloat = 0, nightW: CGFloat = 0

    var intensity: CGFloat = 0.35                    // current rain strength 0...1
    var targetI: CGFloat = 0.55
    var nextWeather: CGFloat = 60
    var windX: CGFloat = 80
    var nextBolt: CGFloat = 8
    var wasRaining = false
    var rainbowUntil: CGFloat = -1
    var onStatus: ((String, String) -> Void)?

    override func didMove(to view: SKView) {
        backgroundColor = .clear
        dropTex = makeDropTexture()
        splashTex = makeSplashTexture()
        rippleTex = makeRippleTexture()
        frogTex = makeFrogTexture()

        tintNode.zPosition = -2
        tintNode.alpha = 0
        addChild(tintNode)
        bandNode.zPosition = -1
        bandNode.alpha = 0
        addChild(bandNode)
        for (i, l) in [starLayer, cloudLayer, rainbowLayer, mistLayer, dropLayer, waterLayer, boatLayer, splashLayer,
                       frogLayer, umbrellaLayer, boltLayer].enumerated() {
            l.zPosition = CGFloat(i)
            addChild(l)
        }
        flashNode.zPosition = 20
        flashNode.alpha = 0
        addChild(flashNode)

        let band = SKSpriteNode(texture: makeBandTexture())
        bandNode.addChild(band)
        bandNode.texture = nil
        bandTexture = band

        buildStars()
        buildClouds()
        buildMist()
        buildWater()
        buildBoats()
        buildRainbow()
        buildUmbrella()
        for _ in 0..<Cfg.frogCount { spawnFrog() }
        groundY = groundTop()
        built = true
        didChangeSize(size)
        for _ in 0..<Int(CGFloat(Cfg.maxDrops) * 0.4) { spawnDrop(y: rnd(0, size.height)) }
    }

    var bandTexture: SKSpriteNode!

    override func didChangeSize(_ oldSize: CGSize) {
        guard built else { return }
        tintNode.size = size
        tintNode.position = CGPoint(x: size.width / 2, y: size.height / 2)
        flashNode.size = size
        flashNode.position = CGPoint(x: size.width / 2, y: size.height / 2)
        bandNode.position = CGPoint(x: size.width / 2, y: size.height)
        bandTexture.size = CGSize(width: size.width, height: size.height * 0.4)
        bandTexture.anchorPoint = CGPoint(x: 0.5, y: 1)
        waterNode.size = CGSize(width: size.width, height: 1)
    }

    /// The ground is the top of the Dock when it sits at the bottom of the screen (else the screen bottom)
    func groundTop() -> CGFloat {
        guard let s = NSScreen.screens.first else { return 0 }
        return max(0, s.visibleFrame.minY - s.frame.minY)
    }

    // MARK: Time

    func currentDate() -> Date {
        switch Cfg.mode {
        case 0: return Date()
        case 1: return Date().addingTimeInterval(lapseOffset)
        default: return presetDate
        }
    }

    func applyMode() {
        if Cfg.mode == 1 { lapseOffset = 0 }
        if Cfg.mode >= 2 { presetDate = findTime(Cfg.mode) }
        statusAcc = 99
    }

    func findTime(_ mode: Int) -> Date {
        let start = Calendar.current.startOfDay(for: Date())
        var best = start, bestScore = Double.infinity
        for i in 0..<288 {
            let d = start.addingTimeInterval(Double(i) * 300)
            let s = skyState(d, lat: Cfg.lat, lon: Cfg.lon)
            let score: Double
            switch mode {
            case 2: score = -s.sunAlt
            case 3: score = s.morning ? 1e9 : abs(s.sunAlt - 0.05)
            default: score = s.sunAlt
            }
            if score < bestScore { bestScore = score; best = d }
        }
        return best
    }

    // MARK: Building the scene

    func buildStars() {
        let tex = radialTexture(32, [(1, 1, 1, 1), (1, 1, 1, 0.45), (1, 1, 1, 0)], [0, 0.35, 1])
        for _ in 0..<Cfg.starCount {
            let n = SKSpriteNode(texture: tex)
            let s = rnd(4, 10)
            n.size = CGSize(width: s, height: s)
            n.position = CGPoint(x: rnd(0, size.width), y: rnd(size.height * 0.3, size.height))
            starLayer.addChild(n)
            stars.append((n, rnd(0.5, 1), rnd(0.8, 2.5), rnd(0, 6.28)))
        }
    }

    func buildClouds() {
        let tex = makeCloudTexture()
        for _ in 0..<Cfg.cloudCount {
            let n = SKSpriteNode(texture: tex)
            let w = rnd(380, 620)
            n.size = CGSize(width: w, height: w / 2)
            n.position = CGPoint(x: rnd(0, size.width), y: rnd(size.height * 0.8, size.height * 1.02))
            cloudLayer.addChild(n)
            clouds.append((n, rnd(12, 30)))
        }
    }

    func buildMist() {
        let tex = radialTexture(256, [(1, 1, 1, 0.55), (1, 1, 1, 0.25), (1, 1, 1, 0)], [0, 0.5, 1])
        for _ in 0..<Cfg.mistCount {
            let n = SKSpriteNode(texture: tex)
            n.size = CGSize(width: rnd(600, 900), height: rnd(180, 260))
            n.position = CGPoint(x: rnd(0, size.width), y: rnd(0, 120))
            n.alpha = 0
            mistLayer.addChild(n)
            mists.append((n, rnd(8, 20)))
        }
    }

    func buildWater() {
        waterNode = SKSpriteNode(texture: makeWaterTexture())
        waterNode.anchorPoint = CGPoint(x: 0, y: 0)
        waterNode.position = .zero
        waterLayer.addChild(waterNode)
    }

    func buildBoats() {
        for i in 0..<Cfg.boatCount {
            let n = SKSpriteNode(texture: makeBoatTexture(boatColors[i % boatColors.count]))
            n.size = CGSize(width: 40, height: 33)
            n.anchorPoint = CGPoint(x: 0.5, y: 0.1)
            n.position = CGPoint(x: rnd(100, size.width - 100), y: 0)
            n.alpha = 0
            boatLayer.addChild(n)
            boats.append((n, rnd(14, 30), rnd(0, 6.28)))
        }
    }

    func buildRainbow() {
        rainbow = SKSpriteNode(texture: makeRainbowTexture())
        rainbow.anchorPoint = CGPoint(x: 0.5, y: 0)
        rainbow.size = CGSize(width: 960, height: 480)
        rainbow.position = CGPoint(x: size.width * 0.5, y: size.height * 0.12)
        rainbowLayer.addChild(rainbow)
        rainbowLayer.alpha = 0
    }

    func buildUmbrella() {
        umbrella = SKSpriteNode(texture: makeUmbrellaTexture())
        umbrella.size = CGSize(width: 128, height: 128)
        umbrella.anchorPoint = CGPoint(x: 0.5, y: 70.0 / 128.0)    // the canopy base is the pivot
        umbrellaLayer.addChild(umbrella)
    }

    func spawnFrog() {
        let f = Frog(texture: frogTex)
        let s = rnd(34, 44)
        f.node.size = CGSize(width: s, height: s)
        f.node.anchorPoint = CGPoint(x: 0.5, y: 0)
        f.node.alpha = 0
        f.phase = rnd(0, 6.28)
        f.groundX = rnd(60, size.width - 60)
        f.node.position = CGPoint(x: f.groundX, y: groundY)
        f.nextHop = rnd(3, 9)
        f.nextCroak = rnd(6, 16)
        frogLayer.addChild(f.node)
        frogs.append(f)
    }

    // MARK: Drops

    func obtainDrop() -> Drop {
        let d = pool.popLast() ?? Drop(texture: dropTex)
        dropLayer.addChild(d.node)
        drops.append(d)
        return d
    }

    func retire(_ d: Drop) {
        d.node.removeFromParent()
        pool.append(d)
    }

    func spawnDrop(y: CGFloat? = nil) {
        let d = obtainDrop()
        let r = CGFloat.random(in: 0...1)
        let li = r < 0.35 ? 0 : (r < 0.7 ? 1 : 2)
        let L = dropLayers[li]
        d.layer = li
        d.inFront = li == 0 || CGFloat.random(in: 0...1) < 0.45
        d.node.size = CGSize(width: L.width, height: CGFloat.random(in: L.len))
        d.node.alpha = CGFloat.random(in: L.alpha)
        d.vy = -CGFloat.random(in: L.speed) * (0.85 + 0.3 * intensity)
        d.vx = windX * L.wind
        d.node.zRotation = atan2(d.vx, -d.vy)
        d.node.position = CGPoint(x: rnd(-300, size.width + 50), y: y ?? (size.height + rnd(10, 250)))
    }

    // MARK: Frame update

    override func update(_ currentTime: TimeInterval) {
        if lastT == 0 { lastT = currentTime }
        let dt = CGFloat(min(currentTime - lastT, 1.0 / 20.0))
        lastT = currentTime
        t += dt
        if Cfg.mode == 1 { lapseOffset += Double(dt) * Cfg.lapseSpeed }

        let m = NSEvent.mouseLocation
        if dt > 0 {
            mouseVX = (m.x - mouse.x) / dt
            mouseVY = (m.y - mouse.y) / dt
            mouseSpeed = hypot(mouseVX, mouseVY)
        }
        mouse = m

        pollAcc += dt
        if Double(pollAcc) >= Cfg.pollInterval { pollWindows(); pollAcc = 0 }
        groundAcc += dt
        if groundAcc > 1 { groundAcc = 0; groundY = groundTop() }

        sky = skyState(currentDate(), lat: Cfg.lat, lon: Cfg.lon)
        let a = CGFloat(sky.sunAlt) * 180 / .pi
        dayW = clamp((a - 8) / 14, 0, 1)
        goldenW = clamp(1 - abs(a - 5) / 9, 0, 1)
        duskW = clamp(1 - abs(a + 5) / 8, 0, 1)
        nightW = clamp((-a - 4) / 10, 0, 1)

        updateWeather(dt)
        let baseWind: CGFloat = (50 + 150 * intensity) * (0.75 + 0.25 * sin(t * 0.3))
        let gustWind: CGFloat = 120 * pow(max(0, sin(t * 0.09)), 10) * intensity
        windX = baseWind + gustWind

        updateEnvironment(dt, sunDeg: a)
        stepDrops(dt)
        stepWater(dt)
        for f in frogs { stepFrog(f, dt) }
        umbrella.isHidden = !Cfg.on(.umbrella)
        if !umbrella.isHidden {
            umbrella.position = CGPoint(x: mouse.x, y: mouse.y + 45)
            umbrella.zRotation += (clamp(-windX / 700, -0.25, 0.25) - umbrella.zRotation) * min(1, dt * 3)
        }
    }

    func fade(_ node: SKNode, _ target: CGFloat, _ dt: CGFloat) {
        node.alpha += (target - node.alpha) * min(1, dt * 1.5)
        node.isHidden = node.alpha < 0.01
    }

    // MARK: Weather director

    func pickWeather() -> CGFloat {
        let targets: [CGFloat] = [0.0, 0.25, 0.55, 0.85, 1.0]
        let w: [Double] = nightW > 0.5 ? [0.10, 0.15, 0.30, 0.25, 0.20]            // storms like the night
            : (dayW > 0.5 ? [0.22, 0.28, 0.28, 0.15, 0.07] : [0.15, 0.25, 0.30, 0.20, 0.10])
        var r = Double.random(in: 0..<1)
        for (i, x) in w.enumerated() {
            r -= x
            if r < 0 { return targets[i] }
        }
        return 0.55
    }

    func updateWeather(_ dt: CGFloat) {
        if Cfg.weather == 0 {
            if t > nextWeather { targetI = pickWeather(); nextWeather = t + rnd(50, 140) }
        } else {
            targetI = Cfg.weatherTargets[Cfg.weather]
        }
        intensity += (targetI - intensity) * min(1, dt * 0.25)
        if intensity > 0.45 { wasRaining = true }
    }

    func weatherName(_ i: CGFloat) -> String {
        switch i {
        case ..<0.06: return "Clear sky"
        case ..<0.35: return "Drizzle"
        case ..<0.65: return "Steady rain"
        case ..<0.9: return "Heavy rain"
        default: return "Thunderstorm"
        }
    }

    // MARK: Clouds, mist, tint, lightning, rainbow

    func updateEnvironment(_ dt: CGFloat, sunDeg a: CGFloat) {
        let W = size.width, H = size.height
        let I = intensity

        // Storm clouds: light grey in drizzle, almost black in a thunderstorm, very dark at night
        let cloudRGB = mixRGB(mixRGB((0.78, 0.82, 0.88), (0.30, 0.34, 0.42), I), (0.10, 0.12, 0.20), nightW * 0.8)
        let cloudTarget = Cfg.on(.clouds) ? clamp(0.25 + 0.75 * I, 0, 1) : 0
        fade(cloudLayer, cloudTarget, dt)
        if !cloudLayer.isHidden {
            for c in clouds {
                c.node.color = ns(cloudRGB)
                c.node.colorBlendFactor = 1
                c.node.alpha = 0.55
                c.node.position.x += (c.speed + windX * 0.15) * dt
                if c.node.position.x > W + 320 { c.node.position = CGPoint(x: -320, y: rnd(H * 0.8, H * 1.02)) }
            }
        }
        bandNode.color = ns(mixRGB((0.14, 0.17, 0.24), (0.03, 0.04, 0.08), nightW))
        bandTexture.color = bandNode.color
        bandTexture.colorBlendFactor = 1
        let bandTarget = Cfg.on(.clouds) ? 0.05 + 0.28 * I : 0
        bandNode.alpha += (bandTarget - bandNode.alpha) * min(1, dt * 1.5)

        // Mist drifting near the ground
        let mistTarget = Cfg.on(.mist) ? clamp(0.08 + 0.30 * I + 0.15 * (duskW + goldenW * 0.5), 0, 0.5) : 0
        fade(mistLayer, 1, dt)
        for mst in mists {
            mst.node.color = ns(mixRGB((0.75, 0.80, 0.86), (0.35, 0.40, 0.55), nightW))
            mst.node.colorBlendFactor = 1
            mst.node.alpha += (mistTarget - mst.node.alpha) * min(1, dt * 1.5)
            mst.node.position.x += (mst.speed + windX * 0.05) * dt
            mst.node.position.y = groundY + 40 + 60 * sin(t * 0.1 + mst.node.size.width)
            if mst.node.position.x > W + 450 { mst.node.position.x = -450 }
        }

        // Stars on clear nights
        let starTarget = clamp((-a - 3) / 9, 0, 1) * clamp(1 - I * 3, 0, 1)
        fade(starLayer, starTarget, dt)
        if !starLayer.isHidden {
            for st in stars { st.node.alpha = st.base * (0.65 + 0.35 * sin(t * st.speed + st.phase)) }
        }

        // Sky tint by time of day: grey-blue day, warm golden hour, purple dusk, deep blue night
        let wsum = max(dayW + goldenW + duskW + nightW, 0.001)
        func blend(_ d: CGFloat, _ gd: CGFloat, _ du: CGFloat, _ ni: CGFloat) -> CGFloat {
            let sum: CGFloat = d * dayW + gd * goldenW + du * duskW + ni * nightW
            return sum / wsum
        }
        tintNode.color = NSColor(calibratedRed: blend(0.30, 0.50, 0.30, 0.02),
                                 green: blend(0.38, 0.36, 0.20, 0.04),
                                 blue: blend(0.50, 0.30, 0.40, 0.14), alpha: 1)
        let tintTarget = Cfg.on(.tint) ? min(0.26, 0.03 + 0.12 * I + 0.10 * nightW + 0.03 * duskW) : 0
        tintNode.alpha += (tintTarget - tintNode.alpha) * min(1, dt * 1.5)

        // Lightning
        if Cfg.on(.lightning) && I > 0.7 && t > nextBolt {
            let strong = I > 0.9
            lightning(bright: strong ? 1 : 0.45)
            nextBolt = t + (strong ? rnd(6, 16) : rnd(18, 45))
        }

        // Rainbow: after the rain has stopped, in daylight
        if Cfg.on(.rainbow) && wasRaining && I < 0.15 && a > 6 {
            wasRaining = false
            showRainbow(for: 70)
        }
        let rbTarget: CGFloat = (Cfg.on(.rainbow) && t < rainbowUntil && a > 2) ? 0.95 : 0
        rainbowLayer.alpha += (rbTarget - rainbowLayer.alpha) * min(1, dt * 0.8)
        rainbowLayer.isHidden = rainbowLayer.alpha < 0.01

        // Menu bar icon and info line
        statusAcc += dt
        if statusAcc > 1 {
            statusAcc = 0
            let icon: String
            if I >= 0.9 { icon = "⛈️" } else if I >= 0.55 { icon = "🌧️" } else if I >= 0.1 { icon = "🌦️" }
            else if nightW > 0.5 { icon = "🌙" } else { icon = "⛅️" }
            onStatus?(icon, String(format: "%@ · rain %.0f%% · Sun %+.0f°", weatherName(I), I * 100, a))
        }
    }

    func showRainbow(for seconds: CGFloat) {
        rainbowUntil = t + seconds
        rainbow.position = CGPoint(x: size.width * rnd(0.35, 0.65), y: size.height * rnd(0.08, 0.2))
        let w = min(size.width * 0.75, 1100)
        rainbow.size = CGSize(width: w, height: w / 2)
    }

    func lightning(bright: CGFloat) {
        flashNode.removeAllActions()
        flashNode.run(.sequence([.fadeAlpha(to: 0.5 * bright, duration: 0.04), .fadeAlpha(to: 0.08, duration: 0.06),
                                 .fadeAlpha(to: 0.4 * bright, duration: 0.04), .fadeOut(withDuration: 0.35)]))
        guard bright > 0.5 else { return }
        let W = size.width, H = size.height
        var x = rnd(W * 0.1, W * 0.9), y = H + 10
        let endY = rnd(H * 0.25, H * 0.6)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: y))
        var pts: [CGPoint] = []
        while y > endY {
            x += rnd(-40, 40)
            y -= rnd(25, 60)
            let p = CGPoint(x: x, y: y)
            path.addLine(to: p)
            pts.append(p)
        }
        if pts.count > 4, let start = pts[2...(pts.count - 2)].randomElement() {      // a side branch
            var bx = start.x, by = start.y
            path.move(to: start)
            for _ in 0..<4 {
                bx += rnd(10, 45) * (Bool.random() ? 1 : -1)
                by -= rnd(20, 45)
                path.addLine(to: CGPoint(x: bx, y: by))
            }
        }
        let bolt = SKShapeNode(path: path)
        bolt.strokeColor = NSColor(calibratedRed: 0.92, green: 0.95, blue: 1, alpha: 1)
        bolt.lineWidth = 3
        bolt.glowWidth = 6
        bolt.alpha = 0
        boltLayer.addChild(bolt)
        bolt.run(.sequence([.fadeAlpha(to: 1, duration: 0.03), .fadeAlpha(to: 0.3, duration: 0.07), .fadeAlpha(to: 1, duration: 0.04),
                            .fadeOut(withDuration: 0.3), .removeFromParent()]))
    }

    func forceLightning() { lightning(bright: 1) }
    func forceRainbow() { showRainbow(for: 60) }

    // MARK: Rain

    func stepDrops(_ dt: CGFloat) {
        let target = intensity < 0.03 ? 0 : Int(CGFloat(Cfg.maxDrops) * pow(intensity, 0.8))
        var spawned = 0
        while drops.count < target && spawned < 25 { spawnDrop(); spawned += 1 }

        let umbrellaOn = Cfg.on(.umbrella)
        let gustOn = Cfg.on(.mouse) && mouseSpeed > 200
        let ux = mouse.x, ubase = mouse.y + 45
        let gT = groundY + 3

        var i = drops.count
        while i > 0 {
            i -= 1
            let d = drops[i], n = d.node
            let L = dropLayers[d.layer]
            d.vx += (windX * L.wind - d.vx) * min(1, dt * 2)
            let prev = n.position
            n.position.x += d.vx * dt
            n.position.y += d.vy * dt
            if gustOn {                                    // swiping the mouse blows nearby rain sideways
                let dx = n.position.x - mouse.x, dy = n.position.y - mouse.y
                if dx * dx + dy * dy < 8100 { d.vx += clamp(mouseVX, -1500, 1500) * 0.015 }
            }
            n.zRotation = atan2(d.vx, -d.vy)

            var gone = false
            if umbrellaOn {                                // the umbrella catches the rain
                let dx = n.position.x - ux
                if abs(dx) < 56 {
                    let domeY = ubase + 48 * sqrt(max(0, 1 - (dx / 56) * (dx / 56)))
                    if prev.y >= domeY && n.position.y < domeY {
                        if CGFloat.random(in: 0...1) < 0.5 { splash(at: CGPoint(x: n.position.x, y: domeY), big: false) }
                        gone = true
                    }
                }
            }
            if !gone && !d.inFront, let p = windowLanding(x: n.position.x, prevY: prev.y, y: n.position.y) {
                if CGFloat.random(in: 0...1) < 0.6 { splash(at: p, big: d.layer == 2) }
                gone = true
            }
            if !gone && n.position.y < gT {
                groundImpact(x: n.position.x)
                gone = true
            }
            if gone || n.position.x > size.width + 400 || n.position.x < -500 {
                drops.swapAt(i, drops.count - 1)
                drops.removeLast()
                retire(d)
            }
        }
    }

    func windowLanding(x: CGFloat, prevY: CGFloat, y: CGFloat) -> CGPoint? {
        for (idx, item) in order.enumerated() {
            let r = item.rect
            guard x >= r.minX, x <= r.maxX, prevY >= r.maxY, y < r.maxY else { continue }
            let pt = CGPoint(x: x, y: r.maxY + 1)
            var hidden = false
            for j in 0..<idx where order[j].rect.contains(pt) { hidden = true; break }
            if !hidden { return CGPoint(x: x, y: r.maxY) }
        }
        return nil
    }

    func groundImpact(x: CGFloat) {
        let r = CGFloat.random(in: 0...1)
        if Cfg.on(.puddles) && waterH > 3 {
            if r < 0.35 { ripple(at: CGPoint(x: x, y: groundY + rnd(0, waterH * 0.8))) }
        } else if r < 0.3 {
            splash(at: CGPoint(x: x, y: groundY + 2), big: false)
        }
    }

    func splash(at p: CGPoint, big: Bool) {
        guard splashLayer.children.count < 140 else { return }
        let n = SKSpriteNode(texture: splashTex)
        n.size = CGSize(width: big ? 26 : 18, height: big ? 16 : 11)
        n.anchorPoint = CGPoint(x: 0.5, y: 0)
        n.position = p
        n.alpha = 0.85
        splashLayer.addChild(n)
        n.run(.sequence([.group([.scale(to: 1.7, duration: 0.22), .fadeOut(withDuration: 0.22)]), .removeFromParent()]))
    }

    func ripple(at p: CGPoint) {
        guard splashLayer.children.count < 140 else { return }
        let n = SKSpriteNode(texture: rippleTex)
        n.size = CGSize(width: 14, height: 5)
        n.position = p
        n.alpha = 0.8
        splashLayer.addChild(n)
        n.run(.sequence([.group([.scale(to: 3.2, duration: 0.6), .fadeOut(withDuration: 0.6)]), .removeFromParent()]))
    }

    // MARK: Puddles and paper boats

    func stepWater(_ dt: CGFloat) {
        if intensity > 0.15 { water = min(1, water + dt * 0.012 * intensity) } else { water = max(0, water - dt * 0.004) }
        let h = Cfg.on(.puddles) ? waterH : 0
        waterNode.size = CGSize(width: size.width, height: max(h, 0.001))
        waterNode.position = CGPoint(x: 0, y: groundY)
        waterNode.isHidden = h < 0.5
        let boatAlpha = clamp((h - 5) / 8, 0, 1)
        for b in boats {
            b.node.alpha = boatAlpha
            if boatAlpha > 0 {
                b.node.position.x += (b.speed + windX * 0.1) * dt
                if b.node.position.x > size.width + 40 { b.node.position.x = -40 }
                b.node.position.y = groundY + h * 0.45 + 2 * sin(t * 1.6 + b.phase)
                b.node.zRotation = 0.1 * sin(t * 1.2 + b.phase)
            }
        }
    }

    // MARK: Frogs

    func frogSpot(id: Int, off: CGFloat, gx: CGFloat) -> CGPoint? {
        if id >= 0 {
            guard let r = lastRect[id] else { return nil }
            return CGPoint(x: r.minX + off, y: r.maxY)
        }
        return CGPoint(x: gx, y: groundY + (Cfg.on(.puddles) ? waterH * 0.25 : 0))
    }

    func startHop(_ f: Frog, scared: Bool) {
        f.from = f.node.position
        f.hopping = true
        f.hopT = 0
        if CGFloat.random(in: 0...1) < 0.7, let item = order.filter({ $0.rect.maxY < size.height - 60 }).randomElement() {
            f.toID = item.id
            f.toOff = rnd(15, max(16, item.rect.width - 15))
        } else {
            f.toID = -1
            f.toGroundX = rnd(40, size.width - 40)
        }
        let to = frogSpot(id: f.toID, off: f.toOff, gx: f.toGroundX) ?? f.from
        let d = hypot(to.x - f.from.x, to.y - f.from.y)
        f.hopDur = clamp(0.35 + d / 900, 0.4, 1.1) * (scared ? 0.8 : 1)
        f.hopH = clamp(30 + d * 0.15, 30, 160)
        f.nextHop = t + rnd(5, 14) / (0.6 + intensity)       // frogs hop more in the rain
    }

    func stepFrog(_ f: Frog, _ dt: CGFloat) {
        let n = f.node
        f.act += ((f.active ? 1 : 0) - f.act) * min(1, dt * 1.2)
        n.alpha = f.act
        if f.act < 0.02 { n.isHidden = true; return }
        n.isHidden = false

        if f.hopping {
            guard let to = frogSpot(id: f.toID, off: f.toOff, gx: f.toGroundX) else {
                f.hopping = false
                f.perchID = -1
                f.groundX = n.position.x
                return
            }
            f.hopT += dt
            let s = clamp(f.hopT / f.hopDur, 0, 1)
            n.position = CGPoint(x: f.from.x + (to.x - f.from.x) * s,
                                 y: f.from.y + (to.y - f.from.y) * s + 4 * s * (1 - s) * f.hopH)
            n.yScale = 1 + 0.25 * sin(s * .pi)               // stretches in the air
            n.xScale = 1 - 0.1 * sin(s * .pi)
            n.zRotation = (to.x >= f.from.x ? -1 : 1) * 0.25 * sin(s * .pi)
            if s >= 1 {
                f.hopping = false
                f.perchID = f.toID
                f.perchOff = f.toOff
                f.groundX = f.toGroundX
                n.zRotation = 0
                splash(at: to, big: false)
            }
            return
        }

        guard let pos = frogSpot(id: f.perchID, off: f.perchOff, gx: f.groundX) else {
            startHop(f, scared: true)                         // its window is gone: hop somewhere else
            return
        }
        n.position = pos
        n.yScale = 1 + 0.03 * sin(t * 3 + f.phase)           // breathing
        n.xScale = 1
        if f.perchID >= 0, let idx = order.firstIndex(where: { $0.id == f.perchID }) {
            let pt = CGPoint(x: pos.x, y: pos.y + 1)
            n.isHidden = order[..<idx].contains { $0.rect.contains(pt) }
        }
        if Cfg.on(.mouse) && mouseSpeed > 250 && hypot(pos.x - mouse.x, pos.y - mouse.y) < 90 {
            startHop(f, scared: true)                         // startled by the mouse
        } else if t > f.nextHop && f.active {
            startHop(f, scared: false)
        }
        if t > f.nextCroak && (nightW > 0.3 || intensity > 0.4) && !n.isHidden {
            ribbit(at: pos)
            f.nextCroak = t + rnd(8, 22)
        } else if t > f.nextCroak {
            f.nextCroak = t + rnd(4, 10)
        }
    }

    func ribbit(at p: CGPoint) {
        let label = SKLabelNode(text: ["ribbit!", "croak!", "ribbit ribbit"].randomElement() ?? "ribbit!")
        label.fontName = "Avenir-Heavy"
        label.fontSize = 12
        label.fontColor = NSColor(calibratedWhite: 0.1, alpha: 1)
        label.verticalAlignmentMode = .center
        let bg = SKShapeNode(rectOf: CGSize(width: label.frame.width + 14, height: 20), cornerRadius: 10)
        bg.fillColor = NSColor(calibratedWhite: 1, alpha: 0.9)
        bg.strokeColor = .clear
        bg.position = CGPoint(x: p.x, y: p.y + 54)
        bg.addChild(label)
        frogLayer.addChild(bg)
        bg.run(.sequence([.wait(forDuration: 1.3), .fadeOut(withDuration: 0.3), .removeFromParent()]))
    }

    // MARK: Windows (macOS origin is top-left, SpriteKit is bottom-left, so flip y)

    func pollWindows() {
        let H = size.height, W = size.width
        var newOrder: [(id: Int, rect: CGRect)] = []
        if let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for w in info {
                guard let layerN = w[kCGWindowLayer as String] as? NSNumber, layerN.intValue == 0,
                      let pidN = w[kCGWindowOwnerPID as String] as? NSNumber, pidN.int32Value != myPID,
                      let numN = w[kCGWindowNumber as String] as? NSNumber,
                      let bd = w[kCGWindowBounds as String] as? NSDictionary,
                      let b = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
                let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
                if alpha < 0.05 || b.width < 100 || b.height < 50 { continue }
                let r = CGRect(x: b.minX, y: H - b.maxY, width: b.width, height: b.height)
                if r.maxY >= H - 1 || r.maxX < 20 || r.minX > W - 20 { continue }
                newOrder.append((id: numN.intValue, rect: r))
            }
        }
        order = newOrder
        lastRect = Dictionary(newOrder.map { ($0.id, $0.rect) }, uniquingKeysWith: { a, _ in a })

        // Frogs come out in the rain and at night
        let fa = clamp(0.25 + 0.7 * intensity + 0.6 * nightW + 0.4 * duskW, 0, 1)
        let activeF = Cfg.on(.frogs) ? Int((CGFloat(Cfg.frogCount) * fa).rounded(.up)) : 0
        for (i, f) in frogs.enumerated() { f.active = i < activeF }
    }
}

// MARK: - Location (only used to know the time of day; never leaves your Mac)

@MainActor final class LocationProvider: NSObject, CLLocationManagerDelegate {
    let mgr = CLLocationManager()
    var onChange: (() -> Void)?

    override init() {
        super.init()
        let d = UserDefaults.standard
        if d.object(forKey: "lat") != nil {
            Cfg.lat = d.double(forKey: "lat")
            Cfg.lon = d.double(forKey: "lon")
        } else {                                              // until we know better, guess from the time zone
            Cfg.lon = Double(TimeZone.current.secondsFromGMT()) / 240.0
            Cfg.lat = 20
        }
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func refresh() {
        mgr.requestWhenInUseAuthorization()
        mgr.requestLocation()
    }

    func set(_ la: Double, _ lo: Double) {
        Cfg.lat = la
        Cfg.lon = lo
        UserDefaults.standard.set(la, forKey: "lat")
        UserDefaults.standard.set(lo, forKey: "lon")
        onChange?()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        let la = l.coordinate.latitude, lo = l.coordinate.longitude
        Task { @MainActor in self.set(la, lo) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways { manager.requestLocation() }
    }
}

// MARK: - App: transparent click-through overlay + menu bar item

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var scene: RainScene!
    var statusItem: NSStatusItem!
    var pauseItem: NSMenuItem!
    var infoItem: NSMenuItem!
    var locItem: NSMenuItem!
    var weatherItems: [NSMenuItem] = []
    var featureItems: [NSMenuItem] = []
    var modeItems: [NSMenuItem] = []
    var paused = false
    let location = LocationProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first else { NSApp.terminate(nil); return }
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true               // clicks go through to what is underneath
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let skView = SKView(frame: NSRect(origin: .zero, size: screen.frame.size))
        skView.allowsTransparency = true
        window.contentView = skView
        scene = RainScene(size: screen.frame.size)
        scene.scaleMode = .resizeFill
        buildMenu()
        scene.onStatus = { [weak self] icon, info in
            self?.statusItem.button?.title = icon
            self?.infoItem.title = info
        }
        skView.presentScene(scene)
        window.orderFrontRegardless()

        location.onChange = { [weak self] in self?.updateLocationTitle() }
        location.refresh()
        updateLocationTitle()
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func updateLocationTitle() {
        locItem.title = String(format: "📍 %.1f°%@, %.1f°%@ — update my location", abs(Cfg.lat), Cfg.lat >= 0 ? "N" : "S",
                               abs(Cfg.lon), Cfg.lon >= 0 ? "E" : "W")
    }

    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🌧️"
        let menu = NSMenu()

        infoItem = NSMenuItem(title: "Reading the sky…", action: nil, keyEquivalent: "")
        infoItem.isEnabled = false
        menu.addItem(infoItem)
        locItem = NSMenuItem(title: "📍 update my location", action: #selector(updateLocation), keyEquivalent: "")
        locItem.target = self
        menu.addItem(locItem)
        menu.addItem(.separator())

        pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())

        let weatherNames = ["Auto weather", "Drizzle", "Steady rain", "Downpour", "Thunderstorm", "Clear sky"]
        for (i, title) in weatherNames.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(setWeather(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            item.state = i == Cfg.weather ? .on : .off
            weatherItems.append(item)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let bolt = NSMenuItem(title: "⚡ Strike lightning", action: #selector(strike), keyEquivalent: "")
        bolt.target = self
        menu.addItem(bolt)
        let bow = NSMenuItem(title: "🌈 Make a rainbow", action: #selector(rainbowNow), keyEquivalent: "")
        bow.target = self
        menu.addItem(bow)
        menu.addItem(.separator())

        let names = ["Lightning", "Storm clouds", "Mist", "Puddles & paper boats", "Rainbows after rain", "Frogs",
                     "Umbrella follows mouse", "Mouse interaction (gusts, frogs hop away)", "Sky tint (grey day / dark night)"]
        for f in Feature.allCases {
            let item = NSMenuItem(title: names[f.rawValue], action: #selector(toggleFeature(_:)), keyEquivalent: "")
            item.tag = f.rawValue
            item.target = self
            item.state = Cfg.on(f) ? .on : .off
            featureItems.append(item)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        for (i, title) in ["Real time", "Time lapse (a day in 2 minutes)", "Preview: noon",
                           "Preview: golden hour", "Preview: night"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(setMode(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            item.state = i == Cfg.mode ? .on : .off
            modeItems.append(item)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func updateLocation() { location.refresh() }
    @objc func strike() { scene.forceLightning() }
    @objc func rainbowNow() { scene.forceRainbow() }

    @objc func togglePause() {
        paused.toggle()
        scene.isPaused = paused
        if paused { window.orderOut(nil) } else { window.orderFrontRegardless() }
        pauseItem.title = paused ? "Resume" : "Pause"
    }

    @objc func setWeather(_ sender: NSMenuItem) {
        Cfg.weather = sender.tag
        for i in weatherItems { i.state = i === sender ? .on : .off }
    }

    @objc func toggleFeature(_ sender: NSMenuItem) {
        Cfg.enabled[sender.tag].toggle()
        sender.state = Cfg.enabled[sender.tag] ? .on : .off
    }

    @objc func setMode(_ sender: NSMenuItem) {
        Cfg.mode = sender.tag
        for i in modeItems { i.state = i === sender ? .on : .off }
        scene.applyMode()
    }

    @objc func screenChanged() {
        guard let s = NSScreen.screens.first else { return }
        window.setFrame(s.frame, display: true)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)     // no Dock icon
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()                               // blocks here, so `delegate` stays alive
}
