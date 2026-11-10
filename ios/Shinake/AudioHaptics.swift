import AVFoundation
import UIKit

/// Short synthesized cues. No asset files. `.ambient` follows the mute switch.
final class SoundBank {
    var enabled = true
    private var players: [String: AVAudioPlayer] = [:]
    private var ready = false

    func prepare() {
        guard !ready else { return }
        ready = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, options: [.mixWithOthers])
        try? session.setActive(true)
        players["eat"] = player(tone(from: 520, to: 880, seconds: 0.11, volume: 0.35))
        players["die"] = player(tone(from: 220, to: 70, seconds: 0.32, volume: 0.4))
        players["save"] = player(tone(from: 440, to: 660, seconds: 0.09, volume: 0.28))
        players["ui"] = player(tone(from: 880, to: 880, seconds: 0.04, volume: 0.18))
        players["record"] = player(arpeggio([523, 659, 784], note: 0.09, volume: 0.32))
    }

    func play(_ name: String) {
        guard enabled else { return }
        prepare()
        guard let player = players[name] else { return }
        player.currentTime = 0
        player.play()
    }

    private func player(_ data: Data) -> AVAudioPlayer? {
        let player = try? AVAudioPlayer(data: data)
        player?.prepareToPlay()
        return player
    }
}

final class HapticBank {
    var enabled = true
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let notice = UINotificationFeedbackGenerator()

    func prepare() {
        light.prepare()
        medium.prepare()
        notice.prepare()
    }

    func tap() {
        guard enabled else { return }
        light.impactOccurred(intensity: 0.55)
    }

    func eat() {
        guard enabled else { return }
        notice.notificationOccurred(.success)
    }

    func save() {
        guard enabled else { return }
        notice.notificationOccurred(.warning)
    }

    func die() {
        guard enabled else { return }
        notice.notificationOccurred(.error)
    }

    func record() {
        guard enabled else { return }
        medium.impactOccurred(intensity: 0.9)
        notice.notificationOccurred(.success)
    }
}

private func tone(from start: Double, to end: Double, seconds: Double, volume: Double) -> Data {
    let rate = 22_050
    let count = max(1, Int(seconds * Double(rate)))
    var samples = [Int16](repeating: 0, count: count)
    var phase = 0.0
    for index in 0..<count {
        let t = Double(index) / Double(max(count - 1, 1))
        let frequency = start + (end - start) * t
        phase += frequency / Double(rate)
        let envelope = pow(1 - t, 1.6)
        let value = sin(phase * 2 * Double.pi) * envelope * volume
        samples[index] = Int16(max(-1, min(1, value)) * 32_000)
    }
    return wav(samples: samples, rate: rate)
}

private func arpeggio(_ notes: [Double], note: Double, volume: Double) -> Data {
    let rate = 22_050
    let per = max(1, Int(note * Double(rate)))
    var samples = [Int16]()
    samples.reserveCapacity(per * notes.count)
    for frequency in notes {
        var phase = 0.0
        for index in 0..<per {
            let t = Double(index) / Double(per)
            phase += frequency / Double(rate)
            let envelope = pow(1 - t, 1.2)
            let value = sin(phase * 2 * Double.pi) * envelope * volume
            samples.append(Int16(max(-1, min(1, value)) * 32_000))
        }
    }
    return wav(samples: samples, rate: rate)
}

private func wav(samples: [Int16], rate: Int) -> Data {
    var data = Data()
    let byteCount = samples.count * 2
    data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // RIFF
    data.append(uint32: UInt32(36 + byteCount))
    data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // WAVE
    data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // fmt 
    data.append(uint32: 16)
    data.append(uint16: 1)
    data.append(uint16: 1)
    data.append(uint32: UInt32(rate))
    data.append(uint32: UInt32(rate * 2))
    data.append(uint16: 2)
    data.append(uint16: 16)
    data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // data
    data.append(uint32: UInt32(byteCount))
    for sample in samples {
        data.append(uint16: UInt16(bitPattern: sample))
    }
    return data
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func append(uint32 value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
