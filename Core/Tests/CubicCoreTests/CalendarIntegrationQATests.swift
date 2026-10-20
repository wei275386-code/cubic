import Foundation
import Testing
@testable import CubicCore

@Suite struct CalendarIntegrationQATests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Int) -> Date { now.addingTimeInterval(Double(minutes) * 60) }
    private func workspace() -> Workspace {
        Workspace(items: [WorkItem(id: "work", name: "Work", remainingMinutes: 60)],
                  timeBlocks: [WorkTimeBlock(id: "reservation", itemID: "work", start: at(30), end: at(60))])
    }
    private var slots: [CapacitySlot] { [CapacitySlot(start: now, end: at(180))] }

    @Test func reservationsLosingDomainReadinessReturnIssuesWithoutChangingDomainFacts() throws {
        let valid = workspace()
        #expect(try valid.calendarTimeBlockIssues(slots: slots, now: now).isEmpty)
        var completed = valid; try completed.completeItem(id: "work", now: now)
        var archived = valid; archived.items[0].isArchived = true
        var blocked = valid
        blocked.blockers = [Blocker(id: "wait", name: "Wait", state: .active, triggeredAt: now)]
        blocked.dependencies = [Dependency(id: "dependency", source: .blocker("wait"), targetItemID: "work")]
        var review = valid; review.items[0].needsReview = true
        var reduced = valid; reduced.items[0].remainingMinutes = 15
        var unknown = valid; unknown.items[0].remainingMinutes = nil
        for input in [completed, archived, blocked, review, reduced, unknown] {
            let original = try SyncCoding.encode(input)
            let issues = try input.calendarTimeBlockIssues(slots: slots, now: now)
            #expect(issues["reservation"] != nil)
            #expect(try SyncCoding.encode(input) == original)
            #expect(input.timeBlocks == valid.timeBlocks)
        }
    }

    @Test func workScheduleAndExternalBusyChangesInvalidateReservationWithoutRemovingIt() throws {
        let input = workspace(), bytes = try SyncCoding.encode(input)
        #expect(try input.calendarTimeBlockIssues(slots: [], now: now)["reservation"] != nil)
        let occupied = BusyInterval(start: at(40), end: at(50))
        #expect(try input.calendarTimeBlockIssues(slots: slots, busy: [occupied], now: now)["reservation"] != nil)
        #expect(try SyncCoding.encode(input) == bytes)
        #expect(input.timeBlocks?.count == 1)
    }

    @Test func startedReservationUsesOnlyFutureFragmentAndExpiredReservationsDoNotCreateIssues() throws {
        var input = workspace()
        input.items[0].remainingMinutes = 30
        input.timeBlocks = [WorkTimeBlock(id: "started", itemID: "work", start: at(-30), end: at(30)),
                            WorkTimeBlock(id: "expired", itemID: "missing-old-item", start: at(-90), end: at(-60))]
        #expect(try input.calendarTimeBlockIssues(slots: slots, now: now).isEmpty)
        input.items[0].requiresContinuous = true; input.items[0].continuousMinutes = 60
        let issues = try input.calendarTimeBlockIssues(slots: slots, now: now)
        #expect(issues["started"] != nil)
        #expect(issues["expired"] == nil)
    }

    @Test func movingAndResizingExcludeOwnOldCalendarEventWhileOtherMappedEventsStillOccupyTime() throws {
        let ownOldEvent = BusyInterval(start: at(30), end: at(60))
        for (start, end) in [(30, 90), (45, 75)] {
            var input = workspace()
            input.timeBlocks?[0].start = at(start); input.timeBlocks?[0].end = at(end)
            let bytes = try SyncCoding.encode(input)
            #expect(try input.calendarTimeBlockIssues(slots: slots, mappedBusy: ["reservation": [ownOldEvent]], now: now).isEmpty)
            #expect(try SyncCoding.encode(input) == bytes)
            // A second block moved elsewhere in Cubic, but its old Calendar event still occupies this interval.
            input.items.append(WorkItem(id: "other-work", name: "Other", remainingMinutes: 30))
            input.timeBlocks?.append(WorkTimeBlock(id: "other-block", itemID: "other-work", start: at(120), end: at(150)))
            let mappedBusy = ["reservation": [ownOldEvent], "other-block": [BusyInterval(start: at(50), end: at(60))]]
            let issues = try input.calendarTimeBlockIssues(slots: slots, mappedBusy: mappedBusy, now: now)
            #expect(issues["reservation"] != nil)
            #expect(issues["other-block"] == nil)
            // Unmapped/external events are never excluded merely because their time equals the old own event.
            #expect(try input.calendarTimeBlockIssues(slots: slots, busy: [ownOldEvent], mappedBusy: ["reservation": [ownOldEvent]], now: now)["reservation"] != nil)
        }
    }
}
