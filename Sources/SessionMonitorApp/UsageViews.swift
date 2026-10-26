import Charts
import SMCore
import SMProtocol
import SwiftUI

/// Token usage of all local sessions (UsageLedger), for the usage window.
@MainActor @Observable final class UsageStats {
  var rows: [UsageRow] = []
  var scanning = false
  var updatedAt: Date?
}

// MARK: Panel row

/// The thread's total and how full its context is, at the end of a panel row.
struct UsageBadge: View {
  let usage: SessionUsage

  var body: some View {
    HStack(spacing: 4) {
      Text(UsageReport.format(usage.total.total))
      if let fraction = usage.contextFraction {
        ContextRing(fraction: fraction)
        Text("\(Int((fraction * 100).rounded()))%")
          .foregroundStyle(fraction >= SessionUsage.contextWarning ? Theme.orange : Theme.textSecondary)
      }
    }
    .font(.caption2.monospacedDigit())
    .foregroundStyle(Theme.textSecondary)
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(usage.tip)
  }
}

struct ContextRing: View {
  let fraction: Double
  var size: CGFloat = 10

  var body: some View {
    let warning = fraction >= SessionUsage.contextWarning
    ZStack {
      Circle().stroke(Theme.border, lineWidth: 2)
      Circle().trim(from: 0, to: max(0.03, fraction))
        .stroke(warning ? Theme.orange : Theme.textSecondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
    .frame(width: size, height: size)
  }
}

extension SessionUsage {
  /// Hover text: totals, the breakdown and the context.
  var tip: String {
    var lines = ["本线程累计 \(UsageReport.format(total.total)) tokens" + (model.map { " · \($0)" } ?? "")]
    lines.append(UsageReport.breakdown(total))
    if let contextTokens, let contextWindow, let fraction = contextFraction {
      var line = "上下文 \(UsageReport.format(contextTokens)) / \(UsageReport.format(contextWindow))（\(Int((fraction * 100).rounded()))%）"
      if fraction >= Self.contextWarning { line += "，接近自动压缩" }
      lines.append(line)
    }
    return lines.joined(separator: "\n")
  }
}

// MARK: Usage window

enum UsageRange: String, CaseIterable, Identifiable {
  case today = "今天", week = "近 7 天", month = "近 30 天", all = "全部"
  var id: String { rawValue }
  var days: Int? {
    switch self {
    case .today: 1
    case .week: 7
    case .month: 30
    case .all: nil
    }
  }
  func rows(_ rows: [UsageRow], now: Date = Date()) -> [UsageRow] {
    guard let days else { return rows }
    let first = UsageReport.lastDays(days, now: now).first ?? ""
    return rows.filter { $0.day >= first }
  }
}

struct UsageView: View {
  let stats: UsageStats
  let refresh: () -> Void
  @State private var range: UsageRange = .week
  @State private var hoveredDay: String?

  static let chartDays = 30

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header
        HStack(spacing: 12) {
          ForEach([UsageRange.today, .week, .month]) { tile($0) }
        }
        section("近 \(Self.chartDays) 天每日用量") { dailyChart }
        let selected = range.rows(stats.rows)
        section("\(range.rawValue)明细") {
          Picker("范围", selection: $range) {
            ForEach(UsageRange.allCases) { Text($0.rawValue).tag($0) }
          }
          .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
          breakdown(UsageReport.total(selected))
        }
        HStack(alignment: .top, spacing: 16) {
          section("按模型") { ranking(UsageReport.ranking(selected, by: \.model)) }
          section("按项目") { ranking(UsageReport.ranking(selected, by: \.project)) }
        }
        Text("统计本机全部 Claude Code 与 Codex 会话记录（含 \(AppInfo.name) 未运行期间的会话），按消息时间归入当天。总量 = 输入（含缓存读写）+ 输出。")
          .font(.caption).foregroundStyle(Theme.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(20)
    }
    .frame(minWidth: 640, idealWidth: 680, minHeight: 600, idealHeight: 760)
  }

  private var header: some View {
    HStack {
      Text("Token 用量").font(.title2.weight(.semibold))
      Spacer()
      if stats.scanning {
        ProgressView().controlSize(.small)
        Text(stats.rows.isEmpty ? "正在统计全部历史…" : "正在更新…").font(.caption).foregroundStyle(Theme.textSecondary)
      } else if let updated = stats.updatedAt {
        Text("更新于 \(updated.formatted(date: .omitted, time: .shortened))").font(.caption)
          .foregroundStyle(Theme.textSecondary)
      }
      Button("刷新", systemImage: "arrow.clockwise", action: refresh).disabled(stats.scanning)
    }
  }

  private func tile(_ range: UsageRange) -> some View {
    let rows = range.rows(stats.rows)
    let claude = UsageReport.total(rows.filter { $0.agent == "claude" }).total
    let codex = UsageReport.total(rows.filter { $0.agent == "codex" }).total
    return VStack(alignment: .leading, spacing: 6) {
      Text(range.rawValue).font(.caption).foregroundStyle(Theme.textSecondary)
      Text(UsageReport.format(claude + codex)).font(.system(size: 26, weight: .semibold).monospacedDigit())
      HStack(spacing: 10) {
        legendItem("Claude", Theme.chartClaude, claude)
        legendItem("Codex", Theme.chartCodex, codex)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: Theme.radiusMedium).fill(Theme.fill))
  }

  private func legendItem(_ name: String, _ color: Color, _ value: Int) -> some View {
    HStack(spacing: 4) {
      RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
      Text("\(name) \(UsageReport.format(value))").font(.caption2.monospacedDigit()).foregroundStyle(Theme.textSecondary)
    }
  }

  private struct DayPoint: Identifiable {
    var day: String
    var date: Date
    var agent: String
    var tokens: Int
    var id: String { day + agent }
  }

  private var dailyPoints: [DayPoint] {
    let days = UsageReport.lastDays(Self.chartDays)
    var totals: [String: Int] = [:]
    for row in stats.rows where row.day >= (days.first ?? "") {
      totals[row.day + "|" + row.agent, default: 0] += row.usage.total
    }
    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd"
    return days.flatMap { day in
      ["Claude", "Codex"].map { agent in
        DayPoint(
          day: day, date: parser.date(from: day) ?? Date(), agent: agent,
          tokens: totals[day + "|" + agent.lowercased()] ?? 0)
      }
    }
  }

  private var dailyChart: some View {
    let points = dailyPoints
    return Chart {
      ForEach(points) { point in
        BarMark(x: .value("日期", point.date, unit: .day), y: .value("Tokens", point.tokens), width: .ratio(0.7))
          .foregroundStyle(by: .value("代理", point.agent))
          .cornerRadius(2)
          .opacity(hoveredDay == nil || hoveredDay == point.day ? 1 : 0.45)
      }
      if let hoveredDay, let date = points.first(where: { $0.day == hoveredDay })?.date {
        RuleMark(x: .value("日期", date, unit: .day))
          .foregroundStyle(Theme.border)
          .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
            dayTooltip(hoveredDay, points.filter { $0.day == hoveredDay })
          }
      }
    }
    .chartForegroundStyleScale(["Claude": Theme.chartClaude, "Codex": Theme.chartCodex])
    .chartLegend(position: .top, alignment: .leading)
    .chartYAxis {
      AxisMarks(position: .leading) { value in
        AxisGridLine().foregroundStyle(Theme.separator)
        AxisValueLabel { if let tokens = value.as(Int.self) { Text(UsageReport.format(tokens)) } }
      }
    }
    .chartXAxis {
      AxisMarks(values: .stride(by: .day, count: 7)) { _ in
        AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true)
      }
    }
    .chartOverlay { proxy in
      GeometryReader { geometry in
        Rectangle().fill(.clear).contentShape(Rectangle())
          .onContinuousHover { phase in
            switch phase {
            case .active(let location):
              guard let frame = proxy.plotFrame else { return }
              let x = location.x - geometry[frame].origin.x
              hoveredDay = proxy.value(atX: x, as: Date.self).map { UsageReport.dayKey($0) }
            case .ended:
              hoveredDay = nil
            }
          }
      }
    }
    .frame(height: 200)
  }

  private func dayTooltip(_ day: String, _ points: [DayPoint]) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(day).font(.caption.weight(.semibold))
      ForEach(points) { point in
        legendItem(point.agent, point.agent == "Claude" ? Theme.chartClaude : Theme.chartCodex, point.tokens)
      }
      Text("合计 \(UsageReport.format(points.reduce(0) { $0 + $1.tokens }))").font(.caption2.monospacedDigit())
    }
    .padding(8)
    .background(RoundedRectangle(cornerRadius: Theme.radiusSmall).fill(Theme.canvasRaised).shadow(radius: 4, y: 2))
  }

  private func breakdown(_ usage: TokenUsage) -> some View {
    let items: [(String, Int)] = [
      ("总量", usage.total), ("输入", usage.input), ("缓存读", usage.cacheRead), ("缓存写", usage.cacheWrite),
      ("输出", usage.output), ("其中思考", usage.reasoning),
    ]
    return HStack(spacing: 0) {
      ForEach(items, id: \.0) { item in
        VStack(alignment: .leading, spacing: 2) {
          Text(item.0).font(.caption).foregroundStyle(Theme.textSecondary)
          Text(UsageReport.format(item.1)).font(.body.weight(.medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  /// Top entries with a bar proportional to the largest; the rest folded into "其他".
  private func ranking(_ entries: [(name: String, usage: TokenUsage)]) -> some View {
    let limit = 8
    var shown = Array(entries.prefix(limit))
    if entries.count > limit {
      shown.append((name: "其他 \(entries.count - limit) 项", usage: entries.dropFirst(limit).reduce(TokenUsage()) { $0 + $1.usage }))
    }
    let largest = max(1, shown.map(\.usage.total).max() ?? 1)
    return VStack(alignment: .leading, spacing: 6) {
      if shown.isEmpty { Text("暂无数据").font(.caption).foregroundStyle(Theme.textSecondary) }
      ForEach(shown, id: \.name) { entry in
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text(entry.name).font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(UsageReport.format(entry.usage.total)).font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
          }
          GeometryReader { geometry in
            Capsule().fill(Theme.blue.opacity(0.75))
              .frame(width: max(3, geometry.size.width * Double(entry.usage.total) / Double(largest)))
          }
          .frame(height: 4)
        }
      }
    }
  }

  private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.headline)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
