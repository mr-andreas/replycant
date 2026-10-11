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

    // The new device has nothing to tap once its QR is shown: approval
    // arrives on its own, so the copy has to say it is waiting.
    @Test func onboardingConnectToExistingCopyMatchesRedesign() {
        #expect(OnboardingView.connectToExistingStepOneInstruction == "On your other device, go to Settings → Link a New Device and scan this code")
        #expect(OnboardingView.connectToExistingStepOneWaitingLabel == "Waiting for your other device to scan...")
        #expect(OnboardingView.connectToExistingRecoveryShortcutLabel == "I have a recovery key")
        #expect(OnboardingView.connectToExistingPasteBackupLabel == "Paste backup text")
        #expect(OnboardingView.connectToExistingRecoveryScanHint == "Scan your saved recovery QR, or paste backup text.")
    }

    @Test func existingDeviceLinkingCopyMatchesRedesign() {
        #expect(DeviceLinkingView.scanPublicKeyHeading == "Scan the new device's QR code")
    }
}
