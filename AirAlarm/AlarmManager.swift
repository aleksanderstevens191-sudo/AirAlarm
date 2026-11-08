import AudioToolbox
import AVFoundation
import MediaPlayer
import UIKit
import UserNotifications

/// Identifiers shared with the notification delegate.
enum AlarmIDs {
    static let notificationCategory = "ALARM"
    static let alarmNotification = "alarm"
    static let stopAction = "STOP"
    static let snoozeAction = "SNOOZE"
}

/// The whole alarm lives here.
///
/// How it works:
/// 1. When the alarm is on, the app plays silent audio that *mixes* with other apps.
///    That keeps the app running in the background all night without stopping your music.
/// 2. At alarm time it checks where audio is going. If headphones/AirPods are connected,
///    it switches to a *non-mixable* audio session (iOS pauses your music) and plays the alarm.
/// 3. If the AirPods aren't connected, it never plays sound. It only vibrates, or does nothing.
/// 4. If the AirPods disconnect while ringing (fall out, battery dies), the sound stops
///    right away so it can't move to the speaker.
@MainActor
final class AlarmManager: ObservableObject {
    static let shared = AlarmManager()

    enum Fallback: String, CaseIterable, Identifiable {
        case vibrate, silent
        var id: String { rawValue }
        var label: String {
            switch self {
            case .vibrate: return "Vibrate only"
            case .silent: return "Do nothing"
            }
        }
    }

    @Published var alarmTime: Date {
        didSet {
            defaults.set(alarmTime.timeIntervalSince1970, forKey: Keys.time)
            if isArmed && !isRinging { scheduleNextFire() }
        }
    }
    @Published var fallback: Fallback {
        didSet { defaults.set(fallback.rawValue, forKey: Keys.fallback) }
    }
    @Published private(set) var isArmed = false
    @Published private(set) var isRinging = false
    @Published private(set) var isSnoozed = false
    @Published private(set) var isTesting = false
    @Published private(set) var nextFireDate: Date?
    @Published private(set) var headphoneName: String?
    @Published private(set) var outputVolume: Float = 0
    @Published private(set) var lastError: String?
    /// True while the alarm sound is actually playing in the headphones.
    @Published private(set) var isPlayingAlarmSound = false

    var headphonesConnected: Bool { headphoneName != nil }
    let snoozeMinutes = 5

    private enum Keys {
        static let time = "alarmTime"
        static let armed = "armed"
        static let fallback = "fallback"
    }

    private static let headphonePorts: Set<AVAudioSession.Port> = [
        .headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP,
    ]

    private let defaults = UserDefaults.standard
    private let session = AVAudioSession.sharedInstance()
    private var keepAlivePlayer: AVAudioPlayer?
    private var alarmPlayer: AVAudioPlayer? {
        didSet { isPlayingAlarmSound = alarmPlayer != nil }
    }
    private var tickTimer: Timer?
    private var vibrateTimer: Timer?
    private var testStopWork: DispatchWorkItem?
    private var volumeObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []

    private init() {
        if let saved = defaults.object(forKey: Keys.time) as? Double {
            alarmTime = Date(timeIntervalSince1970: saved)
        } else {
            alarmTime = Calendar.current.date(bySettingHour: 6, minute: 0, second: 0, of: Date()) ?? Date()
        }
        fallback = Fallback(rawValue: defaults.string(forKey: Keys.fallback) ?? "") ?? .vibrate

        observeSystem()
        refreshRoute()
        if defaults.bool(forKey: Keys.armed) { arm() }
    }

    // MARK: - Public controls

    func arm() {
        lastError = nil
        configureSession(interruptOthers: false)
        startKeepAlive()
        isArmed = true
        defaults.set(true, forKey: Keys.armed)
        scheduleNextFire()
        startTicking()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    func disarm() {
        if isRinging { endRinging() }
        isArmed = false
        isSnoozed = false
        nextFireDate = nil
        defaults.set(false, forKey: Keys.armed)
        tickTimer?.invalidate()
        tickTimer = nil
        keepAlivePlayer?.stop()
        keepAlivePlayer = nil
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [AlarmIDs.alarmNotification])
        if !isTesting {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Stops the alarm. It stays on for the same time tomorrow.
    func stopAlarm() {
        guard isRinging || isSnoozed else { return }
        endRinging()
        if isArmed { scheduleNextFire() }
    }

    func snooze() {
        guard isRinging else { return }
        endRinging()
        nextFireDate = Date().addingTimeInterval(TimeInterval(snoozeMinutes * 60))
        isSnoozed = true
        scheduleNotification()
    }

    /// Plays the alarm for 3 seconds, but only if headphones are connected.
    func testSound() {
        refreshRoute()
        guard !isRinging else { return }
        guard headphonesConnected else {
            lastError = "Connect your AirPods first. The test never plays on the iPhone speaker."
            return
        }
        lastError = nil
        isTesting = true
        startAlarmSound(fadeIn: false)

        testStopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.endTest() }
        }
        testStopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func refreshRoute() {
        let output = session.currentRoute.outputs.first { Self.headphonePorts.contains($0.portType) }
        headphoneName = output?.portName
        outputVolume = session.outputVolume
    }

    // MARK: - Scheduling

    private func scheduleNextFire() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: alarmTime)
        nextFireDate = Calendar.current.nextDate(after: Date(), matching: parts, matchingPolicy: .nextTime)
        isSnoozed = false
        scheduleNotification()
    }

    private func startTicking() {
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func tick() {
        guard isArmed else { return }

        if isRinging {
            // Safety net in case a route-change notification is missed:
            // never let the alarm keep playing once the headphones are gone.
            refreshRoute()
            if !headphonesConnected && alarmPlayer != nil { headphonesLost() }
            return
        }

        // If something (a phone call, Siri) interrupted the silent audio, restart it.
        if keepAlivePlayer?.isPlaying != true && !isTesting {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
            startKeepAlive()
        }

        if let fireDate = nextFireDate, Date() >= fireDate {
            fire()
        }
    }

    // MARK: - Ringing

    private func fire() {
        if isTesting { endTest() }
        isRinging = true
        isSnoozed = false
        refreshRoute()
        if headphonesConnected {
            startAlarmSound(fadeIn: true)
        } else {
            startFallback()
        }
        enableRemoteCommands()
    }

    private func startAlarmSound(fadeIn: Bool) {
        refreshRoute()
        guard headphonesConnected else { headphonesLost(); return }
        stopVibrating()

        // A non-mixable session makes iOS pause whatever music is playing.
        if !configureSession(interruptOthers: true) {
            // If iOS won't let us interrupt, at least turn the music down under the alarm.
            try? session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try? session.setActive(true)
        }

        // Check again after the session change, before any sound plays.
        refreshRoute()
        guard headphonesConnected else { headphonesLost(); return }

        alarmPlayer?.stop()
        let player = try? AVAudioPlayer(data: ToneGenerator.alarmPattern(), fileTypeHint: AVFileType.wav.rawValue)
        player?.numberOfLoops = -1
        player?.volume = fadeIn ? 0.2 : 1.0
        player?.prepareToPlay()
        if player?.play() == true {
            if fadeIn { player?.setVolume(1.0, fadeDuration: 15) }
            alarmPlayer = player
            keepAlivePlayer?.pause()
            setNowPlaying()
        } else {
            lastError = "Couldn't start the alarm sound."
            alarmPlayer = nil
            startKeepAlive()
        }
    }

    /// Runs when the headphones disappear while sound might be playing.
    private func headphonesLost() {
        alarmPlayer?.stop()
        alarmPlayer = nil
        if isTesting { endTest() }
        if isRinging { startFallback() }
    }

    private func startFallback() {
        alarmPlayer?.stop()
        alarmPlayer = nil
        // Keep the app alive with silent audio so we can re-ring if the AirPods come back.
        configureSession(interruptOthers: false)
        startKeepAlive()

        guard fallback == .vibrate, vibrateTimer == nil else { return }
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        let timer = Timer(timeInterval: 1.5, repeats: true) { _ in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
        RunLoop.main.add(timer, forMode: .common)
        vibrateTimer = timer
    }

    private func stopVibrating() {
        vibrateTimer?.invalidate()
        vibrateTimer = nil
    }

    private func endRinging() {
        alarmPlayer?.stop()
        alarmPlayer = nil
        stopVibrating()
        isRinging = false
        disableRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()

        if isArmed {
            // Go back to quiet, mixable background mode for the next alarm.
            startKeepAlive()
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
    }

    private func endTest() {
        testStopWork?.cancel()
        testStopWork = nil
        guard isTesting else { return }
        isTesting = false
        alarmPlayer?.stop()
        alarmPlayer = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if isArmed {
            startKeepAlive()
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        } else {
            // Lets your music app resume after the test.
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - Audio helpers

    @discardableResult
    private func configureSession(interruptOthers: Bool) -> Bool {
        do {
            try session.setCategory(.playback, mode: .default, options: interruptOthers ? [] : [.mixWithOthers])
            try session.setActive(true)
            return true
        } catch {
            lastError = "Audio problem: \(error.localizedDescription)"
            return false
        }
    }

    private func startKeepAlive() {
        if keepAlivePlayer == nil {
            let player = try? AVAudioPlayer(data: ToneGenerator.silence(seconds: 2), fileTypeHint: AVFileType.wav.rawValue)
            player?.numberOfLoops = -1
            player?.prepareToPlay()
            keepAlivePlayer = player
        }
        if keepAlivePlayer?.isPlaying == false {
            keepAlivePlayer?.play()
        }
    }

    // MARK: - AirPods controls (press the stem to snooze while ringing)

    private func enableRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.pauseCommand, center.togglePlayPauseCommand, center.stopCommand] {
            command.removeTarget(nil)
            command.isEnabled = true
            command.addTarget { [weak self] _ in
                MainActor.assumeIsolated { self?.snooze() }
                return .success
            }
        }
    }

    private func disableRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.pauseCommand, center.togglePlayPauseCommand, center.stopCommand] {
            command.removeTarget(nil)
            command.isEnabled = false
        }
    }

    private func setNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: isTesting ? "Alarm test" : "Alarm",
            MPMediaItemPropertyArtist: "AirAlarm",
        ]
    }

    // MARK: - Notifications (always silent, so they never make noise on the speaker)

    private func scheduleNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [AlarmIDs.alarmNotification])
        guard let date = nextFireDate else { return }

        let content = UNMutableNotificationContent()
        content.title = "⏰ Time to get up"
        content.body = "Your alarm is ringing in your AirPods. Press the AirPods stem to snooze."
        content.categoryIdentifier = AlarmIDs.notificationCategory
        content.sound = nil

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        let request = UNNotificationRequest(identifier: AlarmIDs.alarmNotification, content: content, trigger: trigger)
        center.add(request, withCompletionHandler: nil)
    }

    private func warnAppClosed() {
        let content = UNMutableNotificationContent()
        content.title = "Your alarm is OFF"
        content.body = "AirAlarm was closed, so it can't ring. Open the app again and leave it running."
        content.sound = nil
        let request = UNNotificationRequest(identifier: "closed", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: - System events

    private func observeSystem() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleRouteChange() }
        })

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            MainActor.assumeIsolated { self?.handleInterruption(type) }
        })

        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMediaReset() }
        })

        observers.append(center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.isArmed == true { self?.warnAppClosed() }
            }
        })

        volumeObservation = session.observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
            let volume = session.outputVolume
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.outputVolume = volume }
            }
        }
    }

    private func handleRouteChange() {
        refreshRoute()
        guard isRinging || isTesting else { return }
        if headphonesConnected {
            // AirPods came back while the alarm was going off: ring in them again.
            if isRinging && alarmPlayer == nil { startAlarmSound(fadeIn: false) }
        } else {
            headphonesLost()
        }
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        guard type == .ended else { return }
        if isRinging {
            if headphonesConnected { startAlarmSound(fadeIn: false) } else { startFallback() }
        } else if isArmed {
            configureSession(interruptOthers: false)
            startKeepAlive()
        }
    }

    private func handleMediaReset() {
        keepAlivePlayer = nil
        alarmPlayer = nil
        if isRinging {
            if headphonesConnected { startAlarmSound(fadeIn: false) } else { startFallback() }
        } else if isArmed {
            configureSession(interruptOthers: false)
            startKeepAlive()
        }
    }
}
