import AppKit
import CoreImage.CIFilterBuiltins
import Observation
import SMCore
import SMProtocol

/// The settings-facing side of phone access: the persisted on/off switch, pairing code and
/// paired devices around SMCore's RemoteHub (DEV_SPEC §17).
@MainActor @Observable final class RemoteAccess {
  static let enabledKey = "remoteEnabled"

  private(set) var status = RemoteHub.Status()
  private(set) var devices: [RemoteDevice] = []
  private(set) var pairing: PairingPayload?
  private(set) var pairingExpires: Date?
  private(set) var error: String?
  var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

  @ObservationIgnored private let hub: RemoteHub?
  /// Usage rows answered to phones that ask (RemoteHub.usageRows).
  var usageRows: (() -> [UsageRow])? {
    get { hub?.usageRows }
    set { hub?.usageRows = newValue }
  }

  init(store: SessionStore, directory: URL, audit: @escaping @MainActor (String) -> Void) {
    do {
      hub = try RemoteHub(store: store, directory: directory, audit: audit)
    } catch {
      hub = nil
      self.error = "手机访问不可用：\(error.localizedDescription)"
    }
    hub?.statusChanged = { [weak self] status in
      self?.status = status
      self?.reloadDevices()
    }
    reloadDevices()
  }

  /// Starts the server if the switch was left on.
  func resume() async {
    if enabled { await setEnabled(true) }
  }

  func setEnabled(_ on: Bool) async {
    UserDefaults.standard.set(on, forKey: Self.enabledKey)
    guard let hub else { return }
    if on {
      do {
        try await hub.start(serverName: Host.current().localizedName ?? "Mac")
        error = nil
        newPairingCode()
      } catch {
        self.error = "无法开启手机访问：\(error.localizedDescription)"
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
      }
    } else {
      hub.stop()
      pairing = nil
      pairingExpires = nil
    }
    status = hub.status
  }

  func newPairingCode() {
    pairing = hub?.pairingPayload()
    pairingExpires = pairing.map { _ in Date().addingTimeInterval(RemoteDevices.codeLifetime) }
    // Debug aid (like SM_SNAPSHOT_DIR): the link for sm-remote, without reading the QR code.
    if let path = ProcessInfo.processInfo.environment["SM_REMOTE_PAIRING_OUT"], let pairing {
      FileManager.default.createFile(
        atPath: path, contents: Data(pairing.url.absoluteString.utf8),
        attributes: [.posixPermissions: 0o600])
    }
  }

  func revoke(_ device: RemoteDevice) {
    do { try hub?.revoke(deviceID: device.id) } catch {
      self.error = "吊销失败：\(error.localizedDescription)"
    }
    reloadDevices()
  }

  func reloadDevices() {
    devices = hub?.devices.all.sorted { $0.pairedAt > $1.pairedAt } ?? []
  }

  func stop() { hub?.stop() }

  static func qrCode(for text: String, size: CGFloat) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let scale = size / output.extent.width
    let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let rep = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
  }
}
