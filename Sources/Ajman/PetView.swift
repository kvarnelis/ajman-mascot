import AppKit

final class PetView: NSView {
    static let sleepBreathingScale = 1.02
    static let sleepBreathingHalfPeriod: TimeInterval = 5
    static let sleepBreathingAnchorPoint = CGPoint(x: 0.5, y: 0)

    private static let breathingAnimationKey = "sleep-breathing"
    private static let scratchRakeAnimationKey = "scratch-rake"
    private let imageLayer = CALayer()

    var isBreathing: Bool { imageLayer.animation(forKey: Self.breathingAnimationKey) != nil }
    var isScratchRaking: Bool { imageLayer.animation(forKey: Self.scratchRakeAnimationKey) != nil }

    var image: CGImage? {
        didSet { setImage(image) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .trilinear
        imageLayer.anchorPoint = Self.sleepBreathingAnchorPoint
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { nil }

    /// Control-click/right-click is owned by the pet action cycle, never a context menu.
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func layout() {
        super.layout()
        imageLayer.bounds = bounds
        imageLayer.position = CGPoint(x: bounds.midX, y: bounds.minY)
    }

    func setImage(_ image: CGImage?, crossfadeDuration: TimeInterval = 0) {
        if crossfadeDuration > 0, imageLayer.contents != nil {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = crossfadeDuration
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            imageLayer.add(transition, forKey: "sleep-pose-crossfade")
        }
        imageLayer.contents = image
    }

    func setBreathingEnabled(_ enabled: Bool, temperament: Temperament = .normal) {
        guard enabled else {
            imageLayer.removeAnimation(forKey: Self.breathingAnimationKey)
            return
        }
        guard !isBreathing else { return }

        let breathing = CABasicAnimation(keyPath: "transform.scale.y")
        breathing.fromValue = 1.0
        breathing.toValue = temperament.scaledBreathingScale(Self.sleepBreathingScale)
        breathing.duration = temperament.scaledCalmPose(interval: Self.sleepBreathingHalfPeriod)
        breathing.autoreverses = true
        breathing.repeatCount = .infinity
        breathing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        imageLayer.add(breathing, forKey: Self.breathingAnimationKey)
    }

    func setScratchRaking(_ enabled: Bool, amplitude: CGFloat = ScratchBehavior.rakeAmplitude) {
        imageLayer.removeAnimation(forKey: Self.scratchRakeAnimationKey)
        guard enabled else { return }

        let rake = CABasicAnimation(keyPath: "transform.translation.y")
        rake.fromValue = -amplitude
        rake.toValue = amplitude
        rake.duration = ScratchBehavior.rakeDuration / (Double(ScratchBehavior.rakeCycles) * 2)
        rake.autoreverses = true
        rake.repeatCount = Float(ScratchBehavior.rakeCycles)
        rake.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        imageLayer.add(rake, forKey: Self.scratchRakeAnimationKey)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }
}
