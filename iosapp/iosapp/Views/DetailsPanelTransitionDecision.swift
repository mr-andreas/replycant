import UIKit

/// Decides whether a drag should commit to opening or closing the details
/// panel so short intentional nudges feel responsive without accidental toggles.
struct DetailsPanelTransitionDecision {
    static let showTranslationThreshold: CGFloat = 50
    static let hideTranslationThreshold: CGFloat = 50
    static let velocityThreshold: CGFloat = 400
    static let axisVelocityRatio: CGFloat = 1.2

    static func shouldShow(translationY: CGFloat, velocityY: CGFloat) -> Bool {
        if velocityY <= -velocityThreshold {
            return true
        }
        return translationY <= -showTranslationThreshold
    }

    static func shouldHide(translationY: CGFloat, velocityY: CGFloat) -> Bool {
        if velocityY >= velocityThreshold {
            return true
        }
        return translationY >= hideTranslationThreshold
    }
}
