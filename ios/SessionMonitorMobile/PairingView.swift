import SMProtocol
import SwiftUI
import VisionKit

/// First run, or "pair another Mac": scan the QR code from the Mac's settings, or paste its link.
struct PairingView: View {
  @Environment(MobileModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  var dismissible = false
  @State private var scanning = false

  var body: some View {
    NavigationStack {
      VStack(spacing: 22) {
        Spacer()
        Image(systemName: "macbook.and.iphone")
          .font(.system(size: 56, weight: .light)).foregroundStyle(Theme.blue)
        VStack(spacing: 8) {
          Text("连接你的 Mac").font(.title2.weight(.semibold))
          Text("在 Mac 上打开\(AppInfo.name) → 设置 → 手机，开启\"允许手机访问\"，然后扫描显示的二维码。")
            .font(.callout).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
        VStack(spacing: 12) {
          if DataScannerViewController.isSupported {
            Button { scanning = true } label: {
              Label("扫描二维码", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
          }
          Button {
            if let text = UIPasteboard.general.string, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
              Task { await model.pair(link: url) }
            } else {
              model.pairingError = "剪贴板里没有配对链接。在 Mac 的配对页面点\"复制链接\"。"
            }
          } label: {
            Label("粘贴配对链接", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered).controlSize(.large)
        }
        .padding(.horizontal, 32)
        .disabled(model.pairing)
        if model.pairing {
          ProgressView("正在配对…")
        } else if let error = model.pairingError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.callout).foregroundStyle(Theme.pink).multilineTextAlignment(.center)
            .padding(.horizontal, 28)
        }
        Spacer()
        Text("只在局域网或 Tailscale 内连接，通信经 TLS 加密。")
          .font(.footnote).foregroundStyle(Theme.textSecondary)
          .padding(.bottom, 12)
      }
      .frame(maxWidth: .infinity)
      .background(Theme.canvas.ignoresSafeArea())
      .toolbar {
        if dismissible {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        }
      }
      .sheet(isPresented: $scanning) {
        QRScannerView { text in
          scanning = false
          if let url = URL(string: text) { Task { await model.pair(link: url) } }
        }
        .ignoresSafeArea()
      }
      .onChange(of: model.servers.count) { old, new in
        if dismissible, new > old { dismiss() }
      }
    }
  }
}

/// VisionKit's live scanner, reporting the first SessionMonitor pairing QR code it sees.
struct QRScannerView: UIViewControllerRepresentable {
  let found: (String) -> Void

  func makeUIViewController(context: Context) -> DataScannerViewController {
    let scanner = DataScannerViewController(
      recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
      isHighlightingEnabled: true)
    scanner.delegate = context.coordinator
    try? scanner.startScanning()
    return scanner
  }

  func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(found: found) }

  final class Coordinator: NSObject, DataScannerViewControllerDelegate {
    let found: (String) -> Void
    private var done = false
    init(found: @escaping (String) -> Void) { self.found = found }

    func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
      for item in items {
        guard !done, case .barcode(let code) = item, let text = code.payloadStringValue,
          text.hasPrefix("sessionmonitor://pair")
        else { continue }
        done = true
        scanner.stopScanning()
        found(text)
      }
    }
  }
}
