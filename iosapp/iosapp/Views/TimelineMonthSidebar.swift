import SwiftUI

// Carries precomputed sidebar rows so month highlight updates avoid
// repeating grouping, sorting, and date-format work in SwiftUI body.
struct TimelineMonthSidebarSection: Identifiable, Equatable {
    // Represents one precomputed month row with stable selection key.
    struct Entry: Identifiable, Equatable {
        let yearMonth: TimelineYearMonth
        let label: String

        var year: Int { yearMonth.year }
        var month: Int { yearMonth.month }
        var id: String { "\(yearMonth.year)-\(yearMonth.month)" }
    }

    let year: Int
    let entries: [Entry]

    var id: Int { year }

    // Formats month labels once so repeated sidebar updates only toggle row highlight state.
    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter
    }()

    // Builds deterministic sections used by both runtime rendering and tests.
    static func sections(from monthIndex: [TimelineMonthEntry]) -> [TimelineMonthSidebarSection] {
        let groups = Dictionary(grouping: monthIndex, by: \.year)
        return groups.keys.sorted().map { year in
            let rows = (groups[year] ?? [])
                .sorted { $0.month < $1.month }
                .map { monthEntry in
                    Entry(
                        yearMonth: monthEntry.yearMonth,
                        label: monthLabel(for: monthEntry.month)
                    )
                }
            return TimelineMonthSidebarSection(year: year, entries: rows)
        }
    }

    // Converts one numeric month to localized short text used in the sidebar rows.
    private static func monthLabel(for month: Int) -> String {
        var components = DateComponents()
        components.year = 2000
        components.month = month
        components.day = 1
        guard let date = Calendar.current.date(from: components) else {
            return String(format: "%02d", month)
        }
        return monthFormatter.string(from: date)
    }
}

// Isolates one month row so month changes only re-render rows whose highlight state changed.
struct TimelineMonthRow: View, Equatable {
    let id: String
    let label: String
    let isHighlighted: Bool
    let onTap: () -> Void

    // Restricts equality to row identity plus highlight state so closure identity never forces redraws.
    static func == (lhs: TimelineMonthRow, rhs: TimelineMonthRow) -> Bool {
        lhs.id == rhs.id
            && lhs.label == rhs.label
            && lhs.isHighlighted == rhs.isHighlighted
    }

    // Renders one tappable month with highlight-only background drawing to reduce offscreen render cost.
    var body: some View {
        Button {
            onTap()
        } label: {
            Text(label)
                .font(.caption.weight(isHighlighted ? .bold : .regular))
                .foregroundStyle(isHighlighted ? Color.accentColor : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    isHighlighted ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
        }
        .buttonStyle(.plain)
    }
}

// Renders a compact month navigator so users can quickly jump across large timeline ranges.
struct TimelineMonthSidebar: View {
    let timelineManager: TimelineManager
    @ObservedObject private var selection: TimelineMonthSelectionModel
    @State private var lastAutoScrolledMonthID: String?

    // Binds sidebar observation to the narrow month-selection model so paging publishes do not re-render this view.
    init(timelineManager: TimelineManager) {
        self.timelineManager = timelineManager
        _selection = ObservedObject(wrappedValue: timelineManager.monthSelection)
    }

    // Extends month navigation beneath system bars while keeping labels readable and tappable.
    // The material background reaches behind nav and tab bars via ignoresSafeAreaEdges, while
    // scroll content stays within safe area so months remain accessible without manual insets.
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(selection.sections) { group in
                        Text(String(group.year))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)

                        ForEach(group.entries) { entry in
                            TimelineMonthRow(
                                id: entry.id,
                                label: entry.label,
                                isHighlighted: isHighlighted(entry.yearMonth),
                                onTap: {
                                    timelineManager.scrollToMonth(year: entry.year, month: entry.month)
                                }
                            )
                            .equatable()
                            .id(entry.id)
                            }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
            .frame(width: 64)
            .background(Color(.systemBackground), ignoresSafeAreaEdges: [.top, .bottom])
            .accessibilityIdentifier("timelineMonthSidebar")
            .onAppear {
                scrollToHighlightedMonth(using: proxy, animated: false)
            }
            .onChange(of: selection.currentYearMonth) { _, _ in
                guard !selection.isGridScrolling else { return }
                scrollToHighlightedMonth(using: proxy, animated: true)
            }
            .onChange(of: selection.isGridScrolling) { _, isScrolling in
                guard !isScrolling else { return }
                scrollToHighlightedMonth(using: proxy, animated: true)
            }
        }
    }

    // Matches one month against the viewport month to drive active-state highlighting.
    private func isHighlighted(_ yearMonth: TimelineYearMonth) -> Bool {
        guard let currentYearMonth = selection.currentYearMonth else { return false }
        return currentYearMonth == yearMonth
    }

    // Keeps the active month visible inside the sidebar when timeline scrolling changes selection.
    private func scrollToHighlightedMonth(using proxy: ScrollViewProxy, animated: Bool) {
        guard let currentYearMonth = selection.currentYearMonth else { return }
        let id = "\(currentYearMonth.year)-\(currentYearMonth.month)"
        guard lastAutoScrolledMonthID != id else { return }
        lastAutoScrolledMonthID = id
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}
