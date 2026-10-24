import SMProtocol
import SwiftUI

struct SessionDetailView: View {
  let sessionID: String
  @Environment(MobileModel.self) private var model
  #if DEBUG
    // `-SMTab 终端` opens the terminal tab (screenshots in testing).
    @State private var tab = Tab(rawValue: UserDefaults.standard.string(forKey: "SMTab") ?? "") ?? .conversation
  #else
    @State private var tab = Tab.conversation
  #endif
  @State private var draft = ""
  @State private var confirmBusySend = false
  @FocusState private var inputFocused: Bool

  enum Tab: String, CaseIterable { case conversation = "对话", terminal = "终端" }

  private var session: RemoteSession? { model.sessions[sessionID] }
  private var pane: PaneSnapshot? { model.panes[sessionID] }

  var body: some View {
    VStack(spacing: 0) {
      if let session {
        header(session)
        if session.remoteInput {
          Picker("视图", selection: $tab) {
            ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
          }
          .pickerStyle(.segmented).padding(.horizontal, 16).padding(.bottom, 8)
        }
        Group {
          switch session.remoteInput ? tab : .conversation {
          case .conversation: ConversationView(entries: model.transcripts[sessionID])
          case .terminal: TerminalView(pane: pane)
          }
        }
        .frame(maxHeight: .infinity)
        bottomBar(session)
      } else {
        ContentUnavailableView("会话已结束", systemImage: "xmark.circle", description: Text("Mac 上已不再显示这个会话。"))
      }
    }
    .background(Theme.canvas.ignoresSafeArea())
    .navigationTitle(session?.name ?? "会话")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { model.open(sessionID) }
    .onDisappear { model.close(sessionID) }
    .confirmationDialog("会话正在工作", isPresented: $confirmBusySend, titleVisibility: .visible) {
      Button("仍然发送") { submit() }
    } message: {
      Text("消息会输入到终端，由 agent 决定何时处理。")
    }
  }

  private func header(_ session: RemoteSession) -> some View {
    HStack(spacing: 8) {
      Image(systemName: session.stateSymbol).foregroundStyle(session.stateColor)
      Text(session.stateLabel).font(.subheadline.weight(.semibold)).foregroundStyle(session.stateColor)
      Tag(text: session.agentLabel, color: session.agentColor)
      Text(session.projectName).font(.subheadline).foregroundStyle(Theme.textSecondary).lineLimit(1)
      Spacer()
      if let tool = session.currentTool, session.state == .working {
        Text(tool).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary).lineLimit(1)
          .frame(maxWidth: 140, alignment: .trailing)
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 10)
  }

  @ViewBuilder private func bottomBar(_ session: RemoteSession) -> some View {
    VStack(spacing: 8) {
      if !session.remoteInput {
        Label(
          session.state == .ended ? "会话已结束" : "仅查看：这个会话没有在 tmux 中运行，无法远程发送",
          systemImage: "eye"
        )
        .font(.footnote).foregroundStyle(Theme.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        if let menu = pane?.menu, !menu.isEmpty {
          MenuButtons(options: menu) { model.send($0, to: sessionID) }
        }
        if let feedback = model.feedback[sessionID], Date().timeIntervalSince(feedback.at) < 30 {
          FeedbackLine(feedback: feedback)
        }
        HStack(alignment: .bottom, spacing: 8) {
          if session.state == .working || session.state == .needsPermission || session.state == .needsInput {
            Button { model.send(.escape, to: sessionID) } label: {
              Image(systemName: "stop.fill").font(.system(size: 15, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(Circle().fill(Theme.fill))
            }
            .tint(Theme.pink)
            .accessibilityLabel("中断（Esc）")
          }
          TextField("发送消息到终端", text: $draft, axis: .vertical)
            .lineLimit(1...6)
            .focused($inputFocused)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 19).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(Theme.border))
          Button {
            if session.state == .working { confirmBusySend = true } else { submit() }
          } label: {
            Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold))
              .foregroundStyle(.white).frame(width: 38, height: 38)
              .background(Circle().fill(canSend ? Theme.blue : Theme.idle.opacity(0.5)))
          }
          .disabled(!canSend)
          .accessibilityLabel("发送")
        }
      }
    }
    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
    .background(.bar)
  }

  private var canSend: Bool {
    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (pane?.menu.isEmpty ?? true)
  }

  private func submit() {
    let text = draft
    draft = ""
    model.send(text, to: sessionID)
  }
}

/// The numbered choices on screen (permission prompt, question), as buttons that press the number.
struct MenuButtons: View {
  let options: [MenuOption]
  let press: (RemoteKey) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("终端正在等待选择", systemImage: "list.number")
        .font(.caption.weight(.semibold)).foregroundStyle(Theme.orange)
      ForEach(options, id: \.number) { option in
        Button {
          if let key = RemoteKey.digit(option.number) { press(key) }
        } label: {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(option.number)").font(.callout.monospacedDigit().weight(.bold))
              .frame(width: 22, height: 22).background(Circle().fill(Theme.fill))
            Text(option.label).font(.callout).multilineTextAlignment(.leading)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.horizontal, 10).padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 12)
              .fill(option.selected ? Theme.blue.opacity(0.12) : Theme.raised))
          .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(option.selected ? Theme.blue.opacity(0.4) : Theme.border))
        }
        .buttonStyle(.plain)
        .disabled(RemoteKey.digit(option.number) == nil)
      }
    }
  }
}

struct FeedbackLine: View {
  let feedback: MobileModel.Feedback

  var body: some View {
    HStack(spacing: 6) {
      switch feedback.status {
      case nil: ProgressView().controlSize(.mini)
      case .delivered?: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
      case .unconfirmed?: Image(systemName: "questionmark.circle.fill").foregroundStyle(Theme.yellow)
      case .rejected?: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.pink)
      }
      Text(feedback.message).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
      Spacer()
    }
  }
}

struct ConversationView: View {
  let entries: [TranscriptEntry]?

  var body: some View {
    if let entries {
      if entries.isEmpty {
        ContentUnavailableView("还没有对话", systemImage: "text.bubble", description: Text("会话的对话记录会显示在这里。"))
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
              ForEach(entries) { EntryView(entry: $0).id($0.id) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
          }
          .defaultScrollAnchor(.bottom)
          .onChange(of: entries.last?.id) { _, last in
            if let last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
          }
        }
      }
    } else {
      ProgressView("正在读取对话…").frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

struct EntryView: View {
  let entry: TranscriptEntry

  var body: some View {
    switch entry.role {
    case .user:
      HStack {
        Spacer(minLength: 40)
        Text(entry.text).font(.callout).foregroundStyle(.white)
          .padding(.horizontal, 12).padding(.vertical, 8)
          .background(RoundedRectangle(cornerRadius: 16).fill(Theme.blue))
          .textSelection(.enabled)
      }
    case .assistant:
      Text(Self.markdown(entry.text)).font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.border))
        .textSelection(.enabled)
    case .tool:
      Label(entry.text, systemImage: "terminal")
        .font(.caption.monospaced()).foregroundStyle(Theme.textSecondary).lineLimit(3)
        .padding(.horizontal, 4)
    }
  }

  static func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)))
      ?? AttributedString(text)
  }
}
