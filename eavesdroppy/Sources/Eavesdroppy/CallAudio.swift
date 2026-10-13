import CoreAudio
import Darwin
import Foundation

// Which processes are using the microphone, and a watcher for "the default input started running" (D12, D13).
// Foundation + Core Audio only, so it compiles outside the droplet for tests. Every call here can block for a moment
// on a wedged HAL: call it off the main thread.

/// Call apps and browsers, matched by bundle-id prefix. Audio is often owned by a helper process (Chrome's
/// `com.google.Chrome.helper`, Teams' `...teams2.modulehost`, Safari's `com.apple.WebKit.GPU`), so a prefix is the match.
/// ponytail: a fixed list; add an id when a call app is missed. `com.apple.WebKit.GPU` is shared by every WebKit
/// app, so any of them using the mic counts as a call.
enum CallApps {
    static let prefixes: [(prefix: String, name: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams", "Teams"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.apple.FaceTime", "FaceTime"), ("com.apple.avconferenced", "FaceTime"),
        ("com.cisco.webexmeetingsapp", "Webex"), ("Cisco-Systems.Spark", "Webex"), ("com.webex.meetingmanager", "Webex"),
        ("com.hnc.Discord", "Discord"),
        ("com.google.Chrome", "Chrome"), ("com.apple.Safari", "Safari"), ("com.apple.WebKit.GPU", "Safari"),
        ("company.thebrowser.Browser", "Arc"), ("com.microsoft.edgemac", "Edge"), ("org.mozilla.firefox", "Firefox"),
        ("com.brave.Browser", "Brave"), ("at.studio.AsideBrowser", "Aside"),
    ]

    /// The display name of the call app a bundle id belongs to, or nil.
    static func name(forBundleID id: String) -> String? {
        prefixes.first { id.hasPrefix($0.prefix) }?.name
    }

    /// Bundle ids of the apps whose windows hold a meeting's participant list (item 7), for the Accessibility reader.
    static let participantApps: [String] = ["us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams",
                                            "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
                                            "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox"]
}

struct InputProcess: Equatable { var pid: pid_t; var bundleID: String }

enum CallAudio {
    private static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T) -> T? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v = initial, size = UInt32(MemoryLayout<T>.size)
        let err = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, UnsafeMutableRawPointer($0)) }
        return err == noErr ? v : nil
    }

    static func defaultInputDevice() -> AudioObjectID {
        get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, AudioObjectID(kAudioObjectUnknown)) ?? AudioObjectID(kAudioObjectUnknown)
    }

    /// Whether any process is capturing from the default input device.
    static func defaultInputRunning() -> Bool {
        let dev = defaultInputDevice()
        return dev != kAudioObjectUnknown && (get(dev, kAudioDevicePropertyDeviceIsRunningSomewhere, UInt32(0)) ?? 0) != 0
    }

    /// Every process Core Audio knows that currently runs input (macOS 14.2+; empty before that).
    static func processesRunningInput() -> [InputProcess] {
        guard #available(macOS 14.2, *) else { return [] }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size >= 4 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        var out: [InputProcess] = []
        for id in ids {
            guard (get(id, kAudioProcessPropertyIsRunningInput, UInt32(0)) ?? 0) != 0,
                  let pid = get(id, kAudioProcessPropertyPID, pid_t(0)) else { continue }
            let cf: CFString? = get(id, kAudioProcessPropertyBundleID, "" as CFString)
            var bundle = (cf as String?) ?? ""
            if bundle.isEmpty { bundle = appBundleID(pid: pid) ?? "" }
            out.append(InputProcess(pid: pid, bundleID: bundle))
        }
        return out
    }

    /// Core Audio leaves some bundle ids empty: fall back to the outermost .app of the executable.
    private static func appBundleID(pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let path = String(cString: buf)
        guard let r = path.range(of: ".app/") else { return nil }
        return Bundle(path: String(path[..<r.lowerBound]) + ".app")?.bundleIdentifier
    }

    /// Names of the call apps running input, never counting this process (Droppy's own recorder, dictation, enrollment).
    static func callAppsRunningInput(excludingPID own: pid_t = getpid()) -> [String] {
        var seen: [String] = []
        for p in processesRunningInput() where p.pid != own {
            if let n = CallApps.name(forBundleID: p.bundleID), !seen.contains(n) { seen.append(n) }
        }
        return seen
    }
}

/// Calls `onChange(running)` (on its own queue) whenever the default input device starts or stops being used by
/// anyone, and once on start with the current state. Re-attaches when the default input device changes.
final class MicWatcher: @unchecked Sendable {
    private let q = DispatchQueue(label: "eavesdroppy.micwatch", qos: .utility)
    private let lock = NSLock()
    private var active = false
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceBlock: AudioObjectPropertyListenerBlock?
    private var systemBlock: AudioObjectPropertyListenerBlock?
    private var onChange: ((Bool) -> Void)?

    private static let runningAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private static let defaultAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    private var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }

    func start(_ onChange: @escaping (Bool) -> Void) {
        lock.lock(); let was = active; active = true; lock.unlock()
        guard !was else { return }
        q.async { [self] in
            self.onChange = onChange
            var addr = Self.defaultAddr
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.q.async { self?.attach() } }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, q, block) == noErr { systemBlock = block }
            attach()
        }
    }

    /// Listeners are removed asynchronously; callbacks that race with it are dropped by `active`.
    func stop() {
        lock.lock(); active = false; lock.unlock()
        q.async { [self] in
            detach()
            if let b = systemBlock {
                var addr = Self.defaultAddr
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, q, b)
                systemBlock = nil
            }
            onChange = nil
        }
    }

    private func detach() {
        if let b = deviceBlock, device != kAudioObjectUnknown {
            var addr = Self.runningAddr
            AudioObjectRemovePropertyListenerBlock(device, &addr, q, b)
        }
        deviceBlock = nil; device = AudioObjectID(kAudioObjectUnknown)
    }

    /// q only: (re)attach to the current default input and report its state.
    private func attach() {
        guard isActive else { return }
        detach()
        let dev = CallAudio.defaultInputDevice()
        if dev != kAudioObjectUnknown {
            var addr = Self.runningAddr
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, self.isActive else { return }
                self.onChange?(CallAudio.defaultInputRunning())
            }
            if AudioObjectAddPropertyListenerBlock(dev, &addr, q, block) == noErr { device = dev; deviceBlock = block }
        }
        onChange?(CallAudio.defaultInputRunning())
    }
}
