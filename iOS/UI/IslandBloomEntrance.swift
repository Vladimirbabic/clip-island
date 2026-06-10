import SwiftUI

// MARK: - Entrance model

/// Decides when the launch entrance replays. Cold launches always play it
/// (the container animates once on first appear); foregrounding replays it
/// only after the app spent at least `minimumBackgroundInterval` in the
/// background. `.inactive` blips (app switcher, Control Center) never count.
@MainActor
final class BloomEntranceModel: ObservableObject {
    /// Single source of truth for the "long enough in background" rule.
    static let minimumBackgroundInterval: TimeInterval = 60

    /// Bumped to request a replay; the container re-runs its entrance task
    /// whenever this changes.
    @Published private(set) var generation = 0

    private var backgroundedAt: Date?

    func sceneDidEnterBackground(now: Date = .now) {
        backgroundedAt = now
    }

    func sceneDidBecomeActive(now: Date = .now) {
        guard let backgroundedAt else { return }
        self.backgroundedAt = nil
        if now.timeIntervalSince(backgroundedAt) >= Self.minimumBackgroundInterval {
            generation += 1
        }
    }
}

// MARK: - Tuning

/// Geometry of the Dynamic Island, derived from the safe area instead of a
/// device list: island hardware reports a top safe-area inset of at least
/// 59pt; the cutout is ~126x37pt, horizontally centered, sitting ~11pt from
/// the top of the screen (its bottom sits the same margin above the inset
/// line, which keeps the frame correct on taller-inset models).
private enum IslandMetrics {
    static let minimumTopInset: CGFloat = 59
    static let size = CGSize(width: 126, height: 37)
    static let capsuleCornerRadius: CGFloat = 18.5
    static let verticalMargin: CGFloat = 11
    /// Approximate physical display corner radius the clip relaxes into;
    /// once the clip covers the screen the rounding hides behind the real
    /// display corners.
    static let displayCornerRadius: CGFloat = 55
}

/// All entrance timings in one place; the bloom totals ~0.5s.
private enum BloomTiming {
    /// Spring that grows the island capsule into the full screen.
    static let expandDuration: TimeInterval = 0.45
    static let expandBounce: Double = 0.15
    /// Content fades/scales in over the last ~40% of the expansion.
    static let revealDelay: TimeInterval = 0.26
    static let revealDuration: TimeInterval = 0.22
    /// Non-island fallback: fade + slide from the top.
    static let fallbackDuration: TimeInterval = 0.35
    /// Reduce Motion: straight cross-fade to content.
    static let reducedMotionFadeDuration: TimeInterval = 0.25
    /// One frame, so the collapsed state is committed before animating.
    static let firstFrameDelay: Duration = .milliseconds(32)
}

private enum EntranceStyle {
    case islandBloom
    case fadeSlide
    case reducedMotionFade
}

// MARK: - Container

/// Launch chrome: on Dynamic Island devices the UI "blooms" out of the
/// island. The content is clipped to a capsule matching the island's frame,
/// which springs open into the full screen while the content fades and
/// scales in over the tail of the expansion. Devices without an island get
/// a quick fade + slide from the top; Reduce Motion gets a plain fade.
///
/// The effect is render-only (clip shape + opacity + scale on a stable view
/// hierarchy), so no layout passes happen mid-flight and the wrapped
/// content keeps its identity and state across replays.
struct IslandBloomContainer<Content: View>: View {
    @ObservedObject var model: BloomEntranceModel
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 0 = clip is the island capsule, 1 = clip covers the whole screen.
    @State private var expansion: CGFloat = 0
    /// 0 = content invisible, 1 = fully revealed.
    @State private var reveal: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let style = entranceStyle(topInset: proxy.safeAreaInsets.top)
            let frames = BloomFrames(proxy: proxy)
            ZStack {
                clipShape(for: style, frames: frames)
                    .stroke(Color.white, lineWidth: 1)
                    .opacity(outlineOpacity(for: style))
                content
                    .opacity(Double(reveal))
                    .scaleEffect(contentScale(for: style))
                    .offset(y: contentOffset(for: style))
                    .clipShape(clipShape(for: style, frames: frames))
            }
            .task(id: model.generation) {
                await playEntrance(style: style)
            }
        }
        .background(ClipTheme.background.ignoresSafeArea())
    }

    // MARK: - Entrance

    private func playEntrance(style: EntranceStyle) async {
        expansion = 0
        reveal = 0
        try? await Task.sleep(for: BloomTiming.firstFrameDelay)
        guard !Task.isCancelled else { return }

        switch style {
        case .islandBloom:
            withAnimation(
                .spring(duration: BloomTiming.expandDuration, bounce: BloomTiming.expandBounce)
            ) {
                expansion = 1
            }
            withAnimation(
                .easeOut(duration: BloomTiming.revealDuration).delay(BloomTiming.revealDelay)
            ) {
                reveal = 1
            }
        case .fadeSlide:
            expansion = 1
            withAnimation(.easeOut(duration: BloomTiming.fallbackDuration)) {
                reveal = 1
            }
        case .reducedMotionFade:
            expansion = 1
            withAnimation(.easeOut(duration: BloomTiming.reducedMotionFadeDuration)) {
                reveal = 1
            }
        }
    }

    private func entranceStyle(topInset: CGFloat) -> EntranceStyle {
        if reduceMotion { return .reducedMotionFade }
        return topInset >= IslandMetrics.minimumTopInset ? .islandBloom : .fadeSlide
    }

    // MARK: - Derived effect values

    private func clipShape(for style: EntranceStyle, frames: BloomFrames) -> BloomClipShape {
        switch style {
        case .islandBloom:
            return BloomClipShape(
                progress: expansion,
                startFrame: frames.island,
                endFrame: frames.full,
                startCornerRadius: IslandMetrics.capsuleCornerRadius,
                endCornerRadius: IslandMetrics.displayCornerRadius
            )
        case .fadeSlide, .reducedMotionFade:
            // Oversized constant clip: never visible, but keeps the view
            // hierarchy identical across styles (e.g. after rotation).
            return BloomClipShape(
                progress: 1,
                startFrame: frames.oversized,
                endFrame: frames.oversized,
                startCornerRadius: 0,
                endCornerRadius: 0
            )
        }
    }

    /// Faint capsule outline so the expansion reads against the pure black
    /// canvas; gone once the content has fully bloomed in.
    private func outlineOpacity(for style: EntranceStyle) -> Double {
        guard style == .islandBloom else { return 0 }
        return 0.25 * Double(1 - reveal)
    }

    private func contentScale(for style: EntranceStyle) -> CGFloat {
        guard style == .islandBloom else { return 1 }
        return 0.92 + 0.08 * reveal
    }

    private func contentOffset(for style: EntranceStyle) -> CGFloat {
        guard style == .fadeSlide else { return 0 }
        return -24 * (1 - reveal)
    }
}

// MARK: - Geometry

/// Frames in the container's local coordinate space, whose origin is the
/// safe area's top-leading corner — the full screen therefore extends into
/// negative y, which the clip path is allowed to cover.
private struct BloomFrames {
    let island: CGRect
    let full: CGRect
    let oversized: CGRect

    init(proxy: GeometryProxy) {
        let insets = proxy.safeAreaInsets
        full = CGRect(
            x: -insets.leading,
            y: -insets.top,
            width: proxy.size.width + insets.leading + insets.trailing,
            height: proxy.size.height + insets.top + insets.bottom
        )
        let islandSize = IslandMetrics.size
        let topMargin = max(
            IslandMetrics.verticalMargin,
            insets.top - islandSize.height - IslandMetrics.verticalMargin
        )
        island = CGRect(
            x: full.midX - islandSize.width / 2,
            y: full.minY + topMargin,
            width: islandSize.width,
            height: islandSize.height
        )
        oversized = full.insetBy(dx: -200, dy: -200)
    }
}

/// Single animatable rounded rectangle interpolating from the island
/// capsule to the full screen; spring overshoot extrapolates past the
/// screen, which simply leaves nothing clipped.
private struct BloomClipShape: Shape {
    var progress: CGFloat
    let startFrame: CGRect
    let endFrame: CGRect
    let startCornerRadius: CGFloat
    let endCornerRadius: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in _: CGRect) -> Path {
        let frame = CGRect(
            x: lerp(startFrame.minX, endFrame.minX),
            y: lerp(startFrame.minY, endFrame.minY),
            width: lerp(startFrame.width, endFrame.width),
            height: lerp(startFrame.height, endFrame.height)
        )
        let radius = max(0, lerp(startCornerRadius, endCornerRadius))
        return Path(roundedRect: frame, cornerRadius: radius, style: .continuous)
    }

    private func lerp(_ from: CGFloat, _ to: CGFloat) -> CGFloat {
        from + (to - from) * progress
    }
}
