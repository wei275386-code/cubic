import SwiftUI
import CubicCore

/// 今天 answers "what now": the one next action, what needs attention, and today's timeline.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    private var cal: Calendar { model.workCalendar }
    private var day: Date { cal.startOfDay(for: model.now) }
    private var itemIDs: Set<String> {
        Set(model.workspace.items.filter { !$0.archived && $0.effectiveDisposition != .cancelled }.map(\.id))
    }
    private var allocations: [TrialAllocation] {
        let ids = itemIDs
        return model.planning?.witness.allocations.filter { ids.contains($0.itemID) && cal.isDate($0.start, inSameDayAs: day) } ?? []
    }

    var body: some View {
        content
            .cubicNavigationTitle("今天")
            #if os(iOS)
            .navigationSubtitle(CalendarFormat.dayTitle(day, calendar: cal))
            #endif
            .refreshable { await model.refresh(background: false); await model.refreshCalendarBridge() }
            .task { model.ensureCalendarBridge() }
    }

    private var timeline: some View {
        CalendarTimelineView(day: day, calendar: cal, slots: model.capacitySlots(on: day), events: model.busyEvents(on: day),
                             itemIDs: itemIDs, allocations: allocations, markers: model.waitMarkers(on: day))
    }

    #if os(iOS)
    private var content: some View {
        List {
            Section {
                NextActionCard()
                AttentionStrip()
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            Section {
                timeline
            } header: { DayHeader(day: day, calendar: cal, itemIDs: itemIDs, title: "今日时间线") }
            AvailableWorkSection(limit: 5)
        }
        .listSectionSpacing(.compact)
    }
    #else
    private var content: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    NextActionCard(compact: true)
                    AttentionDigest()
                    AvailableWorkCompactList().glassCard()
                }.padding(16)
            }.frame(width: 380)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    DayHeader(day: day, calendar: cal, itemIDs: itemIDs, title: "今日时间线")
                    timeline
                }.padding(16)
            }
        }
    }
    #endif
}
