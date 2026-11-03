import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import CubicCore

private struct CalendarDrag {
    let itemID: String
    let blockID: String?
    let minutes: Int
    var anchorMinutes: Double = 0
}

private struct CalendarDropPreview: Equatable {
    let block: WorkTimeBlock
}

/// A point-in-time reminder drawn on the timeline, such as a waiting follow-up.
struct CalendarMarker: Identifiable, Equatable {
    let id: String
    let date: Date
    let title: String
}

extension AppModel {
    /// A placed work leaves the rail, including partial arrangements. Removing
    /// its last current/future block makes it available again.
    func calendarCandidates(itemIDs: Set<String>) -> [WorkItem] {
        let now = Date()
        let scheduled = Set((workspace.timeBlocks ?? []).filter { $0.end > now }.map(\.itemID))
        return workspace.items.filter {
            itemIDs.contains($0.id) && !$0.archived && $0.effectiveDisposition == .active &&
            $0.status != .completed && !scheduled.contains($0.id) && ($0.remainingMinutes ?? 0) > 0
        }.sorted { lhs, rhs in
            let first = health(ofItem: lhs).urgency, second = health(ofItem: rhs).urgency
            return first == second ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : first < second
        }
    }

    func calendarCandidateDurations(_ candidates: [WorkItem], allocations: [TrialAllocation]) -> [String: Int] {
        var suggested: [String: Int] = [:]
        for allocation in allocations where suggested[allocation.itemID] == nil {
            suggested[allocation.itemID] = Int(allocation.end.timeIntervalSince(allocation.start) / 60)
        }
        return Dictionary(uniqueKeysWithValues: candidates.map { item in
            let remaining = max(1, item.remainingMinutes ?? 30)
            return (item.id, item.requiresContinuous ? remaining : max(1, min(max(15, suggested[item.id] ?? 30), remaining)))
        })
    }
}

/// Unscheduled work as draggable cards. Horizontal above the iPhone timeline,
/// vertical beside the Mac week grid.
struct CalendarCandidateRail: View {
    let itemIDs: Set<String>
    let allocations: [TrialAllocation]
    let calendar: Calendar
    let defaultStart: Date
    var axis: Axis = .horizontal
    @Environment(AppModel.self) private var model
    @State private var editing: WorkTimeBlock?
    var body: some View {
        let candidates = model.calendarCandidates(itemIDs: itemIDs)
        let durations = model.calendarCandidateDurations(candidates, allocations: allocations)
        Group {
            if axis == .horizontal {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(candidates, id: \.id) { card($0, minutes: durations[$0.id] ?? 30).frame(width: 172) }
                    }.padding(.vertical, 2)
                }.scrollIndicators(.hidden)
            } else {
                VStack(spacing: 8) {
                    ForEach(candidates, id: \.id) { card($0, minutes: durations[$0.id] ?? 30).frame(maxWidth: .infinity) }
                }
            }
        }.sheet(item: $editing) { CalendarTimeBlockEditor(block: $0, calendar: calendar) }
    }
    private func card(_ item: WorkItem, minutes: Int) -> some View {
        // The card is hosted outside SwiftUI's environment, so it receives plain values.
        let health = model.health(ofItem: item)
        let context = model.workspace.projects.first { model.relatedProjectIDs(for: item).contains($0.id) }?.name ?? "独立工作"
        return NativeCalendarDragCard(drag: CalendarDrag(itemID: item.id, blockID: nil, minutes: minutes), onTap: {
            let start = max(defaultStart, Date().addingTimeInterval(300))
            editing = WorkTimeBlock(itemID: item.id, start: start, end: start.addingTimeInterval(Double(minutes) * 60))
        }) {
            CandidateCardContent(name: item.name, context: context, minutes: minutes, tint: health.tint)
        }.frame(height: 62)
            .accessibilityElement(children: .combine).accessibilityLabel("\(item.name)，\(minutes) 分钟，\(context)")
            .accessibilityAddTraits(.isButton).accessibilityIdentifier("calendar.drag.item.\(item.id)")
    }
}

private struct CandidateCardContent: View {
    let name: String
    let context: String
    let minutes: Int
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(context).lineLimit(1)
                Spacer(minLength: 4)
                Text(shortMinutesLabel(minutes)).monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct CalendarTimelineView: View {
    let day: Date
    let calendar: Calendar
    let slots: [CapacitySlot]
    let events: [BusyEvent]
    let itemIDs: Set<String>
    let allocations: [TrialAllocation]
    var markers: [CalendarMarker] = []
    var showsRail = true
    var showsHourLabels = true
    var hourRange: ClosedRange<Int>? = nil
    var hourHeight: Double = 60
    @Environment(AppModel.self) private var model
    @State private var editing: WorkTimeBlock?
    @State private var placing = false
    @State private var preview: CalendarDropPreview?
    #if os(iOS)
    @State private var selectionFeedback = UISelectionFeedbackGenerator()
    #endif
    private var gutter: Double { showsHourLabels ? 52 : 4 }
    private var dayStart: Date { calendar.startOfDay(for: day) }
    private var dayEnd: Date { calendar.date(byAdding: .day, value: 1, to: dayStart)! }
    private var blocks: [WorkTimeBlock] {
        (model.workspace.timeBlocks ?? []).filter { block in
            guard let item = model.item(block.itemID) else { return false }
            return itemIDs.contains(block.itemID) && !item.archived && item.effectiveDisposition != .cancelled && block.start < dayEnd && block.end > dayStart
        }
    }
    private var rangeStart: Date {
        if let hourRange { return min(dayEnd, calendar.date(byAdding: .hour, value: hourRange.lowerBound, to: dayStart) ?? dayStart) }
        let earliest = (slots.map(\.start) + blocks.map(\.start)).min() ?? calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day)!
        return max(dayStart, (calendar.dateInterval(of: .hour, for: earliest)?.start ?? earliest).addingTimeInterval(-3600))
    }
    private var rangeEnd: Date {
        if let hourRange { return min(dayEnd, calendar.date(byAdding: .hour, value: hourRange.upperBound, to: dayStart) ?? dayEnd) }
        let latest = (slots.map(\.end) + blocks.map(\.end)).max() ?? calendar.date(bySettingHour: 20, minute: 0, second: 0, of: day)!
        let endOfHour = calendar.dateInterval(of: .hour, for: latest)?.end ?? latest
        return min(dayEnd, max(endOfHour, rangeStart.addingTimeInterval(6 * 3600)))
    }
    private var hasCandidates: Bool { !model.calendarCandidates(itemIDs: itemIDs).isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsRail {
                if hasCandidates {
                    Text(dragInstructions).font(.caption).foregroundStyle(.secondary)
                    CalendarCandidateRail(itemIDs: itemIDs, allocations: allocations, calendar: calendar, defaultStart: slots.first?.start ?? rangeStart)
                } else {
                    Text(blocks.isEmpty ? "没有待安排工作" : placedInstructions)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geometry in
                let start = rangeStart, end = rangeEnd, seconds = max(1, end.timeIntervalSince(start))
                let height = geometry.size.height, width = max(1, geometry.size.width - gutter)
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.secondary.opacity(0.03)).allowsHitTesting(false)
                    ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                        interval(start: slot.start, end: slot.end, rangeStart: start, seconds: seconds, height: height, width: width, color: Color.cubicAccent.opacity(0.08)).allowsHitTesting(false)
                    }
                    ForEach(events) { event in
                        eventView(event, rangeStart: start, seconds: seconds, height: height, width: width).allowsHitTesting(false)
                    }
                    NativeCalendarDropSurface(timelineHeight: height, onHover: { drag, point in
                        updatePreview(drag, point: point, start: start, end: end, height: height)
                    }, onDrop: { drag, point in
                        place(drag, point: point, start: start, end: end, height: height)
                    }).frame(width: geometry.size.width, height: height)
                    ForEach(0...Int(seconds / 3600), id: \.self) { hour in
                        let y = Double(hour) * 3600 / seconds * height
                        let date = start.addingTimeInterval(Double(hour) * 3600)
                        // The label's centre, rule and event top share the same y.
                        if showsHourLabels {
                            Text(time(date)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 46, height: 16, alignment: .leading)
                                .position(x: 23, y: y)
                                .accessibilityIdentifier("calendar.hour.\(hour)")
                                .allowsHitTesting(false)
                        }
                        Rectangle().fill(Color.secondary.opacity(0.18)).frame(width: width, height: 0.5)
                            .offset(x: gutter, y: y).allowsHitTesting(false)
                    }
                    ForEach(blocks) { block in
                        let lower = max(block.start, start), upper = min(block.end, end)
                        if lower < upper {
                            let origin = lower.timeIntervalSince(start) / seconds * height
                            NativeCalendarDragCard(drag: CalendarDrag(itemID: block.itemID, blockID: block.id, minutes: max(1, Int(block.end.timeIntervalSince(block.start) / 60)), anchorMinutes: lower.timeIntervalSince(block.start) / 60), anchorScale: seconds / 60 / height, timelineOffset: origin, timelineHeight: height, onTap: { editing = block }, onHover: { drag, point in
                                updatePreview(drag, point: CGPoint(x: point.x + gutter, y: origin + point.y), start: start, end: end, height: height)
                            }, onDrop: { drag, point in
                                place(drag, point: CGPoint(x: point.x + gutter, y: origin + point.y), start: start, end: end, height: height)
                            }) {
                                blockContent(block, visibleMinutes: upper.timeIntervalSince(lower) / 60)
                            }.frame(width: max(1, width - 4), height: max(1, upper.timeIntervalSince(lower) / seconds * height - 1))
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(model.item(block.itemID)?.name ?? "工作")，\(time(block.start))–\(time(block.end))，\(CalendarIntegrationCopy.blockStatus(block, model: model))")
                                .accessibilityAddTraits(.isButton).accessibilityIdentifier("calendar.block.\(block.id)")
                                .offset(x: gutter + 2, y: origin)
                        }
                    }
                    ForEach(markers) { marker in
                        if marker.date >= start && marker.date <= end {
                            markerView(marker, width: width)
                                .offset(x: gutter + 4, y: max(0, marker.date.timeIntervalSince(start) / seconds * height - 10))
                                .allowsHitTesting(false)
                        }
                    }
                    let now = Date()
                    if now >= start && now <= end {
                        let y = now.timeIntervalSince(start) / seconds * height
                        Rectangle().fill(Color.red).frame(width: width, height: 1.5)
                            .offset(x: gutter, y: y - 0.75).allowsHitTesting(false)
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                            .offset(x: gutter - 4, y: y - 4).allowsHitTesting(false).accessibilityHidden(true)
                    }
                    if let preview {
                        let block = preview.block
                        let lower = max(block.start, start), upper = min(block.end, end)
                        if lower < upper {
                            blockContent(block, visibleMinutes: upper.timeIntervalSince(lower) / 60)
                                .overlay { RoundedRectangle(cornerRadius: CubicMetrics.blockRadius).stroke(Color.cubicAccent, lineWidth: 2) }
                                .frame(width: max(1, width - 4), height: max(1, upper.timeIntervalSince(lower) / seconds * height - 1))
                                .offset(x: gutter + 2, y: lower.timeIntervalSince(start) / seconds * height)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                }.accessibilityElement(children: .contain).accessibilityIdentifier("calendar.timeline")
            }.frame(height: max(showsRail ? 360 : 120, rangeEnd.timeIntervalSince(rangeStart) / 3600 * hourHeight))
                .padding(.vertical, 8)
            if placing { Label("正在保存时间块…", systemImage: "clock").font(.caption) }
        }.sheet(item: $editing) { CalendarTimeBlockEditor(block: $0, calendar: calendar) }
            .onChange(of: day) { _, _ in preview = nil }
    }
    private func proposedBlock(_ drag: CalendarDrag, point: CGPoint, start: Date, end: Date, height: Double) -> WorkTimeBlock? {
        guard !placing, !model.saving, itemIDs.contains(drag.itemID), model.item(drag.itemID) != nil,
              (1...5256000).contains(drag.minutes), drag.anchorMinutes.isFinite,
              point.x >= gutter, point.y >= 0, point.y <= height else { return nil }
        let minutes = ((point.y / height * end.timeIntervalSince(start) / 60 - drag.anchorMinutes) / 15).rounded() * 15
        let date = start.addingTimeInterval(minutes * 60)
        return WorkTimeBlock(id: drag.blockID ?? "calendar.drop.preview", itemID: drag.itemID, start: date, end: date.addingTimeInterval(Double(drag.minutes) * 60))
    }
    private func updatePreview(_ drag: CalendarDrag?, point: CGPoint, start: Date, end: Date, height: Double) {
        let next = drag.flatMap { proposedBlock($0, point: point, start: start, end: end, height: height) }.map { CalendarDropPreview(block: $0) }
        if next != preview {
            #if os(iOS)
            if next != nil { selectionFeedback.selectionChanged() }
            #endif
            preview = next
        }
    }
    private func place(_ drag: CalendarDrag, point: CGPoint, start: Date, end: Date, height: Double) {
        preview = nil
        guard var block = proposedBlock(drag, point: point, start: start, end: end, height: height) else { return }
        if drag.blockID == nil { block.id = UUID().uuidString }
        placing = true
        Task {
            let saved = await model.saveTimeBlock(block)
            placing = false
            #if os(iOS)
            if saved { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            #else
            _ = saved
            #endif
        }
    }
    private func blockContent(_ block: WorkTimeBlock, visibleMinutes: Double) -> some View {
        let past = block.end <= Date()
        let name = model.item(block.itemID)?.name ?? "工作"
        let range = "\(time(block.start))–\(time(block.end))"
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if past { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                if visibleMinutes < 30 {
                    // One line in a narrow column: keep the whole time beside the name, otherwise drop it rather than cut both.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 4) {
                            Text(name).font(.system(size: 10, weight: .semibold)).lineLimit(1).fixedSize()
                            Spacer(minLength: 0)
                            Text(range).font(.system(size: 9)).monospacedDigit().lineLimit(1).fixedSize()
                        }
                        Text(name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text(name).font(.caption.weight(.semibold))
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if visibleMinutes >= 30 {
                Text(range).font(.system(size: 10)).monospacedDigit().lineLimit(1)
            }
            if visibleMinutes >= 60 {
                Text(CalendarIntegrationCopy.blockStatus(block, model: model)).font(.caption2).lineLimit(1)
            }
        }.foregroundStyle(past ? Color.secondary : Color.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 8).padding(.trailing, 4).padding(.top, 2)
            .background(Color.cubicAccent.opacity(past ? 0.1 : 0.2), in: RoundedRectangle(cornerRadius: CubicMetrics.blockRadius))
            .overlay(alignment: .leading) { Capsule().fill(Color.cubicAccent.opacity(past ? 0.5 : 1)).frame(width: 3).padding(.vertical, 3).padding(.leading, 2) }
            .clipShape(RoundedRectangle(cornerRadius: CubicMetrics.blockRadius))
            .help("\(name) \(range)")
    }
    private func eventView(_ event: BusyEvent, rangeStart: Date, seconds: Double, height: Double, width: Double) -> some View {
        let lower = max(event.start, rangeStart), upper = min(event.end, rangeStart.addingTimeInterval(seconds))
        let eventHeight = max(0, upper.timeIntervalSince(lower) / seconds * height - 1)
        return Text(event.allDay ? "\(event.title) · 全天" : event.title)
            .font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, 6).padding(.top, 2)
            .frame(width: max(1, width - 4), height: eventHeight, alignment: .topLeading)
            .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: CubicMetrics.blockRadius))
            .overlay { RoundedRectangle(cornerRadius: CubicMetrics.blockRadius).strokeBorder(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 0.5, dash: [3, 2])) }
            .clipped()
            .opacity(eventHeight > 0 ? 1 : 0)
            .offset(x: gutter + 2, y: max(0, lower.timeIntervalSince(rangeStart) / seconds * height))
            .accessibilityLabel("日历占用：\(event.title)")
    }
    private func markerView(_ marker: CalendarMarker, width: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "flag.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(Color.cubicAmber, in: Circle())
            if width > 150 {
                Text(marker.title).font(.caption2.weight(.semibold)).foregroundStyle(Color.cubicAmber).lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.cubicAmber.opacity(0.14), in: Capsule())
            }
        }.frame(maxWidth: max(20, width - 8), alignment: .leading)
            .accessibilityLabel("跟进：\(marker.title)")
    }
    private func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
    }
    private var dragInstructions: String {
        #if os(macOS)
        "拖动安排时间，点击编辑。"
        #else
        "长按拖动安排时间，点按编辑。"
        #endif
    }
    private var placedInstructions: String {
        #if os(macOS)
        "工作已安排，拖动时间块可移动"
        #else
        "工作已安排，长按时间块可移动"
        #endif
    }
    private func interval(start: Date, end: Date, rangeStart: Date, seconds: Double, height: Double, width: Double, color: Color) -> some View {
        let lower = max(start, rangeStart), upper = min(end, rangeStart.addingTimeInterval(seconds))
        return Rectangle().fill(color).frame(width: width, height: max(0, upper.timeIntervalSince(lower) / seconds * height))
            .offset(x: gutter, y: max(0, lower.timeIntervalSince(rangeStart) / seconds * height))
    }
}


/// Both the rail and placed events use the system's lift, cancellation and
/// drag session. Local typed payloads prevent text from becoming calendar work.
#if os(iOS)
private struct NativeCalendarDragCard<Content: View>: UIViewRepresentable {
    let drag: CalendarDrag
    var anchorScale: Double = 0
    var timelineOffset: CGFloat = 0
    var timelineHeight: CGFloat = 0
    let onTap: () -> Void
    var onHover: ((CalendarDrag?, CGPoint) -> Void)? = nil
    var onDrop: ((CalendarDrag, CGPoint) -> Void)? = nil
    @ViewBuilder var content: () -> Content
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> UIView {
        let hosting = UIHostingController(rootView: content())
        context.coordinator.hosting = hosting
        // The container accepts the exact proposed event size. Hosting intrinsic
        // text height must never expand the event's visible time interval.
        let view = UIView()
        view.backgroundColor = .clear
        view.clipsToBounds = true
        hosting.view.backgroundColor = .clear
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hosting.view.frame = view.bounds
        view.addSubview(hosting.view)
        let interaction = UIDragInteraction(delegate: context.coordinator)
        interaction.isEnabled = true
        view.addInteraction(interaction)
        if onDrop != nil { view.addInteraction(UIDropInteraction(delegate: context.coordinator.drop)) }
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap)))
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.hosting?.rootView = content()
        context.coordinator.drop.onHover = onHover
        context.coordinator.drop.onDrop = onDrop
        context.coordinator.drop.timelineOffset = timelineOffset
        context.coordinator.drop.timelineHeight = timelineHeight
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.drop.end() }
    final class Coordinator: NSObject, UIDragInteractionDelegate {
        var parent: NativeCalendarDragCard
        var hosting: UIHostingController<Content>?
        let drop = CalendarDropCoordinator()
        init(parent: NativeCalendarDragCard) { self.parent = parent }
        @objc func tap() { parent.onTap() }
        func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
            var drag = parent.drag
            if let view = interaction.view, drag.blockID != nil {
                drag.anchorMinutes += max(0, session.location(in: view).y * parent.anchorScale)
                drag.anchorMinutes = min(Double(drag.minutes), drag.anchorMinutes)
            }
            let item = UIDragItem(itemProvider: NSItemProvider(object: drag.itemID as NSString))
            item.localObject = drag
            return [item]
        }
        func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: UIDragSession) -> UITargetedDragPreview? {
            guard let view = interaction.view else { return nil }
            let parameters = UIDragPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: 5)
            return UITargetedDragPreview(view: view, parameters: parameters)
        }
        func dragInteraction(_ interaction: UIDragInteraction, willAnimateLiftWith animator: any UIDragAnimating, session: UIDragSession) {
            animator.addAnimations { interaction.view?.alpha = 0.3 }
        }
        func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation) {
            interaction.view?.alpha = 1
        }
    }
}

private struct NativeCalendarDropSurface: UIViewRepresentable {
    let timelineHeight: CGFloat
    let onHover: (CalendarDrag?, CGPoint) -> Void
    let onDrop: (CalendarDrag, CGPoint) -> Void
    func makeCoordinator() -> CalendarDropCoordinator { CalendarDropCoordinator() }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.addInteraction(UIDropInteraction(delegate: context.coordinator))
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onHover = onHover
        context.coordinator.onDrop = onDrop
        context.coordinator.timelineHeight = timelineHeight
    }
    static func dismantleUIView(_ view: UIView, coordinator: CalendarDropCoordinator) { coordinator.end() }
}

private final class CalendarDropCoordinator: NSObject, UIDropInteractionDelegate {
    var onHover: ((CalendarDrag?, CGPoint) -> Void)?
    var onDrop: ((CalendarDrag, CGPoint) -> Void)?
    private weak var view: UIView?
    private weak var scrollView: UIScrollView?
    private var session: UIDropSession?
    private var timer: Timer?
    private static var scrollLocks: [ObjectIdentifier: (scroll: UIScrollView, enabled: Bool, count: Int)] = [:]
    var timelineOffset: CGFloat = 0
    var timelineHeight: CGFloat = 0
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.localDragSession != nil && session.items.count == 1 && session.items.first?.localObject is CalendarDrag
    }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        guard let view = interaction.view, let drag = session.items.first?.localObject as? CalendarDrag else { return UIDropProposal(operation: .forbidden) }
        self.view = view; self.session = session
        onHover?(drag, session.location(in: view))
        if timer == nil {
            var ancestor = view.superview
            while let current = ancestor {
                if let scroll = current as? UIScrollView, scroll.contentSize.height > scroll.bounds.height {
                    scrollView = scroll
                    let key = ObjectIdentifier(scroll)
                    if var lock = Self.scrollLocks[key] {
                        lock.count += 1
                        Self.scrollLocks[key] = lock
                    } else {
                        Self.scrollLocks[key] = (scroll, scroll.isScrollEnabled, 1)
                    }
                    // One scroll driver during the lift; UIKit's ancestor auto-
                    // scrolling otherwise competes with the calendar timer.
                    scroll.isScrollEnabled = false
                    break
                }
                ancestor = current.superview
            }
            let timer = Timer(timeInterval: 1.0 / 30, target: self, selector: #selector(scrollAtEdge), userInfo: nil, repeats: true)
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        return UIDropProposal(operation: .move)
    }
    @objc private func scrollAtEdge() {
        guard let scroll = scrollView, let view, let window = view.window, let session,
              let drag = session.items.first?.localObject as? CalendarDrag else { return }
        // Use the visible scroll viewport, excluding the floating tab bar.
        let visible = scroll.convert(scroll.bounds, to: window).intersection(window.bounds.inset(by: window.safeAreaInsets))
        let y = session.location(in: window).y
        let top = visible.minY + 56, bottom = visible.maxY - 88
        let delta = y < top ? -min(10, (top - y) / 5) : y > bottom ? min(10, (y - bottom) / 5) : 0
        guard delta != 0 else { return }
        let contentLower = -scroll.adjustedContentInset.top
        let contentUpper = max(contentLower, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let viewport = scroll.convert(visible, from: window)
        let timelineTop = view.convert(view.bounds, to: scroll).minY - timelineOffset
        let lower = contentLower
        let upper = max(lower, min(contentUpper, scroll.contentOffset.y + timelineTop + timelineHeight - (viewport.maxY - 88)))
        let next = min(upper, max(lower, scroll.contentOffset.y + delta))
        if next != scroll.contentOffset.y {
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: next), animated: false)
            onHover?(drag, session.location(in: view))
        }
    }
    func end() {
        timer?.invalidate(); timer = nil
        if let scroll = scrollView, var lock = Self.scrollLocks[ObjectIdentifier(scroll)] {
            lock.count -= 1
            if lock.count == 0 {
                scroll.isScrollEnabled = lock.enabled
                Self.scrollLocks.removeValue(forKey: ObjectIdentifier(scroll))
            } else {
                Self.scrollLocks[ObjectIdentifier(scroll)] = lock
            }
        }
        session = nil; scrollView = nil; view = nil
        onHover?(nil, .zero)
    }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) { end() }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) { end() }
    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let view = interaction.view, let drag = session.items.first?.localObject as? CalendarDrag else { end(); return }
        let point = session.location(in: view)
        end()
        onDrop?(drag, point)
    }
}
#endif

#if os(macOS)
private struct NativeCalendarDragCard<Content: View>: NSViewRepresentable {
    let drag: CalendarDrag
    var anchorScale: Double = 0
    var timelineOffset: CGFloat = 0
    var timelineHeight: CGFloat = 0
    let onTap: () -> Void
    var onHover: ((CalendarDrag?, CGPoint) -> Void)? = nil
    var onDrop: ((CalendarDrag, CGPoint) -> Void)? = nil
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> CalendarMacDragCardView {
        let view = CalendarMacDragCardView()
        let hosting = NSHostingView(rootView: content())
        // Event bounds come from the timeline's proposed duration, not the
        // hosted text's intrinsic height.
        hosting.sizingOptions = []
        hosting.frame = view.bounds
        hosting.autoresizingMask = [.width, .height]
        view.addSubview(hosting)
        context.coordinator.hosting = hosting
        configure(view)
        return view
    }
    func updateNSView(_ view: CalendarMacDragCardView, context: Context) {
        context.coordinator.hosting?.rootView = content()
        configure(view)
    }
    private func configure(_ view: CalendarMacDragCardView) {
        view.drag = drag
        view.anchorScale = anchorScale
        view.onTap = onTap
        view.drop.onHover = onHover
        view.drop.onDrop = onDrop
        view.drop.timelineOffset = timelineOffset
        view.drop.timelineHeight = timelineHeight
        view.acceptsCalendarDrops = onDrop != nil
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CalendarMacDragCardView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
    static func dismantleNSView(_ view: CalendarMacDragCardView, coordinator: Coordinator) { view.drop.end() }
    final class Coordinator {
        var hosting: NSHostingView<Content>?
    }
}

private struct NativeCalendarDropSurface: NSViewRepresentable {
    let timelineHeight: CGFloat
    let onHover: (CalendarDrag?, CGPoint) -> Void
    let onDrop: (CalendarDrag, CGPoint) -> Void
    func makeNSView(context: Context) -> CalendarMacDropView {
        let view = CalendarMacDropView()
        configure(view)
        return view
    }
    func updateNSView(_ view: CalendarMacDropView, context: Context) { configure(view) }
    private func configure(_ view: CalendarMacDropView) {
        view.acceptsCalendarDrops = true
        view.drop.onHover = onHover
        view.drop.onDrop = onDrop
        view.drop.timelineHeight = timelineHeight
    }
    static func dismantleNSView(_ view: CalendarMacDropView, coordinator: ()) { view.drop.end() }
}

/// The pasteboard advertises a private type, but the payload is taken only
/// from a live local drag source. External text and stale pasteboards cannot
/// schedule work, and no asynchronous provider loads run during hover.
private class CalendarMacDropView: NSView {
    static let pasteboardType = NSPasteboard.PasteboardType("app.cubic.calendar.time-block")
    let drop = CalendarMacDropCoordinator()
    var acceptsCalendarDrops = false {
        didSet {
            guard acceptsCalendarDrops != oldValue else { return }
            if acceptsCalendarDrops { registerForDraggedTypes([Self.pasteboardType]) }
            else { unregisterDraggedTypes() }
        }
    }
    override var isFlipped: Bool { true }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptsCalendarDrops, let drag = localDrag(sender) else { drop.end(); return [] }
        drop.update(drag, in: self, point: convert(sender.draggingLocation, from: nil))
        return .move
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { drop.end() }
    override func draggingEnded(_ sender: any NSDraggingInfo) { drop.end() }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        acceptsCalendarDrops && localDrag(sender) != nil
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard acceptsCalendarDrops, let drag = localDrag(sender), let onDrop = drop.onDrop else { drop.end(); return false }
        let point = convert(sender.draggingLocation, from: nil)
        drop.end()
        onDrop(drag, point)
        return true
    }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { drop.end() }
    private func localDrag(_ sender: any NSDraggingInfo) -> CalendarDrag? {
        guard sender.numberOfValidItemsForDrop == 1 || sender.draggingPasteboard.pasteboardItems?.count == 1,
              sender.draggingPasteboard.availableType(from: [Self.pasteboardType]) != nil,
              let source = sender.draggingSource as? CalendarMacDragCardView else { return nil }
        return source.activeDrag
    }
}

private final class CalendarMacDragCardView: CalendarMacDropView, NSDraggingSource {
    var drag: CalendarDrag?
    var anchorScale: Double = 0
    var onTap: (() -> Void)?
    private(set) var activeDrag: CalendarDrag?
    private var mouseDownEvent: NSEvent?
    private var mouseDownPoint = CGPoint.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    // Hosted text must not consume the card's mouse down. This preserves one
    // native click/drag gesture without an overlay blocking drop destinations.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }
    override func mouseDragged(with event: NSEvent) {
        guard mouseDownEvent != nil, var drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) >= 4 else { return }
        mouseDownEvent = nil
        if drag.blockID != nil {
            drag.anchorMinutes = min(Double(drag.minutes), drag.anchorMinutes + max(0, mouseDownPoint.y * anchorScale))
        }
        activeDrag = drag
        let item = NSPasteboardItem()
        item.setString(UUID().uuidString, forType: Self.pasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size)
        if let bitmap = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: bitmap)
            image.addRepresentation(bitmap)
        }
        draggingItem.setDraggingFrame(bounds, contents: image)
        // Start at the event that crossed the drag threshold. Reusing the
        // original mouse-down can leave a fast drag at its old location.
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    override func mouseUp(with event: NSEvent) {
        guard mouseDownEvent != nil else { return }
        mouseDownEvent = nil
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onTap?() }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { alphaValue = 0.35 }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        alphaValue = 1
        activeDrag = nil
        mouseDownEvent = nil
        drop.end()
    }
}

@MainActor
private final class CalendarMacDropCoordinator {
    var onHover: ((CalendarDrag?, CGPoint) -> Void)?
    var onDrop: ((CalendarDrag, CGPoint) -> Void)?
    var timelineOffset: CGFloat = 0
    var timelineHeight: CGFloat = 0
    private weak var view: NSView?
    private weak var scrollView: NSScrollView?
    private var drag: CalendarDrag?
    private var timer: Timer?

    func update(_ drag: CalendarDrag, in view: NSView, point: CGPoint) {
        self.view = view
        self.drag = drag
        onHover?(drag, point)
        guard timer == nil else { return }
        var ancestor: NSView? = view.superview
        while let current = ancestor {
            if let scroll = current as? NSScrollView, let document = scroll.documentView,
               document.bounds.height > scroll.contentView.bounds.height + 1 {
                scrollView = scroll
                break
            }
            ancestor = current.superview
        }
        guard scrollView != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollAtEdge() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func scrollAtEdge() {
        guard let view, let window = view.window, let scroll = scrollView,
              let document = scroll.documentView, let drag else { return }
        let clip = scroll.contentView
        let pointer = clip.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let y = clip.isFlipped ? pointer.y - clip.bounds.minY : clip.bounds.maxY - pointer.y
        let edge: CGFloat = min(56, clip.bounds.height / 4)
        let delta: CGFloat = y < edge ? -min(12, (edge - y) / 4) :
            y > clip.bounds.height - edge ? min(12, (y - clip.bounds.height + edge) / 4) : 0
        guard delta != 0 else { return }
        let maxOrigin = max(document.bounds.minY, document.bounds.maxY - clip.bounds.height)
        var origin = clip.bounds.origin
        origin.y = min(maxOrigin, max(document.bounds.minY, origin.y + (document.isFlipped ? delta : -delta)))
        guard origin != clip.bounds.origin else { return }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        onHover?(drag, view.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
    func end() {
        timer?.invalidate()
        timer = nil
        drag = nil
        scrollView = nil
        view = nil
        onHover?(nil, .zero)
    }
}
#endif

private struct CalendarTimeBlockEditor: View {
    let block: WorkTimeBlock
    let calendar: Calendar
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var minutes: String
    init(block: WorkTimeBlock, calendar: Calendar) {
        self.block = block; self.calendar = calendar
        _start = State(initialValue: block.start)
        _minutes = State(initialValue: String(max(1, Int(block.end.timeIntervalSince(block.start) / 60))))
    }
    private var validation: String? {
        guard model.item(block.itemID) != nil else { return "工作已删除或不可用" }
        guard let value = Int(minutes), (1...5256000).contains(value) else { return "请输入正整数分钟" }
        return start < Date() ? "请选择未来时间；实际投入请在工作详情记录" : nil
    }
    var body: some View {
        ProjectEditorContainer(title: "设置工作时间块", identifier: "calendar.block.editor", validation: validation, save: {
            guard let value = Int(minutes) else { return false }
            return await model.saveTimeBlock(WorkTimeBlock(id: block.id, itemID: block.itemID, start: start, end: start.addingTimeInterval(Double(value) * 60)))
        }) {
            Section("工作安排") {
                Text(model.item(block.itemID)?.name ?? "已删除工作").font(.headline)
                DatePicker("开始时间", selection: $start).environment(\.calendar, calendar).environment(\.timeZone, calendar.timeZone)
                    .accessibilityIdentifier("calendar.block.start")
                ProjectMinutesField(title: "时长（分钟）", text: $minutes, identifier: "calendar.block.minutes")
                Text("工作时区：\(calendar.timeZone.identifier)").font(.caption).foregroundStyle(.secondary)
                Text("保存只确定安排，不改变真实投入和剩余时间。")
                if model.workspace.timeBlocks?.contains(where: { $0.id == block.id }) == true {
                    CalendarTimeBlockIntegrationRow(block: block)
                    Button(role: .destructive) {
                        Task { if await model.mutate({ try $0.removeTimeBlock(id: block.id, now: Date()) }) { dismiss() } }
                    } label: { Label("移除时间块（保留工作）", systemImage: "trash").frame(minHeight: 44) }
                        .disabled(model.saving).accessibilityIdentifier("calendar.block.removeNow")
                }
            }
        }
    }
}
