import AppKit
import CoreAudio
import OSLog
import UserNotifications
import VantageCore

private let log = Logger(subsystem: "com.venka.vantage", category: "detection")

/// Which other processes are capturing audio right now (CoreAudio process objects, macOS 14.4+).
/// Reads only bundle IDs and a running-input flag — never any audio.
enum MicUsage {
    static func bundleIDs(excludingPID own: pid_t = getpid()) -> [String] {
        users(excludingPID: own).compactMap(\.bundleID)
    }

    static func users(excludingPID own: pid_t = getpid()) -> [(pid: pid_t, bundleID: String?)] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }

        return objects.compactMap { object in
            guard read(object, kAudioProcessPropertyIsRunningInput, as: UInt32.self) == 1,
                  let pid = read(object, kAudioProcessPropertyPID, as: pid_t.self), pid != own else { return nil }
            return (pid, bundleID(of: object))
        }
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as: T.Type) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr ? value.pointee : nil
    }

    private static func bundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let id = value?.takeRetainedValue() as String?, !id.isEmpty else { return nil }
        return id
    }
}

/// Notices when a call app starts using the mic and asks whether to start listening
/// (and, when the call ends, whether to stop). Never starts listening on its own.
@MainActor
final class MeetingDetection: NSObject, UNUserNotificationCenterDelegate {
    private weak var model: AppModel?
    private var detector = MeetingDetector()
    private var timer: Timer?
    private static let startAction = "start", stopAction = "stop"
    private static let startCategory = "call-started", endCategory = "call-ended"

    /// Notifications need a real app bundle; the bare debug binary has none.
    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    init(model: AppModel) {
        self.model = model
        super.init()
        guard Self.available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.startCategory,
                                   actions: [UNNotificationAction(identifier: Self.startAction, title: "Start listening",
                                                                  options: [.foreground])],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.endCategory,
                                   actions: [UNNotificationAction(identifier: Self.stopAction, title: "Stop listening",
                                                                  options: [])],
                                   intentIdentifiers: []),
        ])
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// Follows the Settings toggle.
    func refresh() {
        let on = Self.available && Pref.d.bool(forKey: Pref.detectMeetings)
        if on, timer == nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if !granted { log.notice("notifications not allowed; detection prompts won't show") }
            }
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            log.notice("meeting detection on")
        } else if !on, let t = timer {
            t.invalidate()
            timer = nil
            detector.reset()
            log.notice("meeting detection off")
        }
    }

    private func tick() {
        guard let model else { return }
        let listening = model.phase != .idle
        switch detector.update(micUsers: MicUsage.bundleIDs(), listening: listening) {
        case .none:
            break
        case .started(let app):
            log.notice("call detected: \(app.name, privacy: .public)")
            notify(app.promptTitle, body: "Start listening to take notes? Vantage won't record until you do.",
                   category: Self.startCategory)
        case .ended(let app):
            guard model.isRunning else { return }
            log.notice("call ended: \(app.name, privacy: .public)")
            notify("\(app.name) call ended", body: "Vantage is still listening. Stop and write your notes?",
                   category: Self.endCategory)
        }
    }

    private func notify(_ title: String, body: String, category: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.sound = .default
        // Same identifier per kind: a newer prompt replaces an unanswered one.
        let request = UNNotificationRequest(identifier: category, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        await MainActor.run {
            guard let model = self.model else { return }
            // Clicking the banner itself means "yes" too.
            let start = action == Self.startAction
                || (action == UNNotificationDefaultActionIdentifier && category == Self.startCategory)
            let stop = action == Self.stopAction
            if start {
                NSApp.activate()
                model.showMainWindow?()
                guard model.phase == .idle else { return }
                model.newMeeting()
                model.toggle()
            } else if stop, model.isRunning {
                model.toggle()
            } else if action == UNNotificationDefaultActionIdentifier {
                NSApp.activate()
                model.showMainWindow?()
            }
        }
    }
}
