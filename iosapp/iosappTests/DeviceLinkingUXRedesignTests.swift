import SwiftUI
import Testing
@testable import iosapp

// Locks the redesigned cross-device pairing copy and visual-state contracts so
// future edits do not regress the clearer two-step UX.
struct DeviceLinkingUXRedesignTests {
    // Ensures step badges always render a consistent "STEP x of y" label.
    @Test func stepIndicatorBuildsExpectedBadgeText() {
        #expect(PairingStepIndicator.badgeText(step: 1) == "STEP 1")
        #expect(PairingStepIndicator.badgeText(step: 1, of: 2) == "STEP 1 of 2")
        #expect(PairingStepIndicator.badgeText(step: 2, of: 2) == "STEP 2 of 2")
    }

    // Ensures QR card border state is explicit so Step 2 can be visually
    // distinct from Step 1.
    @Test func qrCodeDisplayTracksWhetherBorderIsEnabled() {
        let withoutBorder = QRCodeDisplayView(data: "{}", title: "No Border")
        #expect(!withoutBorder.hasBorder)

        let withBorder = QRCodeDisplayView(data: "{}", title: "Border", borderColor: .green)
        #expect(withBorder.hasBorder)
    }

    // Ensures new-device Step 1 copy emphasizes waiting for the other device
    // before advancing, reducing accidental early taps.
    @Test func onboardingConnectToExistingCopyMatchesRedesign() {
        #expect(OnboardingView.connectToExistingStepOneInstruction == "On your other device, go to Settings → Link a New Device and scan this code")
        #expect(OnboardingView.connectToExistingStepOneContinueLabel == "Next")
        #expect(OnboardingView.connectToExistingStepOneWaitingLabel == "Waiting for your other device to scan...")
        #expect(OnboardingView.connectToExistingStepTwoHint == "Your other device should now be showing a green-bordered QR code")
    }

    // Ensures old-device copy clearly separates the grant-access success state
    // from the follow-up config-sharing step.
    @Test func existingDeviceLinkingCopyMatchesRedesign() {
        #expect(DeviceLinkingView.scanPublicKeyHeading == "Scan the new device's QR code")
        #expect(DeviceLinkingView.shareConfigSuccessLabel == "Access granted!")
        #expect(DeviceLinkingView.shareConfigHeading == "Now let the new device scan this")
        #expect(DeviceLinkingView.shareConfigBody == "On the new device, tap Next and point its camera at this code")
        #expect(DeviceLinkingView.shareConfigSubtitle == "Server Configuration")
    }
}
