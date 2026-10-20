import SwiftUI

extension Color {
    static let cubicAccent = Color("CubicAccent")
    static let cubicAmber = Color("CubicAmber")
    static let cubicOnAccent = Color("CubicOnAccent")
}
struct MetricTile: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }
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
