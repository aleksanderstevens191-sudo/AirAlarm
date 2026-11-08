import Foundation

/// Builds the app's audio in memory (16-bit mono WAV), so no sound files are needed.
enum ToneGenerator {
    static let sampleRate = 44_100

    /// Pure silence. Looped all night so iOS keeps the app alive in the background.
    static func silence(seconds: Double) -> Data {
        wav(samples: [Int16](repeating: 0, count: Int(seconds * Double(sampleRate))))
    }

    /// A "beep-beep-beep-beep ... pause" pattern, about 1.6 seconds long, meant to be looped.
    static func alarmPattern() -> Data {
        let rate = Double(sampleRate)
        var samples = [Int16](repeating: 0, count: Int(1.6 * rate))

        let beepLength = 0.12
        let gap = 0.08
        let frequencies: [Double] = [880, 1175, 880, 1175]
        let length = Int(beepLength * rate)
        let fade = Int(0.005 * rate) // 5 ms fade in/out avoids clicks

        for (index, frequency) in frequencies.enumerated() {
            let start = Int(Double(index) * (beepLength + gap) * rate)
            for n in 0..<length {
                var envelope = 1.0
                if n < fade {
                    envelope = Double(n) / Double(fade)
                } else if n > length - fade {
                    envelope = Double(length - n) / Double(fade)
                }
                let t = Double(n) / rate
                let value = sin(2 * .pi * frequency * t) * envelope * 0.7
                samples[start + n] = Int16(value * Double(Int16.max))
            }
        }
        return wav(samples: samples)
    }

    private static func wav(samples: [Int16]) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let dataSize = UInt32(samples.count * MemoryLayout<Int16>.size)

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))               // fmt chunk size
        append(UInt16(1))                // PCM
        append(UInt16(1))                // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))   // byte rate
        append(UInt16(2))                // block align
        append(UInt16(16))               // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        for sample in samples { append(sample) }
        return data
    }
}
