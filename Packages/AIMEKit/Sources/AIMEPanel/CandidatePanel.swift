public import AppKit
import os

/// Borderless, non-activating window that floats the candidate view next to the
/// text cursor. One instance lives for the whole input method process.
///
/// Per keystroke the main thread only lays out text and moves layers. The window is
/// sized in coarse steps ("capacity") and never shrinks while visible, so typing does
/// not resize the window or make the window server recompute its shadow; the rounded
/// background, its shadow, the blur and the text clip are standalone layers whose
/// geometry changes are animated by the render server.
@MainActor
public final class CandidatePanel {
    public let view = CandidateView()
    private let window: NSPanel
    private let effect = NSVisualEffectView()
    private let signposter = OSSignposter(subsystem: "app.zool.aime", category: "panel")
    private var lastCursorRect: NSRect = .zero
    private let container = NSView()
    /// Rounded background + shadow.
    private let background = CALayer()
    /// Clips the blur and the text to the (animating) background shape.
    private let effectMask = CALayer()
    private let textMask = CALayer()
    private var capacity: NSSize = .zero
    /// Visible frames of the screens, fetched when the panel appears: asking AppKit on
    /// every keystroke round-trips to the window server.
    private var screenFrames: [(frame: NSRect, visible: NSRect)] = []
    private var contentFrame: NSRect = .zero

    /// Motion is on unless the user asked to reduce it. Tests switch it off.
    public var animationsEnabled = true
    private var motionAllowed: Bool {
        animationsEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    static let resizeDuration: CFTimeInterval = 0.1
    static let appearDuration: CFTimeInterval = 0.12
    /// Room around the content for the layer shadow.
    static let margin: CGFloat = 18

    public var theme: PanelTheme {
        get { view.theme }
        set {
            view.theme = newValue
            effect.isHidden = !newValue.translucency
        }
    }

    public var isVisible: Bool { window.isVisible }

    public init() {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) - 1)
        window.backgroundColor = .clear
        window.isOpaque = false
        // The shadow is drawn by `background`; a window shadow would be recomputed by the
        // window server on every content change.
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.animationBehavior = .none

        container.wantsLayer = true
        container.layer?.addSublayer(background)
        background.shadowOffset = CGSize(width: 0, height: -3)
        for mask in [effectMask, textMask] { mask.backgroundColor = CGColor(gray: 0, alpha: 1) }
        view.drawsBackground = false
        view.wantsLayer = true
        view.layer?.mask = textMask
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.mask = effectMask
        effect.isHidden = true
        container.addSubview(effect)
        container.addSubview(view)
        window.contentView = container
    }

    /// Shows `state` next to `cursorRect` (screen coordinates, AppKit origin).
    ///
    /// Motion never delays feedback: text is laid out and drawn at its final size right
    /// away; the background and the clip grow or shrink to it in the render server.
    ///
    /// `transition` choreographs a change of layer (candidates ↔ menu ↔ a menu page): the
    /// content crossfades and glides a few points in the direction of travel while the
    /// background springs to its new size — all in the render server.
    public func show(_ state: PanelState, at cursorRect: NSRect, transition requested: Transition = .none) {
        guard !state.isEmpty else { hide(); return }
        let transition = pendingTransition ?? requested
        pendingTransition = nil
        let interval = signposter.beginInterval("update")
        defer { signposter.endInterval("update", interval) }

        let appearing = !window.isVisible
        if appearing || screenFrames.isEmpty { screenFrames = NSScreen.screens.map { ($0.frame, $0.visibleFrame) } }
        if cursorRect != .zero { lastCursorRect = cursorRect }
        // One candidate: never wider than the theme's limit or 60 % of the screen the cursor
        // is on. A whole row may use up to 90 % of that screen.
        let screenWidth = (screenFrames.first { $0.frame.contains(lastCursorRect.origin) } ?? screenFrames.first)?.visible.width ?? 1440
        let themeLimit = view.theme.maxWidth
        view.maxContentWidth = floor(min(themeLimit > 0 ? themeLimit : .greatestFiniteMagnitude, screenWidth * 0.6))
        view.maxRowWidth = floor(screenWidth * 0.9)
        view.state = state
        let size = view.fittingContentSize
        let margin = Self.margin

        // Grow the window in steps; keep it while visible.
        let needed = NSSize(width: size.width + margin * 2, height: size.height + margin * 2)
        if appearing || needed.width > capacity.width || needed.height > capacity.height {
            capacity = NSSize(width: max(capacity.width, ceil(needed.width / 96) * 96),
                              height: max(capacity.height, ceil(needed.height / 48) * 48))
            if appearing { capacity = NSSize(width: ceil(needed.width / 96) * 96, height: ceil(needed.height / 48) * 48) }
        }
        // Content's top-left sits next to the cursor; the window extends right and down.
        let content = position(for: size, cursor: lastCursorRect)
        let frame = NSRect(x: content.minX - margin, y: content.maxY + margin - capacity.height,
                           width: capacity.width, height: capacity.height)
        if window.frame.size != frame.size {
            window.setFrame(frame, display: false)
            container.frame = NSRect(origin: .zero, size: capacity)
            effect.frame = container.bounds
        } else if window.frame.origin != frame.origin {
            window.setFrameOrigin(frame.origin)
        }

        let previous = contentFrame
        contentFrame = NSRect(x: margin, y: capacity.height - margin - size.height, width: size.width, height: size.height)
        // The text view keeps its size once large enough; only the clip changes.
        let viewSize = appearing ? size
            : NSSize(width: max(view.frame.width, size.width), height: max(view.frame.height, size.height))
        let viewFrame = NSRect(x: margin, y: contentFrame.maxY - viewSize.height, width: viewSize.width, height: viewSize.height)
        if view.frame != viewFrame { view.frame = viewFrame }
        view.needsDisplay = true

        let animate = motionAllowed && !appearing && previous != .zero && previous.size != size
        let transitioning = transition != .none && motionAllowed && !appearing
        if transitioning { playTransition(transition) }
        hideHoldCue()
        let theme = view.theme
        let radius = min(theme.cornerRadius, size.height / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        styleBackground(radius: radius)
        if animate {
            // Start from the previous shape, anchored at the same top-left corner.
            let start = NSRect(x: margin, y: contentFrame.maxY - previous.height, width: previous.width, height: previous.height)
            place(start, radius: min(theme.cornerRadius, previous.height / 2))
        }
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setDisableActions(!animate)
        // Layer changes get a longer, springier resize than per-keystroke updates.
        CATransaction.setAnimationDuration(transitioning ? Self.transitionDuration : Self.resizeDuration)
        CATransaction.setAnimationTimingFunction(transitioning
            ? CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1.0) : CAMediaTimingFunction(name: .easeOut))
        place(contentFrame, radius: radius)
        CATransaction.commit()

        if state.busy || state.glow { showBusy(radius: radius, shimmer: state.busy) } else { hideBusy() }
        updateHeroGlow()

        if appearing {
            window.alphaValue = 1
            window.orderFrontRegardless()
            if motionAllowed { playAppear() }
        }
    }

    // MARK: - Glow

    /// While an AI action runs: a soft ring of slowly turning colour around the panel and
    /// a light sweep across its caption. On a menu page the same ring, thinner, sits
    /// around the main action. Both are render-server animations; with reduced motion the
    /// ring is shown still.
    private let busyGlow = GlowRing()
    private let heroGlow = GlowRing()
    private let shimmer = CAGradientLayer()
    static let busySpread: CGFloat = 12
    /// Whether the glows are currently shown (for tests).
    var isBusyShown: Bool { busyGlow.isShown }
    var isHeroGlowShown: Bool { heroGlow.isShown }

    private func showBusy(radius: CGFloat, shimmer showsShimmer: Bool) {
        guard let host = container.layer, let textLayer = view.layer else { return }
        let wasShown = busyGlow.isShown
        let resized = wasShown && busyGlow.frame.size != contentFrame.insetBy(dx: -Self.busySpread, dy: -Self.busySpread).size
        busyGlow.show(in: host, below: background, rect: contentFrame, radius: radius, spread: Self.busySpread,
                      strokes: [(3, 0.85), (6, 0.22), (9, 0.15), (12, 0.1), (15, 0.07), (19, 0.04), (23, 0.025)],
                      period: 3.2, sheen: nil, animated: motionAllowed)
        // Moving between AI layers the panel changes size; the ring follows by fading back
        // in around the new outline rather than jumping.
        if resized, motionAllowed { busyGlow.fadeIn(delay: Self.transitionDuration * 0.5) }

        guard showsShimmer else {
            if shimmer.superlayer != nil {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                shimmer.removeAllAnimations()
                shimmer.removeFromSuperlayer()
                CATransaction.commit()
            }
            return
        }
        let shimmerWasShown = shimmer.superlayer != nil
        // A band of the background colour that travels across the caption.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let back = view.theme.effectiveBackColor
        func band(_ alpha: Double) -> CGColor { CGColor(srgbRed: back.red, green: back.green, blue: back.blue, alpha: alpha) }
        shimmer.colors = [band(0), band(0.62), band(0)]
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.locations = [-0.5, -0.25, 0]
        shimmer.frame = textMask.frame
        if shimmer.superlayer == nil { textLayer.addSublayer(shimmer) }
        CATransaction.commit()

        guard motionAllowed, !shimmerWasShown else { return }
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-0.5, -0.25, 0]
        sweep.toValue = [1, 1.25, 1.5]
        sweep.duration = 1.6
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shimmer.add(sweep, forKey: "sweep")
    }

    private func hideBusy() {
        busyGlow.hide()
        guard shimmer.superlayer != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shimmer.removeAllAnimations()
        shimmer.removeFromSuperlayer()
        CATransaction.commit()
    }

    /// The ring around a menu page's main action (view coordinates).
    private func updateHeroGlow() {
        let rect = view.heroFrame
        guard rect != .zero, let host = view.layer else { return heroGlow.hide() }
        heroGlow.show(in: host, below: nil, rect: rect, radius: view.heroCornerRadius, spread: 6,
                      strokes: [(1.5, 0.95), (4, 0.2), (7, 0.11), (10, 0.05)], period: 4,
                      sheen: CGColor(srgbRed: 0.13, green: 0.78, blue: 0.93, alpha: 0.16), animated: motionAllowed)
    }

    // MARK: - Transitions

    public enum Transition: Sendable, Equatable {
        case none
        /// Going deeper (candidates → menu → page): content arrives from the right.
        case push
        /// Going back: content arrives from the left.
        case pop
        /// Same level, different content (category tabs): crossfade only.
        case fade
        /// Opening the menu from the candidates: content rises into place.
        case morph
    }

    /// Used by the next `show` when the caller cannot pass a transition itself.
    public var pendingTransition: Transition?
    static let transitionDuration: CFTimeInterval = 0.24

    private func playTransition(_ transition: Transition) {
        guard let layer = view.layer else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "contentFade")
        let offset: CGSize = switch transition {
        case .push: CGSize(width: 14, height: 0)
        case .pop: CGSize(width: -14, height: 0)
        case .morph: CGSize(width: 0, height: 8)
        case .fade, .none: .zero
        }
        guard offset != .zero else { return }
        let glide = CASpringAnimation(keyPath: "transform")
        glide.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(offset.width, offset.height, 0))
        glide.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        glide.damping = 22
        glide.stiffness = 320
        glide.mass = 1
        glide.duration = min(glide.settlingDuration, 0.4)
        layer.add(glide, forKey: "contentGlide")
    }

    // MARK: - Hold cue

    /// A soft glow behind the menu button while the hold key is down, so the eye is
    /// already on the spot the menu grows from. It waits a moment before showing (quick
    /// taps and shortcuts show nothing), has no outline, and fades out when let go.
    private let holdGlow = CALayer()
    static let holdCueDelay: CFTimeInterval = 0.12

    public func showHoldCue(duration: CFTimeInterval) {
        guard window.isVisible, motionAllowed, let host = view.layer else { return }
        let target = view.menuButtonFrame
        guard target != .zero else { return }
        let rect = target.insetBy(dx: -3, dy: -3)
        let theme = view.theme
        let tint = theme.candidateTextColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        holdGlow.removeAllAnimations()
        holdGlow.frame = rect
        holdGlow.cornerRadius = min(rect.width, rect.height) * 0.32
        holdGlow.cornerCurve = .continuous
        holdGlow.backgroundColor = CGColor(srgbRed: tint.red, green: tint.green, blue: tint.blue, alpha: 0.13)
        holdGlow.opacity = 1
        if holdGlow.superlayer !== host { host.insertSublayer(holdGlow, at: 0) }
        CATransaction.commit()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.72
        grow.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [fade, grow]
        // Nothing during the delay, then a gentle rise over the rest of the hold.
        group.beginTime = holdGlow.convertTime(CACurrentMediaTime(), from: nil) + Self.holdCueDelay
        group.duration = max(0.1, duration - Self.holdCueDelay)
        group.fillMode = .backwards
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        holdGlow.add(group, forKey: "hold")
    }

    /// Removes the cue; `animated` fades it out (the key was let go) instead of cutting.
    public func hideHoldCue(animated: Bool = false) {
        guard holdGlow.superlayer != nil else { return }
        guard animated, motionAllowed, let shown = holdGlow.presentation()?.opacity, shown > 0.01 else {
            holdGlow.removeAllAnimations()
            holdGlow.removeFromSuperlayer()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                // A new hold may have started meanwhile; only remove a glow that is still fading.
                guard let self, self.holdGlow.animation(forKey: "hold") == nil else { return }
                self.holdGlow.removeAllAnimations()
                self.holdGlow.removeFromSuperlayer()
            }
        }
        holdGlow.removeAnimation(forKey: "hold")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = shown
        fade.toValue = 0
        fade.duration = 0.14
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        holdGlow.opacity = 0
        holdGlow.add(fade, forKey: "fadeOut")
        CATransaction.commit()
    }

    /// Positions the background, its shadow and both clips on `rect` (container coordinates).
    private func place(_ rect: NSRect, radius: CGFloat) {
        background.frame = rect
        background.cornerRadius = radius
        background.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size),
                                       cornerWidth: radius, cornerHeight: radius, transform: nil)
        effectMask.frame = rect
        effectMask.cornerRadius = radius
        // textMask lives in the text view's coordinate space.
        // The text view is flipped, so is its layer: measure the clip from the top edge.
        textMask.frame = NSRect(x: rect.minX - view.frame.minX, y: view.frame.maxY - rect.maxY,
                                width: rect.width, height: rect.height)
        textMask.cornerRadius = radius
    }

    private func styleBackground(radius: CGFloat) {
        let theme = view.theme
        let back = theme.effectiveBackColor
        background.backgroundColor = CGColor(srgbRed: back.red, green: back.green, blue: back.blue, alpha: back.alpha)
        background.cornerCurve = .continuous
        effectMask.cornerCurve = .continuous
        textMask.cornerCurve = .continuous
        let border = theme.borderColor
        if border.alpha > 0 {
            background.borderWidth = 1
            background.borderColor = CGColor(srgbRed: border.red, green: border.green, blue: border.blue, alpha: border.alpha)
        } else {
            // A hairline keeps the edge crisp on backgrounds of similar brightness.
            background.borderWidth = 1 / max(1, window.backingScaleFactor)
            background.borderColor = theme.hasDarkBackground ? CGColor(gray: 1, alpha: 0.12) : CGColor(gray: 0, alpha: 0.1)
        }
        let appearance = NSAppearance(named: theme.hasDarkBackground ? .darkAqua : .aqua)
        if effect.appearance?.name != appearance?.name { effect.appearance = appearance }
        background.shadowOpacity = theme.translucency ? 0.22 : 0.18
        background.shadowRadius = 8
        background.shadowColor = CGColor(gray: 0, alpha: 1)
        effect.isHidden = !theme.translucency
    }

    /// Fade in while growing from 96% around the content's top-left corner (near the cursor).
    private func playAppear() {
        guard let layer = container.layer else { return }
        let pivot = CGPoint(x: contentFrame.minX, y: contentFrame.maxY)
        var start = CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
        start = CATransform3DScale(start, 0.96, 0.96, 1)
        start = CATransform3DTranslate(start, -pivot.x, -pivot.y, 0)
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: start)
        scale.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = Self.appearDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "appear")
    }

    /// Current content size (for tests and diagnostics).
    public var frameSize: NSSize { contentFrame.size }
    /// Clip applied to the text view, in its own (flipped) coordinates (for tests).
    var textClipFrame: NSRect { textMask.frame }
    /// Current window size; changes only in steps while visible.
    public var windowSize: NSSize { window.frame.size }

    public func hide() {
        container.layer?.removeAllAnimations()
        for layer in [background, effectMask, textMask] { layer.removeAllAnimations() }
        view.layer?.removeAllAnimations()
        hideHoldCue()
        hideBusy()
        heroGlow.hide()
        pendingTransition = nil
        contentFrame = .zero
        if window.isVisible { window.orderOut(nil) }
    }

    /// Content rectangle below the cursor, flipped above when it would leave the
    /// screen, clamped horizontally.
    func position(for size: NSSize, cursor: NSRect) -> NSRect {
        let screens = screenFrames.isEmpty ? NSScreen.screens.map { ($0.frame, $0.visibleFrame) } : screenFrames
        let visible = (screens.first { $0.0.contains(cursor.origin) } ?? screens.first)?.1
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap = 4 + theme.baseOffset
        var origin = NSPoint(x: cursor.minX - theme.borderWidth - 4, y: cursor.minY - size.height - gap)
        if origin.y < visible.minY { origin.y = cursor.maxY + gap }
        if origin.y + size.height > visible.maxY { origin.y = visible.maxY - size.height }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        return NSRect(origin: origin, size: size)
    }
}

/// A ring of slowly turning colour along a rounded outline, with a soft falloff, and
/// optionally a band of light sweeping across the inside.
@MainActor
final class GlowRing {
    private let layer = CALayer()
    private let gradient = CAGradientLayer()
    private let mask = CALayer()
    private let sheen = CAGradientLayer()
    /// Cool hues with one warm accent; the list is symmetric so the ring has no seam.
    static let colors: [CGColor] = [
        (0.10, 0.60, 1.00), (0.13, 0.83, 0.93), (0.20, 0.83, 0.60), (0.98, 0.75, 0.14),
        (0.20, 0.83, 0.60), (0.13, 0.83, 0.93), (0.10, 0.60, 1.00),
    ].map { CGColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) }

    var isShown: Bool { layer.superlayer != nil }
    var frame: CGRect { layer.frame }

    /// Fades the ring in again (after its outline changed).
    func fadeIn(delay: CFTimeInterval) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        fade.duration = 0.3
        fade.fillMode = .backwards
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "refade")
    }

    /// `strokes` are (line width, opacity) pairs drawn on the outline: one crisp line plus
    /// wider, fainter ones that add up to a soft falloff reaching `spread` points out.
    func show(in host: CALayer, below sibling: CALayer?, rect: CGRect, radius: CGFloat, spread: CGFloat,
              strokes: [(CGFloat, CGFloat)], period: CFTimeInterval, sheen sheenColor: CGColor?, animated: Bool) {
        let wasShown = isShown
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = rect.insetBy(dx: -spread, dy: -spread)
        mask.frame = layer.bounds
        mask.sublayers?.forEach { $0.removeFromSuperlayer() }
        let outline = CGPath(roundedRect: CGRect(x: spread, y: spread, width: rect.width, height: rect.height),
                             cornerWidth: radius, cornerHeight: radius, transform: nil)
        for (width, alpha) in strokes {
            let stroke = CAShapeLayer()
            stroke.frame = mask.bounds
            stroke.path = outline
            stroke.fillColor = nil
            stroke.strokeColor = CGColor(gray: 0, alpha: alpha)
            stroke.lineWidth = width
            mask.addSublayer(stroke)
        }
        layer.mask = mask
        let side = ceil(hypot(layer.bounds.width, layer.bounds.height))
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.colors = Self.colors
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        if gradient.superlayer == nil { layer.addSublayer(gradient) }
        if !wasShown {
            if let sibling { host.insertSublayer(layer, below: sibling) } else { host.insertSublayer(layer, at: 0) }
        }
        if let sheenColor {
            sheen.colors = [sheenColor.copy(alpha: 0)!, sheenColor, sheenColor.copy(alpha: 0)!]
            sheen.startPoint = CGPoint(x: 0, y: 0.5)
            sheen.endPoint = CGPoint(x: 1, y: 0.5)
            sheen.locations = [-0.6, -0.3, 0]
            sheen.frame = rect
            sheen.cornerRadius = radius
            sheen.cornerCurve = .continuous
            sheen.masksToBounds = true
            if sheen.superlayer == nil { host.insertSublayer(sheen, above: layer) }
        } else if sheen.superlayer != nil {
            sheen.removeAllAnimations()
            sheen.removeFromSuperlayer()
        }
        CATransaction.commit()

        guard animated, !wasShown else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.35
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "fadeIn")
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = period
        spin.repeatCount = .infinity
        gradient.add(spin, forKey: "spin")
        if sheenColor != nil {
            // One pass, then a pause, so the row is not restless.
            let sweep = CABasicAnimation(keyPath: "locations")
            sweep.fromValue = [-0.6, -0.3, 0]
            sweep.toValue = [1, 1.3, 1.6]
            sweep.duration = 1.3
            sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            let cycle = CAAnimationGroup()
            cycle.animations = [sweep]
            cycle.duration = 3.4
            cycle.repeatCount = .infinity
            cycle.beginTime = sheen.convertTime(CACurrentMediaTime(), from: nil) + 0.25
            sheen.add(cycle, forKey: "sweep")
        }
    }

    func hide() {
        guard isShown || sheen.superlayer != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.removeAllAnimations()
        layer.removeAllAnimations()
        layer.removeFromSuperlayer()
        sheen.removeAllAnimations()
        sheen.removeFromSuperlayer()
        CATransaction.commit()
    }
}
