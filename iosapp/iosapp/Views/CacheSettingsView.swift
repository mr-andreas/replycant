import SwiftUI

// Displays and allows editing of cache settings for both
// in-memory preloading and the two-tier disk LRU cache.
struct CacheSettingsView: View {
    private let previewStats: ImageDiskCacheManager.CacheStats?
    private let previewRefreshes: [TopCacheRefresh]?
    @ObservedObject private var refreshLog = TopCacheRefreshLog.shared
    @State private var imagesBeforeViewport: Int
    @State private var imagesAfterViewport: Int
    @State private var maxCacheSizeMB: Int
    @State private var localThumbnailsEnabled: Bool
    @State private var fullScreenPreloadRadius: Int
    @State private var mainDiskLimitMB: Int
    @State private var topDiskLimitMB: Int
    @State private var mainWarmCount: Int
    @State private var topWarmCount: Int
    @State private var diskStats: ImageDiskCacheManager.CacheStats?
    @State private var isClearing = false

    // Seeds optional disk-cache numbers and refresh rows so gallery
    // tiles can show the stats and the list without reading this phone.
    init(
        previewStats: ImageDiskCacheManager.CacheStats? = nil,
        previewRefreshes: [TopCacheRefresh]? = nil
    ) {
        self.previewStats = previewStats
        self.previewRefreshes = previewRefreshes
        let manager = CacheSettingsManager.shared
        _imagesBeforeViewport = State(initialValue: manager.imagesBeforeViewport)
        _imagesAfterViewport = State(initialValue: manager.imagesAfterViewport)
        _maxCacheSizeMB = State(initialValue: manager.maxTimelineThumbnailRAMCacheSizeMB)
        _localThumbnailsEnabled = State(initialValue: manager.localThumbnailsEnabled)
        _fullScreenPreloadRadius = State(initialValue: manager.fullScreenPreloadRadius)
        _mainDiskLimitMB = State(initialValue: manager.mainDiskCacheLimitMB)
        _topDiskLimitMB = State(initialValue: manager.topDiskCacheLimitMB)
        _mainWarmCount = State(initialValue: manager.mainCacheWarmItemCount)
        _topWarmCount = State(initialValue: manager.topCacheWarmItemCount)
        _diskStats = State(initialValue: previewStats)
    }

    // Canvas and gallery tiles skip disk I/O so the preview stays a
    // parked snapshot instead of probing empty simulator caches.
    static func shouldLoadDiskStats(
        previewStats: ImageDiskCacheManager.CacheStats?,
        isRunningForPreviews: Bool
    ) -> Bool {
        previewStats == nil && !isRunningForPreviews
    }

    // A gallery tile passes fixed rows. Otherwise the page follows the
    // log, including a warm that finishes while Settings is open.
    private var refreshes: [TopCacheRefresh] {
        previewRefreshes ?? refreshLog.refreshes
    }

    var body: some View {
        VStack(spacing: 20) {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "photo.stack")
                        .imageScale(.large)
                        .foregroundStyle(.tint)
                        .font(.system(size: 60))

                    Text("Cache Settings")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Configure in-memory preloading and disk-based LRU caches for thumbnails and originals.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Divider()
                        .padding(.vertical)

                    VStack(spacing: 30) {
                        // MARK: - Disk Cache: Main
                        diskCacheSection(
                            title: "Main Cache",
                            description: "Caches thumbnails and full-size images during browsing.",
                            limitMB: $mainDiskLimitMB,
                            limitRange: 100...4096,
                            limitStep: 100,
                            warmCount: $mainWarmCount,
                            warmRange: 0...5000,
                            warmStep: 100,
                            sizeBytes: diskStats?.mainSizeBytes,
                            itemCount: diskStats?.mainItemCount,
                            onLimitChange: { newValue in
                                MainActor.assumeIsolated {
                                    CacheSettingsManager.shared.mainDiskCacheLimitMB = newValue
                                }
                            },
                            onWarmChange: { newValue in
                                MainActor.assumeIsolated {
                                    CacheSettingsManager.shared.mainCacheWarmItemCount = newValue
                                }
                            },
                            onClear: {
                                Task {
                                    isClearing = true
                                    await ImageDiskCacheManager.shared.clearMain()
                                    diskStats = await ImageDiskCacheManager.shared.stats()
                                    isClearing = false
                                }
                            }
                        )

                        // MARK: - Disk Cache: Top
                        diskCacheSection(
                            title: "Top Cache",
                            description: "Keeps the most recent thumbnails so the first screen renders instantly.",
                            limitMB: $topDiskLimitMB,
                            limitRange: 10...1024,
                            limitStep: 10,
                            warmCount: $topWarmCount,
                            warmRange: 0...2000,
                            warmStep: 50,
                            sizeBytes: diskStats?.topSizeBytes,
                            itemCount: diskStats?.topItemCount,
                            onLimitChange: { newValue in
                                MainActor.assumeIsolated {
                                    CacheSettingsManager.shared.topDiskCacheLimitMB = newValue
                                }
                            },
                            onWarmChange: { newValue in
                                MainActor.assumeIsolated {
                                    CacheSettingsManager.shared.topCacheWarmItemCount = newValue
                                }
                            },
                            onClear: {
                                Task {
                                    isClearing = true
                                    await ImageDiskCacheManager.shared.clearTop()
                                    diskStats = await ImageDiskCacheManager.shared.stats()
                                    isClearing = false
                                }
                            },
                            showsRefreshes: true
                        )

                        Divider()

                        // MARK: - RAM / Preload settings (existing)

                        VStack(spacing: 15) {
                            Text("Thumbnail Source")
                                .font(.headline)

                            Toggle("Load thumbnails from Photo Library", isOn: $localThumbnailsEnabled)
                                .onChange(of: localThumbnailsEnabled) { _, newValue in
                                    MainActor.assumeIsolated {
                                        CacheSettingsManager.shared.localThumbnailsEnabled = newValue
                                    }
                                }

                            Text("When enabled, timeline thumbnails use local photo library assets first before falling back to the LFS server.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(10)

                        settingCard(title: "Images Before Viewport") {
                            Stepper(value: $imagesBeforeViewport, in: 0...100, step: 1) {
                                HStack {
                                    Text("\(imagesBeforeViewport)")
                                        .font(.title2).fontWeight(.semibold).frame(minWidth: 50)
                                    Text("images").foregroundColor(.secondary)
                                }
                            }
                            .onChange(of: imagesBeforeViewport) { _, newValue in
                                MainActor.assumeIsolated {
                                    CacheSettingsManager.shared.imagesBeforeViewport = newValue
                                }
                            }
                            Text("Preloads images above the visible area")
                                .font(.caption).foregroundColor(.secondary)
                        }

                        settingCard(title: "Images After Viewport") {
                            Stepper(value: $imagesAfterViewport, in: 0...100, step: 1) {
                                HStack {
                                    Text("\(imagesAfterViewport)")
                                        .font(.title2).fontWeight(.semibold).frame(minWidth: 50)
                                    Text("images").foregroundColor(.secondary)
                                }
                            }
                            .onChange(of: imagesAfterViewport) { _, newValue in
                                MainActor.assumeIsolated {
                                    CacheSettingsManager.shared.imagesAfterViewport = newValue
                                }
                            }
                            Text("Preloads images below the visible area")
                                .font(.caption).foregroundColor(.secondary)
                        }

                        settingCard(title: "Max RAM Cache Size") {
                            Stepper(value: $maxCacheSizeMB, in: 10...1000, step: 10) {
                                HStack {
                                    Text("\(maxCacheSizeMB)")
                                        .font(.title2).fontWeight(.semibold).frame(minWidth: 50)
                                    Text("MB").foregroundColor(.secondary)
                                }
                            }
                            .onChange(of: maxCacheSizeMB) { _, newValue in
                                MainActor.assumeIsolated {
                                    CacheSettingsManager.shared.maxTimelineThumbnailRAMCacheSizeMB = newValue
                                }
                            }
                            Text("Maximum RAM used for cached thumbnails")
                                .font(.caption).foregroundColor(.secondary)
                        }

                        settingCard(title: "Fullscreen Preload") {
                            Stepper(value: $fullScreenPreloadRadius, in: 0...20, step: 1) {
                                HStack {
                                    Text("\(fullScreenPreloadRadius)")
                                        .font(.title2).fontWeight(.semibold).frame(minWidth: 50)
                                    Text("each direction").foregroundColor(.secondary)
                                }
                            }
                            .onChange(of: fullScreenPreloadRadius) { _, newValue in
                                MainActor.assumeIsolated {
                                    CacheSettingsManager.shared.fullScreenPreloadRadius = newValue
                                }
                            }
                            Text("Preloads full-resolution neighbor images when viewing fullscreen. Set to 0 to disable.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
        }
        .navigationTitle("Cache")
        .task {
            guard Self.shouldLoadDiskStats(
                previewStats: previewStats,
                isRunningForPreviews: ContentView.isRunningForPreviews(
                    environment: ProcessInfo.processInfo.environment
                )
            ) else { return }
            // Counts come from the size index. This waits for the same
            // walk the timeline starts after the first photos, so the
            // page is not stuck at zero while that walk is running.
            await ImageDiskCacheManager.shared.ensureIndex()
            diskStats = await ImageDiskCacheManager.shared.stats()
        }
    }

    // MARK: - Reusable components

    // The warm history lives in the Top Cache card. A separate card
    // looked like a third cache, so the rows stay with the controls
    // they describe.
    private var refreshRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Refreshes")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)

            if refreshes.isEmpty {
                Text("No refreshes yet")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(refreshes) { refresh in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(TopCacheRefreshCopy.timeRange(refresh))
                        Text(TopCacheRefreshCopy.detail(refresh))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Builds one disk-cache settings card with size, limit, warm count,
    /// and clear. The top card also lists its refresh history so those
    /// times are not mistaken for a separate cache.
    @ViewBuilder
    private func diskCacheSection(
        title: String,
        description: String,
        limitMB: Binding<Int>,
        limitRange: ClosedRange<Int>,
        limitStep: Int,
        warmCount: Binding<Int>,
        warmRange: ClosedRange<Int>,
        warmStep: Int,
        sizeBytes: Int?,
        itemCount: Int?,
        onLimitChange: @escaping (Int) -> Void,
        onWarmChange: @escaping (Int) -> Void,
        onClear: @escaping () -> Void,
        showsRefreshes: Bool = false
    ) -> some View {
        VStack(spacing: 15) {
            Text(title)
                .font(.headline)

            if let sizeBytes, let itemCount {
                HStack {
                    Label(formattedSize(sizeBytes), systemImage: "internaldrive")
                    Spacer()
                    Label("\(itemCount) items", systemImage: "photo")
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
            }

            Stepper(value: limitMB, in: limitRange, step: limitStep) {
                HStack {
                    Text("\(limitMB.wrappedValue)")
                        .font(.title2).fontWeight(.semibold).frame(minWidth: 50)
                    Text("MB limit").foregroundColor(.secondary)
                }
            }
            .onChange(of: limitMB.wrappedValue) { _, newValue in
                onLimitChange(newValue)
            }

            Stepper(value: warmCount, in: warmRange, step: warmStep) {
                HStack {
                    Text("\(warmCount.wrappedValue)")
                        .font(.title2).fontWeight(.semibold).frame(minWidth: 50)
                    Text("warm items").foregroundColor(.secondary)
                }
            }
            .onChange(of: warmCount.wrappedValue) { _, newValue in
                onWarmChange(newValue)
            }

            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)

            Button(role: .destructive) {
                onClear()
            } label: {
                HStack {
                    if isClearing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Clear")
                }
            }
            .buttonStyle(.bordered)

            // The history belongs on this card. A divider keeps the rows
            // from reading as another stepper.
            if showsRefreshes {
                Divider()
                refreshRows
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }

    @ViewBuilder
    private func settingCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 15) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }

    private func formattedSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// Holds a parked cache snapshot so preview tiles can fill the stats
// rows without probing empty simulator directories.
extension ImageDiskCacheManager.CacheStats {
    // Supplies representative disk-cache numbers so gallery tiles
    // show stats rows without reading the on-device cache.
    static let sample = ImageDiskCacheManager.CacheStats(
        mainSizeBytes: 256_000_000,
        mainItemCount: 840,
        topSizeBytes: 18_000_000,
        topItemCount: 120
    )
}
