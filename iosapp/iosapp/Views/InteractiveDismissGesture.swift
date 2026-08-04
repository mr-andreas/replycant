import UIKit

/// Centralizes dismiss gesture thresholds so the full-screen container and
/// any future presenters share one tuning profile for swipe-down dismissal.
struct InteractiveDismissDecision {
    static let axisVelocityRatio: CGFloat = 1.3
    static let commitTranslation: CGFloat = 150
    static let commitVelocity: CGFloat = 800
    static let maxScaleReduction: CGFloat = 0.25
    static let maxBackgroundFade: Double = 0.5
    static let minScrollOffset: CGFloat = -120

    // Approves the recognizer only for downward vertical intent to avoid stealing horizontal paging.
    static func shouldBegin(velocity: CGPoint, scale: CGFloat, scrollOffset: CGFloat) -> Bool {
        guard abs(scale - 1.0) < 0.001 else { return false }
        guard scrollOffset >= minScrollOffset else { return false }
        guard velocity.y > 0 else { return false }
        return abs(velocity.y) > abs(velocity.x) * axisVelocityRatio
    }

    // Converts translation into normalized interactive progress for scale/fade effects.
    static func progress(translationY: CGFloat) -> CGFloat {
        max(0, min(translationY / commitTranslation, 1))
    }

    // Decides whether release should complete dismiss using translation or flick velocity.
    static func shouldDismiss(translationY: CGFloat, velocityY: CGFloat) -> Bool {
        guard velocityY >= 0 else { return false }
        return translationY > commitTranslation || velocityY > commitVelocity
    }
}
