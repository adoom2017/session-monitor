import Charts
import SMProtocol
import SwiftUI

struct ContextRing: View {
  let fraction: Double
  var size: CGFloat = 12

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
  var percent: Int? { contextFraction.map { Int(($0 * 100).rounded()) } }
  var nearlyFull: Bool { (contextFraction ?? 0) >= Self.contextWarning }
}

/// Under the session header: the thread's total and context; tap for the breakdown.
struct SessionUsageLine: View {
  let usage: SessionUsage
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button {
        withAnimation(.snappy) { expanded.toggle() }
      } label: {
        HStack(spacing: 6) {
          Text("\(UsageReport.format(usage.total.total)) tokens")
          if let fraction = usage.contextFraction, let percent = usage.percent {
            Text("·")
            ContextRing(fraction: fraction)
            Text("上下文 \(percent)%").foregroundStyle(usage.nearlyFull ? Theme.orange : Theme.textSecondary)
          }
          Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            .rotationEffect(.degrees(expanded ? 180 : 0))
          Spacer()
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(Theme.textSecondary)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if expanded {
        VStack(alignment: .leading, spacing: 2) {
          Text(UsageReport.breakdown(usage.total))
          if let tokens = usage.contextTokens, let window = usage.contextWindow {
            Text("上下文 \(UsageReport.format(tokens)) / \(UsageReport.format(window))" + (usage.nearlyFull ? "，接近自动压缩" : ""))
          }
          if let model = usage.model { Text(model) }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(Theme.textSecondary)
        .transition(.opacity)
      }
    }
    .padding(.horizontal, 16).padding(.bottom, 8)
  }
}

// MARK: Usage page

enum UsageRange: String, CaseIterable, Identifiable {
  case today = "今天", week = "7 天", month = "30 天", quarter = "90 天"
  var id: String { rawValue }
  var days: Int {
    switch self {
    case .today: 1
    case .week: 7
    case .month: 30
    case .quarter: 90
    }
  }
  func rows(_ rows: [UsageRow], now: Date = Date()) -> [UsageRow] {
    let first = UsageReport.lastDays(days, now: now).first ?? ""
    return rows.filter { $0.day >= first }
  }
}

/// All local sessions' usage on the Mac: tiles, the last 30 days, breakdown, top models/projects.
struct UsagePage: View {
  @Environment(MobileModel.self) private var model
  @State private var range: UsageRange = .week
  @State private var selectedDay: Date?

  var body: some View {
    ScrollView {
      if model.connectedHost == nil {
        ProgressView("正在连接 Mac…").padding(.top, 80)
      } else if !model.supportsUsage {
        ContentUnavailableView(
          "Mac 端版本较旧", systemImage: "chart.bar.xaxis",
          description: Text("更新 Mac 上的\(AppInfo.name)后即可查看用量统计。"))
          .padding(.top, 80)
      } else if let rows = model.usageRows {
        content(rows).padding(16)
      } else {
        ProgressView("正在读取用量…").padding(.top, 80)
      }
    }
    .background(Theme.canvas.ignoresSafeArea())
    .navigationTitle("用量统计")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { model.requestUsage() }
    .onAppear { model.requestUsage() }
    .onChange(of: model.supportsUsage) { model.requestUsage() }
  }

  private func content(_ rows: [UsageRow]) -> some View {
    let selected = range.rows(rows)
    return VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 10) {
        tile(.today, rows)
        tile(.week, rows)
        tile(.month, rows)
      }
      card("近 30 天每日用量") { chart(rows) }
      card("明细") {
        Picker("范围", selection: $range) {
          ForEach(UsageRange.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        breakdown(UsageReport.total(selected))
      }
      card("按模型") { ranking(UsageReport.ranking(selected, by: \.model)) }
      card("按项目") { ranking(UsageReport.ranking(selected, by: \.project)) }
      Text("统计 Mac 上全部 Claude Code 与 Codex 会话记录，按消息时间归入当天。总量 = 输入（含缓存读写）+ 输出。")
        .font(.caption).foregroundStyle(Theme.textSecondary)
    }
  }

  private func tile(_ range: UsageRange, _ rows: [UsageRow]) -> some View {
    let total = UsageReport.total(range.rows(rows)).total
    return VStack(alignment: .leading, spacing: 4) {
      Text(range == .today ? "今天" : "近 \(range.rawValue)").font(.caption).foregroundStyle(Theme.textSecondary)
      Text(UsageReport.format(total)).font(.title3.weight(.semibold).monospacedDigit())
        .minimumScaleFactor(0.7).lineLimit(1)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.raised))
  }

  private struct DayPoint: Identifiable {
    var day: String
    var date: Date
    var agent: String
    var tokens: Int
    var id: String { day + agent }
  }

  private func points(_ rows: [UsageRow]) -> [DayPoint] {
    let days = UsageReport.lastDays(30)
    var totals: [String: Int] = [:]
    for row in rows where row.day >= (days.first ?? "") { totals[row.day + "|" + row.agent, default: 0] += row.usage.total }
    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd"
    return days.flatMap { day in
      ["Claude", "Codex"].map {
        DayPoint(day: day, date: parser.date(from: day) ?? Date(), agent: $0, tokens: totals[day + "|" + $0.lowercased()] ?? 0)
      }
    }
  }

  private func chart(_ rows: [UsageRow]) -> some View {
    let points = points(rows)
    let selectedKey = selectedDay.map { UsageReport.dayKey($0) }
    return VStack(alignment: .leading, spacing: 6) {
      // Tap or drag over the chart: that day's values replace the hint.
      if let selectedKey {
        let day = points.filter { $0.day == selectedKey }
        Text("\(selectedKey)  Claude \(UsageReport.format(day.first { $0.agent == "Claude" }?.tokens ?? 0)) · Codex \(UsageReport.format(day.first { $0.agent == "Codex" }?.tokens ?? 0))")
          .font(.caption.monospacedDigit())
      } else {
        Text("按住图表查看某一天").font(.caption).foregroundStyle(Theme.textSecondary)
      }
      Chart(points) { point in
        BarMark(x: .value("日期", point.date, unit: .day), y: .value("Tokens", point.tokens), width: .ratio(0.7))
          .foregroundStyle(by: .value("代理", point.agent))
          .cornerRadius(2)
          .opacity(selectedKey == nil || selectedKey == point.day ? 1 : 0.45)
      }
      .chartForegroundStyleScale(["Claude": Theme.chartClaude, "Codex": Theme.chartCodex])
      .chartLegend(position: .top, alignment: .leading)
      .chartXSelection(value: $selectedDay)
      .chartYAxis {
        AxisMarks(position: .leading) { value in
          AxisGridLine().foregroundStyle(Theme.border)
          AxisValueLabel { if let tokens = value.as(Int.self) { Text(UsageReport.format(tokens)) } }
        }
      }
      .chartXAxis {
        AxisMarks(values: .stride(by: .day, count: 7)) { _ in
          AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true)
        }
      }
      .frame(height: 180)
    }
  }

  private func breakdown(_ usage: TokenUsage) -> some View {
    let items: [(String, Int)] = [
      ("总量", usage.total), ("输入", usage.input), ("缓存读", usage.cacheRead),
      ("缓存写", usage.cacheWrite), ("输出", usage.output), ("其中思考", usage.reasoning),
    ]
    return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 10) {
      ForEach(items, id: \.0) { item in
        VStack(alignment: .leading, spacing: 2) {
          Text(item.0).font(.caption).foregroundStyle(Theme.textSecondary)
          Text(UsageReport.format(item.1)).font(.body.weight(.medium).monospacedDigit())
        }
      }
    }
  }

  private func ranking(_ entries: [(name: String, usage: TokenUsage)]) -> some View {
    let limit = 6
    var shown = Array(entries.prefix(limit))
    if entries.count > limit {
      shown.append((name: "其他 \(entries.count - limit) 项", usage: entries.dropFirst(limit).reduce(TokenUsage()) { $0 + $1.usage }))
    }
    let largest = max(1, shown.map(\.usage.total).max() ?? 1)
    return VStack(alignment: .leading, spacing: 8) {
      if shown.isEmpty { Text("暂无数据").font(.caption).foregroundStyle(Theme.textSecondary) }
      ForEach(shown, id: \.name) { entry in
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text(entry.name).font(.subheadline).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(UsageReport.format(entry.usage.total)).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.textSecondary)
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

  private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.headline)
      content()
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.raised))
  }
}
