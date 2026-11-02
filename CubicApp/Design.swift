import SwiftUI
import CubicCore

extension Color {
    static let cubicAccent = Color("CubicAccent")
    static let cubicAmber = Color("CubicAmber")
    static let cubicOnAccent = Color("CubicOnAccent")
    static let cubicLate = Color.red
    static let cubicOnTrack = Color.green
}

/// Spacing and radius tokens shared by every redesigned surface.
enum CubicMetrics {
    static let cardRadius: CGFloat = 22
    static let rowRadius: CGFloat = 14
    static let blockRadius: CGFloat = 8
    static let pagePadding: CGFloat = 16
}

// MARK: - Project health

/// One vocabulary for schedule risk, used by every list, chip and detail page.
enum ProjectHealth: Equatable {
    case onTrack, tight, late, unknown, noDeadline, calculating, done

    var label: String {
        switch self {
        case .onTrack: "正常"
        case .tight: "紧张"
        case .late: "来不及"
        case .unknown: "信息不足"
        case .noDeadline: "无截止"
        case .calculating: "计算中"
        case .done: "已结束"
        }
    }
    var tint: Color {
        switch self {
        case .onTrack: .cubicOnTrack
        case .tight: .cubicAmber
        case .late: .cubicLate
        case .unknown, .noDeadline, .calculating, .done: .secondary
        }
    }
    var symbol: String {
        switch self {
        case .onTrack: "checkmark.circle.fill"
        case .tight: "exclamationmark.circle.fill"
        case .late: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle.fill"
        case .noDeadline: "minus.circle.fill"
        case .calculating: "clock.arrow.circlepath"
        case .done: "checkmark.seal.fill"
        }
    }
    /// Lower values need attention first.
    var urgency: Int {
        switch self { case .late: 0; case .tight: 1; case .unknown: 2; case .calculating: 3; case .onTrack: 4; case .noDeadline: 5; case .done: 6 }
    }
}

extension AppModel {
    func projectRisks(_ projectID: String) -> [Risk] {
        presentedRisks.filter { risk in
            risk.projectID == projectID || (risk.projectID == nil && !Set(risk.itemIDs).isDisjoint(with: projectItemIDs(projectID)))
        }
    }

    func health(ofProject projectID: String) -> ProjectHealth {
        guard let project = workspace.projects.first(where: { $0.id == projectID }) else { return .unknown }
        guard project.hasDeliveryCommitment else { return .done }
        if let deadline = project.deadline, deadline < now { return .late }
        guard let assessment = planning?.projects.first(where: { $0.projectID == projectID }) else {
            return project.deadline == nil ? .noDeadline : .calculating
        }
        let risks = projectRisks(projectID)
        if assessment.feasibility == .infeasible ||
            risks.contains(where: { $0.kind == .provenCapacityShortfall || ($0.kind == .sharedResourceConflict && ($0.shortageMinutes ?? 0) > 0) }) {
            return .late
        }
        if project.deadline == nil { return assessment.totalDemandMinutes == nil ? .unknown : .noDeadline }
        if [.insufficient, .boundaryReached].contains(assessment.warningState) ||
            risks.contains(where: { $0.kind == .energyConstraint || $0.kind == .continuousConstraint }) {
            return .tight
        }
        if assessment.totalDemandMinutes == nil || assessment.feasibility == .undetermined ||
            risks.contains(where: { $0.kind == .insufficientInformation }) {
            return .unknown
        }
        return .onTrack
    }

    /// Completed share of a project's active work, counted by item.
    func progress(ofProject projectID: String) -> Double {
        let ids = projectItemIDs(projectID)
        let items = workspace.items.filter { ids.contains($0.id) && !$0.archived && $0.effectiveDisposition != .cancelled }
        guard !items.isEmpty else { return 0 }
        return Double(items.filter { $0.status == .completed && !$0.needsReview }.count) / Double(items.count)
    }

    func health(ofItem item: WorkItem) -> ProjectHealth {
        relatedProjectIDs(for: item).map { health(ofProject: $0) }.min { $0.urgency < $1.urgency } ?? .noDeadline
    }
}

// MARK: - Components

struct StatusChip: View {
    let text: String
    var tint: Color = .secondary
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tint.opacity(0.13), in: Capsule())
        .fixedSize()
    }
}

struct HealthChip: View {
    let health: ProjectHealth
    var body: some View {
        StatusChip(text: health.label, tint: health.tint)
            .accessibilityLabel("排期状态：\(health.label)")
    }
}

struct HealthDot: View {
    let health: ProjectHealth
    var body: some View {
        Circle().fill(health.tint).frame(width: 8, height: 8).accessibilityHidden(true)
    }
}

struct DurationChip: View {
    let minutes: Int?
    var body: some View { StatusChip(text: shortMinutesLabel(minutes), tint: .secondary) }
}

struct ProgressRing: View {
    let fraction: Double
    var size: CGFloat = 44
    var lineWidth: CGFloat = 5
    var tint: Color = .cubicAccent
    var showsLabel = true
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.18), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showsLabel {
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: size * 0.26, weight: .semibold)).monospacedDigit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement().accessibilityLabel("完成 \(Int((fraction * 100).rounded()))%")
    }
}

/// Planned versus available time; overflow turns the bar amber.
struct CapacityBar: View {
    let planned: Int
    let available: Int
    var height: CGFloat = 4
    var body: some View {
        GeometryReader { geometry in
            let ratio = available > 0 ? min(1, Double(planned) / Double(available)) : (planned > 0 ? 1 : 0)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(planned > available ? Color.cubicAmber : Color.cubicAccent)
                    .frame(width: geometry.size.width * ratio)
            }
        }
        .frame(height: height)
        .accessibilityElement().accessibilityLabel("已排 \(minutesLabel(planned))，可用 \(minutesLabel(available))")
    }
}

/// Floating hero surfaces use Liquid Glass; content lists stay plain.
struct GlassCard: ViewModifier {
    var tint: Color? = nil
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(tint.map { .regular.tint($0.opacity(0.18)) } ?? .regular, in: RoundedRectangle(cornerRadius: CubicMetrics.cardRadius))
    }
}

extension View {
    func glassCard(tint: Color? = nil) -> some View { modifier(GlassCard(tint: tint)) }
}

struct EmptyMessage: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
    }
}

func minutesLabel(_ minutes: Int?) -> String {
    guard let minutes else { return "待估计" }
    if minutes == 0 { return "0 分钟" }
    if minutes < 60 { return "\(minutes) 分钟" }
    let remainder = minutes % 60
    return remainder == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(remainder) 分"
}

/// Compact duration for chips: 45min, 2h, 1.5h.
func shortMinutesLabel(_ minutes: Int?) -> String {
    guard let minutes else { return "待估计" }
    if minutes < 60 { return "\(minutes)min" }
    if minutes % 60 == 0 { return "\(minutes / 60)h" }
    let hours = Double(minutes) / 60
    return hours.formatted(.number.precision(.fractionLength(0...1))) + "h"
}
