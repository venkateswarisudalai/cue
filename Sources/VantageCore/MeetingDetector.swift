import Foundation

/// An app that holds calls, recognized by the bundle ID of the process using the microphone.
public struct MeetingApp: Equatable, Sendable {
    public let name: String
    /// Browsers host Meet/Teams/Zoom web calls, but also dictation and other mic use.
    public let isBrowser: Bool

    /// Prefix match, so helper processes count ("com.google.Chrome.helper" → Chrome).
    static let known: [(prefix: String, app: MeetingApp)] = [
        ("us.zoom", MeetingApp(name: "Zoom", isBrowser: false)),
        ("com.microsoft.teams", MeetingApp(name: "Teams", isBrowser: false)),
        ("com.microsoft.teams2", MeetingApp(name: "Teams", isBrowser: false)),  // "new Teams"
        ("com.cisco.webex", MeetingApp(name: "Webex", isBrowser: false)),
        ("com.webex", MeetingApp(name: "Webex", isBrowser: false)),
        ("com.apple.FaceTime", MeetingApp(name: "FaceTime", isBrowser: false)),
        ("com.tinyspeck.slackmacgap", MeetingApp(name: "Slack", isBrowser: false)),
        ("com.hnc.Discord", MeetingApp(name: "Discord", isBrowser: false)),
        ("net.whatsapp.WhatsApp", MeetingApp(name: "WhatsApp", isBrowser: false)),
        ("com.skype", MeetingApp(name: "Skype", isBrowser: false)),
        ("com.google.Chrome", MeetingApp(name: "Chrome", isBrowser: true)),
        ("com.apple.Safari", MeetingApp(name: "Safari", isBrowser: true)),
        // Safari captures the mic from its WebKit GPU process.
        ("com.apple.WebKit.GPU", MeetingApp(name: "Safari", isBrowser: true)),
        ("company.thebrowser", MeetingApp(name: "Arc", isBrowser: true)),
        ("com.microsoft.edgemac", MeetingApp(name: "Edge", isBrowser: true)),
        ("org.mozilla.firefox", MeetingApp(name: "Firefox", isBrowser: true)),
        ("com.brave.Browser", MeetingApp(name: "Brave", isBrowser: true)),
    ]

    public static func from(bundleID: String) -> MeetingApp? {
        known.first { bundleID == $0.prefix || bundleID.hasPrefix($0.prefix + ".") }?.app
    }

    /// Notification wording: "Zoom call detected", "Call detected in Chrome".
    public var promptTitle: String {
        isBrowser ? "Call detected in \(name)" : "\(name) call detected"
    }
}

/// Decides when to offer "Start listening?" and "Stop listening?" from which apps are using the mic.
///
/// A call app must hold the mic for `confirmDelay` before prompting (a quick mic check isn't a
/// call), each call prompts once, and a call ends after the mic has been free for `endDelay`
/// (apps briefly release it when you switch devices or mute).
public struct MeetingDetector: Sendable {
    public enum Event: Equatable, Sendable {
        case none
        case started(MeetingApp)
        /// The call that was prompted for has ended.
        case ended(MeetingApp)
    }

    public var confirmDelay: TimeInterval
    public var endDelay: TimeInterval
    private var call: (app: MeetingApp, since: Date, lastSeen: Date, prompted: Bool)?

    public init(confirmDelay: TimeInterval = 3, endDelay: TimeInterval = 12) {
        self.confirmDelay = confirmDelay
        self.endDelay = endDelay
    }

    /// `micUsers` are bundle IDs of other processes capturing audio right now.
    public mutating func update(micUsers: [String], listening: Bool, now: Date = Date()) -> Event {
        let app = micUsers.lazy.compactMap(MeetingApp.from(bundleID:)).first
        if let app {
            if var c = call {
                c.lastSeen = now
                if listening { c.prompted = true }  // already listening: nothing to offer
                call = c
            } else {
                call = (app, now, now, listening)
            }
            guard var c = call, !c.prompted, now.timeIntervalSince(c.since) >= confirmDelay else { return .none }
            c.prompted = true
            call = c
            return .started(c.app)
        }
        guard let c = call, now.timeIntervalSince(c.lastSeen) >= endDelay else { return .none }
        call = nil
        return c.prompted ? .ended(c.app) : .none
    }

    public mutating func reset() { call = nil }
}
