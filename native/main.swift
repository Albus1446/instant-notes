// iphone-capture — macOS helper used by the "iPhone Camera" VS Code extension.
//
// Modes:
//   --mode continuity  Pops the system Continuity Camera menu ("Take Photo" on your iPhone).
//                      The iPhone camera opens on the phone; tap the shutter, then "Use Photo".
//   --mode webcam      Takes a picture immediately with the iPhone used as a Continuity
//                      webcam (phone must be mounted/nearby, locked, screen facing away).
//   --convert <in>     Convert an existing image file (e.g. HEIC) to JPEG and exit.
//
// Common options:
//   --out <dir>        Output directory (required for capture modes)
//   --name <base>      File base name without extension (default IMG_yyyyMMdd_HHmmss)
//   --quality <0..1>   JPEG quality (default 0.92)
//   --keep-original    Also keep the original HEIC next to the JPEG
//   --timeout <sec>    Give up after this many seconds (default 180)
//
// Result: one JSON line on stdout. Exit 0 = saved, 2 = cancelled/timeout, 1 = error.

import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Arguments

struct Options {
    var mode = "continuity"
    var outDir: String?
    var name: String?
    var quality: Double = 0.92
    var keepOriginal = false
    var timeout: Double = 180
    var convertInput: String?
    var resultFile: String?
    var device: String?
}

func parseArgs() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--mode": o.mode = it.next() ?? o.mode
        case "--out": o.outDir = it.next()
        case "--name": o.name = it.next()
        case "--quality": o.quality = Double(it.next() ?? "") ?? o.quality
        case "--keep-original": o.keepOriginal = true
        case "--timeout": o.timeout = Double(it.next() ?? "") ?? o.timeout
        case "--convert": o.convertInput = it.next()
        case "--result": o.resultFile = it.next()
        case "--device": o.device = it.next()
        default: break
        }
    }
    return o
}

let opts = parseArgs()

// MARK: - Output helpers

func emit(_ dict: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: dict),
       let s = String(data: data, encoding: .utf8) {
        print(s)
        fflush(stdout)
        // When launched through LaunchServices (`open`), stdout isn't ours — use a file.
        if let rf = opts.resultFile { try? data.write(to: URL(fileURLWithPath: rf)) }
    }
}

func finish(ok: Bool, code: Int32, _ extra: [String: Any] = [:]) -> Never {
    var d = extra
    d["ok"] = ok
    emit(d)
    exit(code)
}

func fail(_ msg: String) -> Never { finish(ok: false, code: 1, ["error": msg]) }
func cancel(_ msg: String) -> Never { finish(ok: false, code: 2, ["cancelled": true, "error": msg]) }

func defaultBaseName() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd_HHmmss"
    return "IMG_" + f.string(from: Date())
}

/// Returns a path in `dir` named `base.ext`, adding -1, -2… if it already exists.
func uniquePath(dir: String, base: String, ext: String) -> String {
    let fm = FileManager.default
    var candidate = (dir as NSString).appendingPathComponent("\(base).\(ext)")
    var i = 1
    while fm.fileExists(atPath: candidate) {
        candidate = (dir as NSString).appendingPathComponent("\(base)-\(i).\(ext)")
        i += 1
    }
    return candidate
}

// MARK: - Saving / HEIC → JPEG

enum SaveError: Error, CustomStringConvertible {
    case unreadable, encodeFailed, writeFailed(String)
    var description: String {
        switch self {
        case .unreadable: return "无法识别图片数据"
        case .encodeFailed: return "JPEG 编码失败"
        case .writeFailed(let p): return "写入文件失败: \(p)"
        }
    }
}

/// Writes image `data` into `dir`. JPEG is written byte-for-byte; anything else
/// (HEIC/HEIF/PNG/TIFF…) is re-encoded to JPEG, keeping EXIF/GPS and orientation.
func saveImage(data: Data, dir: String, base: String, quality: Double, keepOriginal: Bool) throws -> [String: Any] {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetCount(src) > 0,
          let typeId = CGImageSourceGetType(src) as String? else { throw SaveError.unreadable }

    let srcType = UTType(typeId)
    let isJPEG = srcType?.conforms(to: .jpeg) ?? false
    let srcExt = srcType?.preferredFilenameExtension ?? "img"
    var result: [String: Any] = ["originalFormat": srcExt]

    let jpgPath = uniquePath(dir: dir, base: base, ext: "jpg")

    if isJPEG {
        guard FileManager.default.createFile(atPath: jpgPath, contents: data) else { throw SaveError.writeFailed(jpgPath) }
        result["converted"] = false
    } else {
        try convertToJPEG(source: src, to: jpgPath, quality: quality)
        result["converted"] = true
        if keepOriginal {
            let origPath = uniquePath(dir: dir, base: base, ext: srcExt)
            if FileManager.default.createFile(atPath: origPath, contents: data) {
                result["originalPath"] = origPath
            }
        }
    }
    result["path"] = jpgPath
    return result
}

func convertToJPEG(source src: CGImageSource, to path: String, quality: Double) throws {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw SaveError.encodeFailed
    }
    // AddImageFromSource carries over metadata (EXIF, GPS, orientation) from the HEIC.
    let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
    CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw SaveError.encodeFailed }
}

func handleCaptured(data: Data) -> Never {
    guard let dir = opts.outDir else { fail("缺少 --out 参数") }
    do {
        let r = try saveImage(data: data, dir: dir, base: opts.name ?? defaultBaseName(),
                              quality: opts.quality, keepOriginal: opts.keepOriginal)
        finish(ok: true, code: 0, r)
    } catch {
        fail("\(error)")
    }
}

// MARK: - Convert-only mode

if let input = opts.convertInput {
    let inURL = URL(fileURLWithPath: input)
    guard let data = try? Data(contentsOf: inURL) else { fail("无法读取 \(input)") }
    let dir = opts.outDir ?? inURL.deletingLastPathComponent().path
    let base = opts.name ?? inURL.deletingPathExtension().lastPathComponent
    do {
        let r = try saveImage(data: data, dir: dir, base: base, quality: opts.quality, keepOriginal: false)
        finish(ok: true, code: 0, r)
    } catch { fail("\(error)") }
}

guard let outDir = opts.outDir else { fail("缺少 --out 参数") }
var isDir: ObjCBool = false
guard FileManager.default.fileExists(atPath: outDir, isDirectory: &isDir), isDir.boolValue else {
    fail("输出目录不存在: \(outDir)")
}

// MARK: - Continuity Camera mode (photo taken on the iPhone)

/// A view that tells AppKit it can receive images, which makes the system fill the
/// "Import from iPhone" menu item with "Take Photo / Scan Documents / Add Sketch".
final class ReceiverView: NSView, NSServicesMenuRequestor {
    override var acceptsFirstResponder: Bool { true }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if let rt = returnType, NSImage.imageTypes.contains(rt.rawValue) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }

    func readSelection(from pboard: NSPasteboard) -> Bool {
        // Prefer the camera's native encodings so no quality is lost before conversion.
        let preferred: [NSPasteboard.PasteboardType] = [
            .init(UTType.heic.identifier), .init(UTType.heif.identifier),
            .init(UTType.jpeg.identifier), .png, .tiff,
        ]
        let available = pboard.types ?? []
        for t in preferred + available where available.contains(t) {
            if let d = pboard.data(forType: t),
               CGImageSourceCreateWithData(d as CFData, nil).map({ CGImageSourceGetCount($0) > 0 }) == true {
                DispatchQueue.main.async { handleCaptured(data: d) }
                return true
            }
        }
        if let img = NSImage(pasteboard: pboard), let tiff = img.tiffRepresentation {
            DispatchQueue.main.async { handleCaptured(data: tiff) }
            return true
        }
        DispatchQueue.main.async { fail("收到的数据不是图片") }
        return false
    }
}

final class ContinuityController: NSObject, NSWindowDelegate {
    let window: NSPanel
    let receiver: ReceiverView
    let status = NSTextField(labelWithString: "")

    /// The Continuity Camera item only gets populated with devices when it lives in the
    /// app's main menu (a pop-up menu stays greyed out), so we keep one there, hidden.
    let importItem = NSMenuItem(title: "Import from iPhone", action: nil, keyEquivalent: "")
    var attempts = 0

    override init() {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 130),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        receiver = ReceiverView(frame: window.contentView!.bounds)
        super.init()

        window.title = "iPhone 拍照"
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        receiver.autoresizingMask = [.width, .height]
        window.contentView = receiver

        status.stringValue = "正在连接 iPhone…"
        status.alignment = .center
        status.frame = NSRect(x: 16, y: 70, width: 308, height: 44)
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 2
        receiver.addSubview(status)

        let again = NSButton(title: "重新拍照", target: self, action: #selector(retake))
        again.bezelStyle = .rounded
        again.frame = NSRect(x: 30, y: 20, width: 170, height: 32)
        receiver.addSubview(again)

        let cancelBtn = NSButton(title: "取消", target: self, action: #selector(doCancel))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"
        cancelBtn.frame = NSRect(x: 210, y: 20, width: 100, height: 32)
        receiver.addSubview(cancelBtn)

        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "iPhone 拍照")
        main.addItem(appItem)
        let fileMenu = NSMenu(title: "File")
        importItem.identifier = NSMenuItem.importFromDeviceIdentifier
        fileMenu.addItem(importItem)
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)
        NSApp.mainMenu = main
    }

    func start() {
        // Place the panel near the mouse so the Continuity popover appears where the user looks.
        let m = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.main
        var origin = NSPoint(x: m.x - 170, y: m.y - 150)
        if let vf = screen?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX), vf.maxX - 340)
            origin.y = min(max(origin.y, vf.minY), vf.maxY - 160)
        }
        window.setFrameOrigin(origin)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(receiver)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.takePhoto() }
    }

    @objc func retake() { attempts = 0; takePhoto() }

    /// Devices in the import submenu: [header (disabled)] Take Photo, Scan Documents, Add Sketch, separator, …
    func listDevices() -> [(name: String, takePhotoIndex: Int)] {
        var devices: [(name: String, takePhotoIndex: Int)] = []
        guard let sub = importItem.submenu else { return devices }
        var header: String?
        for (i, it) in sub.items.enumerated() {
            if it.isSeparatorItem || it.title.isEmpty { header = nil; continue }
            if !it.isEnabled { header = it.title.trimmingCharacters(in: .whitespaces); continue }
            if let h = header { devices.append((h, i)); header = nil }
        }
        return devices
    }

    /// AppKit only fills the import submenu while its menu is being tracked, so open the
    /// (otherwise hidden) File menu for a moment, wait for devices to appear, then close it.
    func populateDevices() {
        guard let fileMenu = importItem.menu else { return }
        var ticks = 0
        let timer = Timer(timeInterval: 0.1, repeats: true) { t in
            ticks += 1
            if !self.listDevices().isEmpty || ticks >= 30 {
                t.invalidate()
                fileMenu.cancelTrackingWithoutAnimation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fileMenu.popUp(positioning: nil, at: NSPoint(x: 30, y: 20), in: receiver)
        timer.invalidate()
    }

    /// Finds the iPhone and fires its "Take Photo" action — no menu clicking needed.
    func takePhoto() {
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(receiver)

        var devices = listDevices()
        if devices.isEmpty {
            populateDevices()
            devices = listDevices()
        }
        if ProcessInfo.processInfo.environment["IC_DEBUG"] != nil {
            FileHandle.standardError.write("attempt \(attempts) active=\(NSApp.isActive) devices=\(devices.map { $0.name })\n".data(using: .utf8)!)
        }

        guard !devices.isEmpty, let sub = importItem.submenu else {
            attempts += 1
            if attempts < 6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.takePhoto() }
            } else {
                status.stringValue = "没有找到可用的 iPhone。\n请解锁手机并靠近 Mac，然后点「重新拍照」"
            }
            return
        }

        let wanted = opts.device?.trimmingCharacters(in: .whitespaces) ?? ""
        let device = devices.first { !wanted.isEmpty && $0.name.localizedCaseInsensitiveContains(wanted) } ?? devices[0]
        sub.performActionForItem(at: device.takePhotoIndex)
        status.stringValue = "已在「\(device.name)」上打开相机\n拍完后在手机上点「使用照片」"
    }

    @objc func doCancel() { cancel("用户取消") }
    func windowWillClose(_ notification: Notification) { cancel("用户关闭窗口") }
}

// MARK: - Webcam mode (iPhone as Continuity webcam, shoots instantly)

final class WebcamController: NSObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    let output = AVCapturePhotoOutput()

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    if ok { self.configure() } else { fail("未获得摄像头权限") }
                }
            }
        default:
            fail("摄像头权限被拒绝：请在 系统设置 → 隐私与安全性 → 摄像头 中允许 VS Code")
        }
    }

    func findIPhone() -> AVCaptureDevice? {
        let ds = AVCaptureDevice.DiscoverySession(deviceTypes: [.continuityCamera, .external],
                                                  mediaType: .video, position: .unspecified)
        return ds.devices.first { $0.deviceType == .continuityCamera }
            ?? ds.devices.first { $0.localizedName.localizedCaseInsensitiveContains("iPhone") }
    }

    func configure() {
        guard let device = findIPhone() else {
            fail("没有找到 iPhone 连续互通摄像头。请确认 iPhone 已锁屏、靠近 Mac、登录同一 Apple ID，并开启 Wi-Fi/蓝牙")
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            session.sessionPreset = .photo
            guard session.canAddInput(input), session.canAddOutput(output) else { fail("无法配置拍摄会话") }
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()
        } catch { fail("打开 iPhone 摄像头失败: \(error.localizedDescription)") }

        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
            // Give auto-exposure / focus a moment to settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.shoot() }
        }
    }

    func shoot() {
        let codecs = output.availablePhotoCodecTypes
        let codec: AVVideoCodecType = codecs.contains(.hevc) ? .hevc : .jpeg
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
        output.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { fail("拍摄失败: \(error.localizedDescription)") }
        guard let data = photo.fileDataRepresentation() else { fail("拍摄失败：没有图像数据") }
        session.stopRunning()
        handleCaptured(data: data)
    }
}

// MARK: - Run

if let rf = opts.resultFile {
    try? String(getpid()).write(toFile: rf + ".pid", atomically: true, encoding: .utf8)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// Without this, AppKit never asks our view for images and the
// "Import from iPhone" item stays greyed out with no devices listed.
app.registerServicesMenuSendTypes([], returnTypes: NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) })

DispatchQueue.main.asyncAfter(deadline: .now() + opts.timeout) { cancel("等待超时") }
signal(SIGTERM) { _ in exit(2) }

var continuity: ContinuityController?
var webcam: WebcamController?

switch opts.mode {
case "webcam":
    webcam = WebcamController()
    DispatchQueue.main.async { webcam!.start() }
case "continuity":
    continuity = ContinuityController()
    DispatchQueue.main.async { continuity!.start() }
default:
    fail("未知模式: \(opts.mode)")
}

app.run()
