import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct UploadReceipt: Decodable, Equatable {
  let path: String
  let bytes: UInt64
}

// Each instance coordinates one read on one worker. NSFileCoordinator.cancel()
// is the operation Foundation permits another thread to call while that read waits.
private final class UploadFileAccess: @unchecked Sendable {
  private let coordinator = NSFileCoordinator(filePresenter: nil)
  private let lock = NSLock()
  private var cancelled = false

  func cancel() {
    lock.withLock { cancelled = true }
    coordinator.cancel()
  }

  private func checkCancellation() throws {
    if lock.withLock({ cancelled }) { throw CancellationError() }
  }

  func read(_ file: URL, perform: (URL) throws -> UInt64) throws -> UInt64 {
    try checkCancellation()
    let scoped = file.startAccessingSecurityScopedResource()
    defer { if scoped { file.stopAccessingSecurityScopedResource() } }
    var coordinationError: NSError?
    var result: Result<UInt64, Error>?
    coordinator.coordinate(readingItemAt: file, options: .withoutChanges, error: &coordinationError) { url in
      result = Result {
        try self.checkCancellation()
        return try perform(url)
      }
    }
    if let result { return try result.get() }
    if let coordinationError { throw coordinationError }
    throw CancellationError()
  }
}

extension TerminalTransport {
  static let maxUploadBytes: UInt64 = 128 * 1024 * 1024

  static func upload(_ client: ClientProfile, session: RemoteSession, file: URL) async throws -> UploadReceipt {
    try Task.checkCancellation()
    guard session.uploadVersion == 1 else { throw RelayError("请更新节点上的 tmux-link-agent 后再上传。") }
    guard session.id >= 0, let instance = session.managedInstance, !instance.isEmpty, !instance.contains("\0"),
          let directory = session.directory, directory.hasPrefix("/"), !directory.contains("\0") else {
      throw RelayError("找不到可用的目标窗格与目录，请重新进入会话。")
    }
    let name = file.lastPathComponent
    guard file.isFileURL, !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
          !name.contains("/"), !name.contains("\\"), !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      throw RelayError("请选择具有有效文件名的普通文件。")
    }
    let connection = try TerminalTransport(client)
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    let reader = FileHandle(fileDescriptor: pair[0], closeOnDealloc: true)
    let worker = pair[1]
    let fileAccess = UploadFileAccess()
    return try await withTaskCancellationHandler {
      // Read the receipt concurrently with the blocking FFI call. The only
      // payload on this local socket is the verified destination and byte count.
      async let receipt: Data = withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          continuation.resume(with: Result {
            var data = Data()
            while let chunk = try reader.read(upToCount: 4096), !chunk.isEmpty {
              guard data.count + chunk.count <= 32 * 1024 else {
                shutdown(reader.fileDescriptor, SHUT_RDWR)
                throw RelayError("节点返回的上传回执过大。")
              }
              data.append(chunk)
            }
            return data
          })
        }
      }
      let size: UInt64 = try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          continuation.resume(with: Result {
            var ownsWorker = true
            defer { if ownsWorker { close(worker) } }
            return try fileAccess.read(file) { url in
              let descriptor = url.withUnsafeFileSystemRepresentation { path in
                path.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) } ?? -1
              }
              guard descriptor >= 0 else { throw RelayError("无法读取所选文件，请检查「文件」中的下载状态或权限。") }
              var status = stat()
              guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG, status.st_size >= 0 else {
                close(descriptor)
                throw RelayError("每次仅支持上传一个普通文件。")
              }
              let size = UInt64(status.st_size)
              guard size <= maxUploadBytes else { close(descriptor); throw RelayError("单个文件最大为 128 MiB。") }
              ownsWorker = false // Rust owns both descriptors, including on errors.
              try connection.writeUpload(worker: worker, file: descriptor, id: session.id, instance: instance,
                                         directory: directory, name: name, size: size)
              return size
            }
          })
        }
      }
      let bytes = try await receipt
      try Task.checkCancellation()
      var parent = directory
      while parent.last == "/" { parent.removeLast() }
      let expected = parent + "/" + name
      guard let verified = try? JSONDecoder().decode(UploadReceipt.self, from: bytes),
            verified.bytes == size, verified.path.utf8.elementsEqual(expected.utf8) else {
        throw RelayError("无法核实上传回执，请在目标目录检查文件。")
      }
      return verified
    } onCancel: {
      // The FileHandle stays alive until both readers return, so a late cancel
      // cannot shut down a descriptor belonging to a later transfer.
      shutdown(reader.fileDescriptor, SHUT_RDWR)
      fileAccess.cancel()
    }
  }

  private func writeUpload(worker: Int32, file: Int32, id: Int64, instance: String, directory: String,
                           name: String, size: UInt64) throws {
    let der = identity?.certificate ?? Data()
    let pkcs8 = identity?.privateKey ?? Data()
    let message = seed.withUnsafeBytes { (seedBytes: UnsafeRawBufferPointer) in
      der.withUnsafeBytes { (cert: UnsafeRawBufferPointer) in
        pkcs8.withUnsafeBytes { (key: UnsafeRawBufferPointer) in
          tl_upload_secure(worker, file, endpoint, port, user, pin, seedBytes.bindMemory(to: UInt8.self).baseAddress!,
                           id, instance, directory, name, size,
                           der.isEmpty ? nil : cert.bindMemory(to: UInt8.self).baseAddress, cert.count,
                           pkcs8.isEmpty ? nil : key.bindMemory(to: UInt8.self).baseAddress, key.count)
        }
      }
    }
    guard let message else { return }
    defer { tl_free_error(message) }
    switch String(cString: message) {
    case "upload exists": throw RelayError("目标目录已有同名文件。请先重命名文件再上传。")
    case "upload target changed": throw RelayError("目标窗格或工作目录已变化，请重新选择目标。")
    case "upload invalid": throw RelayError("文件名、大小或目标目录无效。")
    case "upload unsupported": throw RelayError("请更新节点上的 tmux-link-agent 后再上传。")
    case "upload cancelled": throw CancellationError()
    case "upload incomplete", "upload timed out": throw RelayError("上传未得到完整回执，请在目标目录核实文件后再试。")
    default: throw RelayError("未取得上传回执。请检查连接、目标目录权限及文件是否已到达。")
    }
  }
}

@MainActor
final class SessionUploadFlow: ObservableObject {
  enum Phase {
    case checking, selecting(RemoteSession), sending(RemoteSession, String), interrupted(RemoteSession), done(UploadReceipt), failed(String)
  }
  @Published private(set) var phase = Phase.checking
  @Published var showPicker = false
  @Published private(set) var selected: URL?
  private let client: ClientProfile
  private let locate: () async throws -> RemoteSession
  private var task: Task<Void, Never>?

  init(client: ClientProfile, locate: @escaping () async throws -> RemoteSession) {
    self.client = client
    self.locate = locate
  }

  func begin() {
    cancel()
    selected = nil
    phase = .checking
    task = Task {
      do {
        let session = try await locate()
        try Task.checkCancellation()
        phase = .selecting(session)
        showPicker = true
      } catch { report(error) }
    }
  }

  func pick(_ url: URL?) {
    if let url { selected = url }
    showPicker = false
  }

  func submit() {
    let target: RemoteSession
    switch phase {
    case .selecting(let current), .interrupted(let current): target = current
    default: return
    }
    guard let file = selected else { return }
    phase = .sending(target, file.lastPathComponent)
    task = Task {
      do {
        let current = try await locate()
        try Task.checkCancellation()
        guard current.id == target.id, current.managedInstance == target.managedInstance,
              let oldPath = target.directory, let path = current.directory, oldPath.utf8.elementsEqual(path.utf8) else {
          throw RelayError("选择文件期间目标窗格或目录已变化，请重新选择。")
        }
        let receipt = try await TerminalTransport.upload(client, session: target, file: file)
        try Task.checkCancellation()
        phase = .done(receipt)
      } catch { report(error) }
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
    showPicker = false
  }

  func enteredBackground() {
    guard case .sending(let target, _) = phase else { return }
    cancel()
    phase = .interrupted(target)
  }

  private func report(_ error: Error) {
    guard !Task.isCancelled else { return }
    phase = .failed(error is CancellationError ? "上传已中断，请在目标目录核实文件后再试。" : error.localizedDescription)
  }
}

struct SessionUploadView: View {
  @ObservedObject var flow: SessionUploadFlow
  @Environment(\.dismiss) private var dismiss
  @State private var copied = false

  var body: some View {
    NavigationStack {
      Form {
        switch flow.phase {
        case .checking:
          ProgressView("正在核对目标窗格…")
        case .selecting(let target):
          destination(target)
          Section {
            Button(flow.selected == nil ? "选择文件" : "重新选择文件") { flow.showPicker = true }
              .accessibilityIdentifier("terminal.upload.choose")
            if let file = flow.selected {
              LabeledContent("文件") { Text(verbatim: file.lastPathComponent) }
              Button("上传") { flow.submit() }.accessibilityIdentifier("terminal.upload.send")
            }
          } footer: { Text("单个文件最大为 128 MiB。同名文件会保留。") }
        case .sending(let target, let name):
          destination(target)
          Section {
            LabeledContent("文件") { Text(verbatim: name) }
            ProgressView("正在上传…").accessibilityIdentifier("terminal.upload.sending")
          }
        case .interrupted(let target):
          destination(target)
          Section {
            if let file = flow.selected { LabeledContent("文件") { Text(verbatim: file.lastPathComponent) } }
            Text("上传在切到后台时中断。请先检查目标目录，确认文件是否已到达。")
            Button("从头重新上传") { flow.submit() }.accessibilityIdentifier("terminal.upload.retry")
          }
        case .done(let receipt):
          Section("远端文件") {
            Text(verbatim: receipt.path).font(.body.monospaced()).textSelection(.enabled)
              .accessibilityIdentifier("terminal.upload.path")
            LabeledContent("已上传", value: ByteCountFormatter.string(fromByteCount: Int64(receipt.bytes), countStyle: .file))
            Button {
              UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: receipt.path]], options: [.localOnly: true])
              copied = true
            } label: { Label(copied ? "已复制路径" : "复制路径", systemImage: "doc.on.doc") }
              .accessibilityIdentifier("terminal.upload.copy")
          }
        case .failed(let message):
          Section { Text(message).foregroundStyle(.orange); Button("重新选择") { flow.begin() } }
        }
      }
      .privacySensitive()
      .navigationTitle("上传文件").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(closeTitle) { flow.cancel(); dismiss() }.accessibilityIdentifier("terminal.upload.close")
        }
      }
      .sheet(isPresented: $flow.showPicker) { UploadDocumentPicker(onPick: flow.pick) }
    }
    .onDisappear { if !flow.showPicker { flow.cancel() } }
  }

  private var closeTitle: String {
    switch flow.phase {
    case .sending: return "取消上传"
    case .done, .failed, .interrupted: return "关闭"
    default: return "取消"
    }
  }

  private func destination(_ target: RemoteSession) -> some View {
    Section("上传目标") {
      LabeledContent("会话") { Text(verbatim: target.name) }
      if let directory = target.directory {
        LabeledContent("目录") { Text(verbatim: directory).font(.body.monospaced()).textSelection(.enabled) }
      }
    }
  }
}

private struct UploadDocumentPicker: UIViewControllerRepresentable {
  let onPick: (URL?) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onPick) }
  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
    picker.allowsMultipleSelection = false
    picker.delegate = context.coordinator
    picker.view.accessibilityIdentifier = "terminal.upload.picker"
    return picker
  }
  func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

  final class Coordinator: NSObject, UIDocumentPickerDelegate {
    let completion: (URL?) -> Void
    init(_ completion: @escaping (URL?) -> Void) { self.completion = completion }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
      completion(urls.count == 1 ? urls[0] : nil)
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(nil) }
  }
}
