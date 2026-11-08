import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var alarm: AlarmManager
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                alarmSection
                airPodsSection
                fallbackSection
                tipsSection
                if let error = alarm.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("AirAlarm")
        }
        .fullScreenCover(isPresented: Binding(get: { alarm.isRinging }, set: { _ in })) {
            RingingView()
                .environmentObject(alarm)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { alarm.refreshRoute() }
        }
    }

    private var alarmSection: some View {
        Section {
            DatePicker("Wake up at", selection: $alarm.alarmTime, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)

            Toggle(isOn: Binding(get: { alarm.isArmed }, set: { $0 ? alarm.arm() : alarm.disarm() })) {
                Text("Alarm on").font(.headline)
            }
            .tint(.green)

            if let next = alarm.nextFireDate {
                HStack {
                    Image(systemName: alarm.isSnoozed ? "zzz" : "alarm")
                    Text("\(alarm.isSnoozed ? "Snoozed until" : "Rings") \(next, format: .dateTime.weekday(.wide).hour().minute())")
                }
                .foregroundStyle(.secondary)
            }
        } footer: {
            Text("The alarm repeats every day until you turn it off.")
        }
    }

    private var airPodsSection: some View {
        Section("AirPods") {
            if let name = alarm.headphoneName {
                Label(name, systemImage: "airpods")
                    .foregroundStyle(.green)
            } else {
                Label("Not connected", systemImage: "airpods")
                    .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Volume")
                    Spacer()
                    Text("\(Int(alarm.outputVolume * 100))%").monospacedDigit()
                }
                ProgressView(value: Double(alarm.outputVolume))
                    .tint(alarm.outputVolume < 0.3 ? .orange : .accentColor)
                if alarm.outputVolume < 0.3 && alarm.headphonesConnected {
                    Text("Turn the volume up with the side buttons so the alarm wakes you.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Button {
                alarm.testSound()
            } label: {
                Label(alarm.isTesting ? "Playing in AirPods…" : "Test the alarm sound (3 sec)",
                      systemImage: "speaker.wave.2")
            }
            .disabled(alarm.isTesting || alarm.isRinging)
        }
    }

    private var fallbackSection: some View {
        Section {
            Picker("If AirPods aren't connected", selection: $alarm.fallback) {
                ForEach(AlarmManager.Fallback.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
        } footer: {
            Text("The alarm never plays through the iPhone speaker. If your AirPods fall out or die while it's ringing, the sound stops right away.")
        }
    }

    private var tipsSection: some View {
        Section("Before bed") {
            tip("Turn the alarm on, then just lock your phone.", icon: "lock")
            tip("Don't swipe AirAlarm away in the app switcher, or it can't ring.", icon: "xmark.app")
            tip("Put the phone on the charger. Running all night uses some battery.", icon: "battery.100.bolt")
            tip("Charge your AirPods and keep at least one in your ear.", icon: "airpods")
            tip("Music can play while you fall asleep. The alarm pauses it.", icon: "music.note")
        }
    }

    private func tip(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline)
    }
}

struct RingingView: View {
    @EnvironmentObject private var alarm: AlarmManager

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Text(Date(), style: .time)
                    .font(.system(size: 72, weight: .thin, design: .rounded))
                    .foregroundStyle(.white)
                Text("Time to hit the gym 💪")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)

                Label(alarm.isPlayingAlarmSound ? "Ringing in your AirPods"
                                                : "AirPods not connected. Sound is off.",
                      systemImage: alarm.isPlayingAlarmSound ? "airpods" : "speaker.slash")
                    .foregroundStyle(alarm.isPlayingAlarmSound ? .green : .orange)

                Spacer()

                Button {
                    alarm.snooze()
                } label: {
                    Text("Snooze \(alarm.snoozeMinutes) min")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
                .buttonStyle(.bordered)
                .tint(.white)

                Button {
                    alarm.stopAlarm()
                } label: {
                    Text("Stop")
                        .font(.title2.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 72)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .padding(24)
        }
    }
}
