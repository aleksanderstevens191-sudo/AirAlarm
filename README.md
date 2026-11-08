# AirAlarm ⏰🎧

A simple iPhone alarm that **only rings in your AirPods**, never through the speaker, so you can
get up for the gym without waking your roommate.

- Plays **only** through AirPods or headphones. If they aren't connected, it vibrates (or does nothing). It never uses the speaker.
- **Stops your music** at alarm time. You can fall asleep to music and the alarm takes over.
- If your AirPods fall out or die while it's ringing, the sound **stops right away**, so it can't move to the speaker.
- Fades in gently, then gets louder.
- **Press the AirPods stem** to snooze for 5 minutes. Open the app (or use the notification) to stop.
- Repeats every day until you turn it off.
- Works with the ring/silent switch on silent.

## How to use it each night

1. Open AirAlarm, set your time, and turn **Alarm on**.
2. Put your AirPods in. Tap **Test the alarm sound** once to check the volume.
3. Lock your phone and put it on the charger. **Don't swipe the app away** in the app switcher.

If you do close the app by accident, you'll get a notification saying the alarm is off.

## Why the app has to stay open

iOS doesn't let any app choose where an alarm sound plays. Apple's Clock app, and alarms
made with Apple's AlarmKit, always ring through the speaker. To control the sound, AirAlarm
stays running in the background by playing silent audio that mixes with your music. At alarm
time it checks that headphones are connected, pauses your music, and plays the alarm in your
AirPods. This uses a little battery overnight, so keep the phone charging.

## Install it on your iPhone (free, needs a Mac)

1. Install **Xcode** from the Mac App Store.
2. Download this repo and double-click **`AirAlarm.xcodeproj`**.
3. In Xcode, click **AirAlarm** (blue icon, top left), then **Signing & Capabilities**:
   - **Team**: choose your Apple ID (add it with "Add an Account…" if needed).
   - **Bundle Identifier**: change `com.yourname.AirAlarm` to something unique, like `com.alex.AirAlarm`.
4. Plug in your iPhone, select it at the top of Xcode, and press **▶ Run**.
5. On the iPhone the first time:
   - Turn on **Settings → Privacy & Security → Developer Mode** (the phone restarts).
   - Go to **Settings → General → VPN & Device Management**, tap your Apple ID, and choose **Trust**.
6. Allow notifications when the app asks. They're silent and give you Stop/Snooze buttons on the lock screen.

> With a free Apple ID the app stops opening after **7 days**. Plug in and press Run again to
> renew it. A paid Apple Developer account ($99/yr) makes it last a year.

## Files

| File | What it does |
| --- | --- |
| `AirAlarm/AlarmManager.swift` | Alarm logic: background keep-alive, AirPods check, stopping music, ringing, snooze |
| `AirAlarm/ContentView.swift` | The screens (main screen and the full-screen "ringing" screen) |
| `AirAlarm/ToneGenerator.swift` | Creates the beep and silent audio in code, so no sound files are needed |
| `AirAlarm/AirAlarmApp.swift` | App entry point and the Stop/Snooze notification buttons |
| `AirAlarm/Info.plist` | Turns on background audio so the app can run overnight |
