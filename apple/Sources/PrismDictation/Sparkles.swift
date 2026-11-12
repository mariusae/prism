import CoreGraphics
import QuartzCore

/// The caret while words are said into a note: a bar of light, glittering,
/// throwing off small stars that drift back over the words just written
/// and go out — the words as if coming out of it.
public enum Sparkles {
    /// What glitters off the caret: stars, and finer dust. `color`: the accent.
    public static func emitter(_ color: CGColor) -> CAEmitterLayer {
        let emitter = CAEmitterLayer()
        emitter.emitterShape = .rectangle
        emitter.emitterMode = .surface
        emitter.emitterCells = [cell(star, color, birth: 9, scale: 0.2, velocity: 16),
                                cell(dust, color, birth: 26, scale: 0.12, velocity: 22)]
        return emitter
    }

    /// The caret moved, to `rect`, `busy` while words are coming out of it.
    public static func place(_ emitter: CAEmitterLayer, at rect: CGRect, busy: Bool) {
        emitter.emitterPosition = CGPoint(x: rect.midX, y: rect.midY)
        emitter.emitterSize = CGSize(width: 2, height: rect.height)
        emitter.birthRate = busy ? 1 : 0.3
    }

    /// The caret itself: a bar of the accent, glowing.
    public static func bar(_ color: CGColor) -> CALayer {
        let bar = CALayer()
        bar.backgroundColor = color
        bar.cornerRadius = 1
        bar.shadowColor = color
        bar.shadowOffset = .zero
        bar.shadowRadius = 5
        bar.shadowOpacity = 0.9
        return bar
    }

    /// The bar where the caret is, twinkling.
    public static func glint(_ bar: CALayer, at rect: CGRect, now: CFTimeInterval) {
        bar.frame = CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height)
        let twinkle = abs(sin(now * 5)) * 0.6 + abs(sin(now * 13 + 1)) * 0.4
        bar.opacity = Float(0.7 + 0.3 * twinkle)
        bar.shadowRadius = 3 + 4 * twinkle
    }

    private static func cell(_ image: CGImage?, _ color: CGColor, birth: Float, scale: CGFloat, velocity: CGFloat) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = image
        cell.color = color
        cell.redRange = 0.15
        cell.greenRange = 0.15
        cell.blueRange = 0.1
        cell.birthRate = birth
        cell.lifetime = 0.9
        cell.lifetimeRange = 0.4
        cell.velocity = velocity
        cell.velocityRange = velocity * 0.7
        // Back over what was written, and up a little.
        cell.emissionLongitude = .pi
        cell.emissionRange = .pi * 0.7
        cell.yAcceleration = -10
        cell.scale = scale
        cell.scaleRange = scale * 0.6
        cell.scaleSpeed = -scale * 0.6
        cell.alphaSpeed = -1
        cell.spin = 1.5
        cell.spinRange = 4
        return cell
    }

    /// A star of four points, soft at its heart.
    private static let star: CGImage? = draw(side: 48) { context, side in
        let middle = side / 2, reach = side / 2, waist = side * 0.07
        let path = CGMutablePath()
        path.move(to: CGPoint(x: middle, y: middle - reach))
        path.addQuadCurve(to: CGPoint(x: middle + reach, y: middle), control: CGPoint(x: middle + waist, y: middle - waist))
        path.addQuadCurve(to: CGPoint(x: middle, y: middle + reach), control: CGPoint(x: middle + waist, y: middle + waist))
        path.addQuadCurve(to: CGPoint(x: middle - reach, y: middle), control: CGPoint(x: middle - waist, y: middle + waist))
        path.addQuadCurve(to: CGPoint(x: middle, y: middle - reach), control: CGPoint(x: middle - waist, y: middle - waist))
        context.addPath(path)
        context.fillPath()
    }

    /// A speck, bright in the middle, fading out.
    private static let dust: CGImage? = draw(side: 24) { context, side in
        let space = CGColorSpaceCreateDeviceRGB()
        let colors = [CGColor(red: 1, green: 1, blue: 1, alpha: 1), CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return }
        let middle = CGPoint(x: side / 2, y: side / 2)
        context.drawRadialGradient(gradient, startCenter: middle, startRadius: 0, endCenter: middle, endRadius: side / 2, options: [])
    }

    private static func draw(side: CGFloat, _ body: (CGContext, CGFloat) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        body(context, side)
        return context.makeImage()
    }
}
