#if DEBUG
import SwiftUI

// Groups gallery tiles so section previews stay cheap when the full
// board is too large for Canvas to instantiate at once.
enum GallerySection: String, CaseIterable, Identifiable {
    case onboarding
    case linking
    case recoveryKeys
    case createRecoveryKey
    case recovery
    case appShell
    case timeline
    case upload
    case settings
    case components

    var id: String { rawValue }

    // Supplies section titles so canvas previews and captions stay
    // aligned with the catalog grouping.
    var title: String {
        switch self {
        case .onboarding: return "Onboarding"
        case .linking: return "Link a new device"
        case .recoveryKeys: return "Recovery keys"
        case .createRecoveryKey: return "Create recovery key"
        case .recovery: return "Recover access"
        case .appShell: return "App shell"
        case .timeline: return "Timeline"
        case .upload: return "Upload"
        case .settings: return "Settings"
        case .components: return "Components"
        }
    }
}

// Holds a named screen tile without building its view until Canvas
// asks, so coverage tests can inspect the board without SwiftUI work.
struct GalleryScreen: Identifiable {
    let id: String
    let section: GallerySection
    let makeView: () -> AnyView
}

// Catalog of every previewable iOS screen so UI review can happen
// against the whole app at once instead of one file's previews.
enum AppScreenGallery {
    private static let sampleDevicePublicKeyQR =
        "{\"pubkey\":\"ssh-ed25519 AAAA...\",\"age_pubkey\":\"age1...\",\"name\":\"preview-iphone\",\"uuid\":\"abc123\"}"
    private static let sampleConfigJSON =
        "{\"url\":\"https://git.example.com\",\"ca\":\"-----BEGIN CERTIFICATE-----\\nMIIB...\\n-----END CERTIFICATE-----\"}"

    static let all: [GalleryScreen] =
        onboarding + linking + recoveryKeys + createRecoveryKey
        + recovery + appShell + timeline + upload + settings + components

    // Filters the catalog so a section preview only instantiates that
    // group's screens.
    static func screens(in section: GallerySection) -> [GalleryScreen] {
        all.filter { $0.section == section }
    }

    // Hosts the same board in the running app so Canvas-blank tiles
    // can be inspected without a preview time limit.
    static func shouldShowGallery(arguments: [String]) -> Bool {
        arguments.contains("--gallery")
    }

    // Tallest fixedLayout that still painted in Canvas. Boards at
    // 3000pt rendered as a blank frame with no timeout banner.
    static let workingCanvasHeight: CGFloat = 2200

    static let tileWidth: CGFloat = 402
    static let tileHeight: CGFloat = 874
    static let tileCaptionHeight: CGFloat = 20
    static let gridSpacing: CGFloat = 24
    static let boardPadding: CGFloat = 32

    // Sizes a section board to at most two rows so Canvas stays
    // under the height that silently blanks.
    static func canvasLayout(tileCount: Int) -> CanvasLayout {
        let count = max(tileCount, 1)
        let columns = count <= 4 ? count : Int(ceil(Double(count) / 2.0))
        let rows = Int(ceil(Double(count) / Double(columns)))
        let width = boardPadding * 2
            + CGFloat(columns) * tileWidth
            + CGFloat(max(columns - 1, 0)) * gridSpacing
        let rowHeight = tileCaptionHeight + tileHeight
        let height = boardPadding * 2
            + CGFloat(rows) * rowHeight
            + CGFloat(max(rows - 1, 0)) * gridSpacing
        return CanvasLayout(
            columns: columns,
            rows: rows,
            width: width,
            height: height
        )
    }

    // Wraps a preview view so the catalog can store it without
    // specializing the array element type.
    private static func tile<Content: View>(
        _ id: String,
        section: GallerySection,
        @ViewBuilder content: @escaping () -> Content
    ) -> GalleryScreen {
        GalleryScreen(id: id, section: section, makeView: { AnyView(content()) })
    }

    // Adds a navigation stack for screens that expect toolbar chrome
    // from their production parents.
    private static func stacked<Content: View>(
        _ id: String,
        section: GallerySection,
        @ViewBuilder content: @escaping () -> Content
    ) -> GalleryScreen {
        tile(id, section: section) {
            NavigationStack { content() }
        }
    }

    private static let onboarding: [GalleryScreen] = [
        tile("Onboarding / intro", section: .onboarding) {
            OnboardingView(onComplete: {})
        },
        tile("Onboarding / welcome", section: .onboarding) {
            OnboardingView(preview: .welcome)
        },
        tile("Onboarding / serverSetupGuide", section: .onboarding) {
            OnboardingView(preview: .serverSetupGuide)
        },
        tile("Onboarding / scanQR", section: .onboarding) {
            OnboardingView(preview: .scanQR)
        },
        tile("Onboarding / showPublicKey", section: .onboarding) {
            OnboardingView(
                preview: .showPublicKey,
                devicePublicKeyQR: sampleDevicePublicKeyQR,
                deviceName: "preview-iphone"
            )
        },
        tile("Onboarding / scanConfig", section: .onboarding) {
            OnboardingView(preview: .scanConfig)
        },
        tile("Onboarding / processing", section: .onboarding) {
            OnboardingView(
                preview: .processing,
                isProcessing: true,
                progressMessage: "Cloning repository...",
                progress: 42
            )
        },
        tile("Onboarding / error", section: .onboarding) {
            OnboardingView(
                preview: .error,
                errorMessage: "Server URL not configured"
            )
        }
    ]

    private static let linking: [GalleryScreen] = [
        stacked("Link a new device / scanPublicKey", section: .linking) {
            DeviceLinkingView(preview: .scanPublicKey)
        },
        stacked("Link a new device / processing", section: .linking) {
            DeviceLinkingView(
                preview: .processing,
                isProcessing: true,
                progressMessage: "Adding device key..."
            )
        },
        stacked("Link a new device / showConfig", section: .linking) {
            DeviceLinkingView(
                preview: .showConfig,
                scannedDeviceName: "preview-iphone",
                configJSON: sampleConfigJSON
            )
        },
        stacked("Link a new device / error", section: .linking) {
            DeviceLinkingView(
                preview: .error,
                errorMessage: "mTLS credentials not configured. Please complete initial setup first."
            )
        }
    ]

    private static let recoveryKeys: [GalleryScreen] = [
        stacked("Recovery keys / status", section: .recoveryKeys) {
            RecoveryKeyView(preview: .status)
        }
    ]

    private static let createRecoveryKey: [GalleryScreen] = [
        stacked("Create recovery key / name", section: .createRecoveryKey) {
            RecoveryKeyView(preview: .name)
        },
        stacked("Create recovery key / password", section: .createRecoveryKey) {
            RecoveryKeyView(preview: .password)
        },
        stacked("Create recovery key / processing", section: .createRecoveryKey) {
            RecoveryKeyView(preview: .processing)
        },
        stacked("Create recovery key / created", section: .createRecoveryKey) {
            RecoveryKeyView(preview: .created)
        },
        stacked("Create recovery key / created after share", section: .createRecoveryKey) {
            RecoveryKeyView(preview: .created, hasShared: true)
        },
        stacked("Create recovery key / error", section: .createRecoveryKey) {
            RecoveryKeyView(preview: .error)
        }
    ]

    private static let recovery: [GalleryScreen] = [
        stacked("Recover access / bundle", section: .recovery) {
            RecoveryView(
                initialInput: nil,
                onCompleted: {},
                onCancel: {},
                previewStep: .bundle
            )
        },
        stacked("Recover access / password", section: .recovery) {
            RecoveryView(
                initialInput: "replycant://recover?v=1&d=abc",
                onCompleted: {},
                onCancel: {},
                previewStep: .password
            )
        },
        stacked("Recover access / processing", section: .recovery) {
            RecoveryView(
                initialInput: nil,
                onCompleted: {},
                onCancel: {},
                previewStep: .processing
            )
        },
        stacked("Recover access / serverUnreachable", section: .recovery) {
            RecoveryView(
                initialInput: nil,
                onCompleted: {},
                onCancel: {},
                previewStep: .serverUnreachable
            )
        },
        stacked("Recover access / blocked", section: .recovery) {
            RecoveryView(
                initialInput: nil,
                onCompleted: {},
                onCancel: {},
                previewStep: .blocked
            )
        },
        stacked("Recover access / keyRejected", section: .recovery) {
            RecoveryView(
                initialInput: nil,
                onCompleted: {},
                onCancel: {},
                previewStep: .keyRejected
            )
        },
        stacked("Recover access / done", section: .recovery) {
            RecoveryView(
                initialInput: nil,
                onCompleted: {},
                onCancel: {},
                previewStep: .done
            )
        },
        stacked("Recover access / error", section: .recovery) {
            RecoveryView(
                initialInput: nil,
                onCompleted: {},
                onCancel: {},
                previewStep: .error
            )
        }
    ]

    private static let appShell: [GalleryScreen] = [
        tile("App shell / tabs", section: .appShell) {
            ContentView(
                previewState: .init(
                    errorMessage: nil,
                    isRepoInitialized: true,
                    selectedTab: 0,
                    isResyncing: false,
                    resyncProgress: 0,
                    resyncProgressMessage: "Preparing resync..."
                )
            )
        },
        tile("App shell / resync", section: .appShell) {
            ContentView(
                previewState: .init(
                    errorMessage: nil,
                    isRepoInitialized: false,
                    selectedTab: 0,
                    isResyncing: true,
                    resyncProgress: 63,
                    resyncProgressMessage: "Building media index... (1260/2000)"
                )
            )
        }
    ]

    private static let timeline: [GalleryScreen] = [
        tile("Timeline / empty", section: .timeline) {
            TimelineView(previewState: .empty)
        },
        tile("Timeline / loading", section: .timeline) {
            TimelineView(previewState: .loading)
        },
        tile("Timeline / error", section: .timeline) {
            TimelineView(previewState: .error("LFS URL not configured"))
        }
    ]

    private static let upload: [GalleryScreen] = [
        tile("Upload / idle", section: .upload) {
            GalleryPhotoSyncPreview(state: .idle, isSyncing: false)
        },
        tile("Upload / syncing", section: .upload) {
            GalleryPhotoSyncPreview(
                state: .syncing(
                    current: 7,
                    total: 24,
                    currentFile: "IMG_2048.HEIC",
                    uploadSpeed: "6.2 MB/s",
                    fileSize: "12.4 MB"
                ),
                isSyncing: true
            )
        },
        tile("Upload / completed", section: .upload) {
            GalleryPhotoSyncPreview(
                state: .completed(total: 24),
                isSyncing: false
            )
        },
        tile("Upload / failed", section: .upload) {
            GalleryPhotoSyncPreview(
                state: .failed(
                    NSError(
                        domain: "Preview",
                        code: -1,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Network timeout"
                        ]
                    )
                ),
                isSyncing: false
            )
        }
    ]

    private static let settings: [GalleryScreen] = [
        tile("Settings / list", section: .settings) {
            SettingsView(onWipeAndResync: {}, showRecoveryWarning: false)
        },
        tile("Settings / recovery warning", section: .settings) {
            SettingsView(onWipeAndResync: {}, showRecoveryWarning: true)
        },
        stacked("Settings / repository", section: .settings) {
            RepositorySettingsView(previewState: .sample)
        },
        stacked("Settings / sync", section: .settings) {
            SyncSettingsView()
        },
        stacked("Settings / playback", section: .settings) {
            PlaybackSettingsView()
        },
        stacked("Settings / cache", section: .settings) {
            CacheSettingsView(previewStats: .sample)
        }
    ]

    private static let components: [GalleryScreen] = [
        stacked("Components / scanner scanning", section: .components) {
            QRCodeScannerView(previewState: .scanning)
        },
        stacked("Components / scanner permission", section: .components) {
            QRCodeScannerView(previewState: .permissionDenied)
        },
        stacked("Components / scanner error", section: .components) {
            QRCodeScannerView(previewState: .scanError("Invalid QR code format"))
        },
        tile("Components / progress complete", section: .components) {
            PairingProgressView(
                isProcessing: false,
                message: "Setup complete!"
            )
        }
    ]
}

// Seeds PhotoSyncView with a parked manager so the gallery can show
// idle, in-flight, and finished upload states without Photos access.
private struct GalleryPhotoSyncPreview: View {
    let state: SyncState
    let isSyncing: Bool

    var body: some View {
        let manager = PhotoSyncManager()
        manager.syncState = state
        manager.isSyncing = isSyncing
        return PhotoSyncView(syncManager: manager)
    }
}

// Records the column count and canvas size for one gallery board so
// section previews can stay under the height Canvas will paint.
struct CanvasLayout: Equatable {
    let columns: Int
    let rows: Int
    let width: CGFloat
    let height: CGFloat
}

// Lays out labeled phone-sized tiles eagerly so Canvas cannot skip
// them the way LazyVGrid does when the preview viewport is empty.
struct AppScreenGalleryBoard: View {
    let screens: [GalleryScreen]
    var columns: Int = 10

    var body: some View {
        Grid(alignment: .top, horizontalSpacing: 24, verticalSpacing: 24) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow(alignment: .top) {
                    ForEach(row) { screen in
                        VStack(spacing: 6) {
                            Text(screen.id)
                                .font(.caption2)
                                .lineLimit(1)
                            screen.makeView()
                                .frame(width: 402, height: 874)
                                .clipShape(RoundedRectangle(cornerRadius: 24))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 24)
                                        .stroke(.quaternary)
                                )
                        }
                    }
                }
            }
        }
        .padding(32)
    }

    private var rows: [[GalleryScreen]] {
        stride(from: 0, to: screens.count, by: max(columns, 1)).map {
            Array(screens[$0 ..< min($0 + max(columns, 1), screens.count)])
        }
    }
}

#Preview("Onboarding", traits: .fixedLayout(width: 1744, height: 1876)) {
    AppScreenGalleryBoard(
        screens: AppScreenGallery.screens(in: .onboarding),
        columns: 4
    )
}

#Preview("Link a new device", traits: .fixedLayout(width: 1744, height: 958)) {
    AppScreenGalleryBoard(
        screens: AppScreenGallery.screens(in: .linking),
        columns: 4
    )
}

#Preview("Recovery keys", traits: .fixedLayout(width: 466, height: 958)) {
    AppScreenGalleryBoard(
        screens: AppScreenGallery.screens(in: .recoveryKeys),
        columns: 1
    )
}

#Preview("Create recovery key", traits: .fixedLayout(width: 1318, height: 1876)) {
    AppScreenGalleryBoard(
        screens: AppScreenGallery.screens(in: .createRecoveryKey),
        columns: 3
    )
}

#Preview("Recover access", traits: .fixedLayout(width: 1744, height: 1876)) {
    AppScreenGalleryBoard(
        screens: AppScreenGallery.screens(in: .recovery),
        columns: 4
    )
}

#Preview("App shell", traits: .fixedLayout(width: 892, height: 958)) {
    AppScreenGalleryBoard(
        screens: AppScreenGallery.screens(in: .appShell),
        columns: 2
    )
}

#Preview("Timeline", traits: .fixedLayout(width: 1318, height: 958)) {
    AppScreenGalleryBoard(
        screens: AppScreenGallery.screens(in: .timeline),
        columns: 3
    )
}

#Preview("Upload", traits: .fixedLayout(width: 1744, height: 958)) {
    AppScreenGalleryBoard(
        screens: AppScreenGallery.screens(in: .upload),
        columns: 4
    )
}

#Preview("Settings", traits: .fixedLayout(width: 1318, height: 1876)) {
    AppScreenGalleryBoard(
        screens: AppScreenGallery.screens(in: .settings),
        columns: 3
    )
}

#Preview("Components", traits: .fixedLayout(width: 1744, height: 958)) {
    AppScreenGalleryBoard(
        screens: AppScreenGallery.screens(in: .components),
        columns: 4
    )
}
#endif
