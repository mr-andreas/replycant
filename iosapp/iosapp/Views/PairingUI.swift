import SwiftUI

// Shared visual primitives for the device-pairing flow (onboarding +
// device linking). Centralizes brand colors and repeated button/status
// chrome so both sides of the pairing UX render identically.

// MARK: - Brand Colors

extension Color {
    static let brandPurple = Color(red: 0.43, green: 0.04, blue: 0.82)
    static let brandMagenta = Color(red: 0.86, green: 0.24, blue: 0.96)
    static let brandPlum = Color(red: 0.16, green: 0.04, blue: 0.34)
    static let brandGreen = Color(red: 0.10, green: 0.67, blue: 0.53)

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [.brandPurple, .brandMagenta],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    static var successGradient: LinearGradient {
        LinearGradient(
            colors: [.brandGreen, .mint],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - Button Styles

/// Full-width gradient call-to-action matching the Replycant brand
/// identity used throughout onboarding and device linking.
struct PairingPrimaryButtonStyle: ButtonStyle {
    var disabled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding()
            .background(disabled ? AnyShapeStyle(Color.gray) : AnyShapeStyle(Color.brandGradient))
            .foregroundColor(.white)
            .cornerRadius(12)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

/// Full-width secondary button for less-prominent actions (go back,
/// cancel) that pairs visually with `PairingPrimaryButtonStyle`.
struct PairingSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.brandPlum)
            .foregroundColor(.white)
            .cornerRadius(12)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

/// Subtle tertiary button (gray background) for destructive-cancel
/// or "go back to start" paths.
struct PairingTertiaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.gray.opacity(0.2))
            .foregroundColor(.primary)
            .cornerRadius(12)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

// MARK: - Field Chrome

// Keeps pairing and recovery inputs visible against the plain step
// background so password, label, and URL fields share one capsule style.
extension View {
    // Applies the filled rounded field chrome used throughout wizard steps.
    // The padding parameter exists because the recovery bundle editor uses
    // a tighter inset than single-line fields.
    func pairingFieldBackground(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(Color.gray.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Shared Status Views

// Defines the two visual phases so both devices keep the same step language
// and color cues during key exchange vs. configuration exchange.
enum PairingPhase {
    case sendKey
    case shareConfig

    // Provides a consistent fill style so all phase-aware elements reinforce
    // the same color cue throughout the flow.
    var fill: AnyShapeStyle {
        switch self {
        case .sendKey:
            return AnyShapeStyle(Color.brandGradient)
        case .shareConfig:
            return AnyShapeStyle(Color.successGradient)
        }
    }

    // Provides a matching tint for icons, borders, and hint text in each step.
    var tint: Color {
        switch self {
        case .sendKey:
            return .brandPurple
        case .shareConfig:
            return .brandGreen
        }
    }
}

// Displays a compact phase-colored step badge so users can instantly align the
// current phone and action with the other device.
struct PairingStepIndicator: View {
    let step: Int
    let totalSteps: Int?
    let phase: PairingPhase

    // Preserves the explicit-total initializer used by fixed multi-step flows.
    init(step: Int, of totalSteps: Int, phase: PairingPhase) {
        self.step = step
        self.totalSteps = totalSteps
        self.phase = phase
    }

    // Supports flows where total steps are unknown until after user input.
    init(step: Int, phase: PairingPhase) {
        self.step = step
        self.totalSteps = nil
        self.phase = phase
    }

    // Centralizes badge copy so tests can protect against accidental wording
    // changes that make the cross-device sequence harder to follow.
    static func badgeText(step: Int, of totalSteps: Int? = nil) -> String {
        guard let totalSteps else {
            return "STEP \(step)"
        }
        return "STEP \(step) of \(totalSteps)"
    }

    var body: some View {
        Text(Self.badgeText(step: step, of: totalSteps))
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(phase.fill)
            .clipShape(Capsule())
    }
}

// Shows short context hints near scanner surfaces so users know what to look
// for on the other phone before they attempt scanning.
struct PairingHintBox: View {
    let message: String
    let phase: PairingPhase

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lightbulb")
                .foregroundStyle(phase.tint)
            Text(message)
                .font(.body)
                .foregroundStyle(phase.tint)
                .multilineTextAlignment(.leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(phase.tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Displays in-progress spinner or completion checkmark with a message
/// and optional determinate progress bar. Used by both onboarding and
/// device-linking flows to show async operation status.
struct PairingProgressView: View {
    let isProcessing: Bool
    let message: String
    var progress: Double = 0

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if isProcessing {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(1.5)
                    .padding()
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.green)
            }

            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if isProcessing {
                VStack(spacing: 4) {
                    ProgressView(value: progress, total: 100)
                        .progressViewStyle(LinearProgressViewStyle())
                        .padding(.horizontal, 40)

                    if progress > 0 {
                        Text("\(Int(progress))% complete")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()
        }
    }
}

/// Displays a failure state with a warning icon, title, error detail,
/// and retry/back actions. Callbacks allow each parent flow to handle
/// navigation differently while sharing the visual layout.
struct PairingErrorView: View {
    let title: String
    let message: String?
    let retryLabel: String
    let cancelLabel: String
    let onRetry: () -> Void
    let onCancel: () -> Void

    init(
        title: String = "Setup Failed",
        message: String?,
        retryLabel: String = "Try Again",
        cancelLabel: String = "Go Back",
        onRetry: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.retryLabel = retryLabel
        self.cancelLabel = cancelLabel
        self.onRetry = onRetry
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            Text(title)
                .font(.title2)
                .fontWeight(.semibold)

            if let message {
                Text(message)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Spacer()

            VStack(spacing: 16) {
                Button(action: onRetry) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text(retryLabel)
                    }
                }
                .buttonStyle(PairingPrimaryButtonStyle())

                Button(action: onCancel) {
                    Text(cancelLabel)
                }
                .buttonStyle(PairingTertiaryButtonStyle())
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
    }
}

// MARK: - Previews

#Preview("Progress - Processing") {
    PairingProgressView(isProcessing: true, message: "Cloning repository...", progress: 42)
}

#Preview("Progress - Complete") {
    PairingProgressView(isProcessing: false, message: "Setup complete!")
}

#Preview("Error") {
    PairingErrorView(
        message: "Server URL not configured",
        onRetry: {},
        onCancel: {}
    )
}
