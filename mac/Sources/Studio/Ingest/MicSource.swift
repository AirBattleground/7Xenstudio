// Microphone capture (AVCaptureSession audio) feeding AudioMixer's always-on "mic" input.
// Handles the permission prompt (only when the bundle carries NSMicrophoneUsageDescription: a bare `swift run`
// binary would be killed by TCC), device selection by CoreAudio UID and device removal.
import Foundation
import AVFoundation
import CoreMedia

final class MicSource: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Status: Equatable {
        case idle
        case running(String)
        case denied            // user refused (or restricted): needs System Settings
        case needsPermission   // not asked yet
        case noDevice(String)
        case failed(String)
        var text: String {
            switch self {
            case .idle: "Mic off"
            case .running(let n): n
            case .denied: "Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone."
            case .needsPermission: "Microphone permission needed"
            case .noDevice(let s): s
            case .failed(let s): s
            }
        }
        var isRunning: Bool { if case .running = self { return true } else { return false } }
    }

    private let mixer: AudioMixer
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "mic.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []
    /// Called on the main queue when the status changes (including unexpected runtime errors).
    var onStatus: (@Sendable (Status) -> Void)?
    private(set) var status: Status = .idle

    init(mixer: AudioMixer) { self.mixer = mixer }
    deinit { stop() }

    /// False for unbundled binaries (swift run / tests): requesting access there crashes the process.
    static var canPrompt: Bool { Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil }
    static var authorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestAccess(_ done: @escaping @Sendable (Bool) -> Void) {
        switch authorization {
        case .authorized: done(true)
        case .notDetermined:
            guard canPrompt else { done(false); return }
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    /// Starts capturing from the device with this CoreAudio UID (nil = system default input). Returns the new status.
    @discardableResult
    func start(deviceUID: String?) -> Status {
        stop()
        switch Self.authorization {
        case .authorized: break
        case .notDetermined: return set(.needsPermission)
        default: return set(.denied)
        }
        let dev: AVCaptureDevice?
        if let uid = deviceUID { dev = AVCaptureDevice(uniqueID: uid) } else { dev = AVCaptureDevice.default(for: .audio) }
        guard let dev else { return set(.noDevice(deviceUID == nil ? "No microphone found" : "Selected microphone is not connected")) }
        let s = AVCaptureSession()
        let out = AVCaptureAudioDataOutput()
        out.setSampleBufferDelegate(self, queue: queue)
        do {
            let input = try AVCaptureDeviceInput(device: dev)
            s.beginConfiguration()
            guard s.canAddInput(input), s.canAddOutput(out) else { s.commitConfiguration(); return set(.failed("Cannot capture from \(dev.localizedName)")) }
            s.addInput(input); s.addOutput(out)
            s.commitConfiguration()
        } catch { return set(.failed("\(dev.localizedName): \(error.localizedDescription)")) }
        lock.lock(); session = s; lock.unlock()
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: s, queue: .main) { [weak self] n in
                let e = (n.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "capture error"
                self?.stop(); _ = self?.set(.failed("Microphone stopped: \(e)"))
            },
            nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: dev, queue: .main) { [weak self] _ in
                self?.stop(); _ = self?.set(.noDevice("Microphone disconnected"))
            },
        ]
        let name = dev.localizedName
        queue.async { s.startRunning() }
        return set(.running(name))
    }

    func stop() {
        lock.lock(); let s = session; session = nil; lock.unlock()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        if let s { queue.async { s.stopRunning(); for o in s.outputs { (o as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil) } } }
        if status.isRunning { _ = set(.idle) }
    }

    @discardableResult
    private func set(_ s: Status) -> Status {
        status = s
        let cb = onStatus
        DispatchQueue.main.async { cb?(s) }
        return s
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        mixer.push(id: AudioMixer.micID, sampleBuffer: sampleBuffer)
    }
}
