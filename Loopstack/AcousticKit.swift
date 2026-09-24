import AVFoundation
import Foundation

/// Velocity-layered VCSL one-shots. Layer pick + residual gain + tone + length;
/// velocity is timbre, not a volume knob on one sample.
enum AcousticKit {
  struct Layer {
    var vel: Float
    var takes: [AVAudioPCMBuffer]
  }

  private static var banks: [DrumVoice: [Layer]] = [:]
  private static var rr: [DrumVoice: Int] = [:]
  private static var loaded = false
  private static let lock = NSLock()

  static var isLoaded: Bool {
    lock.lock()
    defer { lock.unlock() }
    return loaded
  }

  static func load() {
    lock.lock()
    if loaded {
      lock.unlock()
      return
    }
    lock.unlock()
    var built: [DrumVoice: [Layer]] = [:]
    func put(_ voice: DrumVoice, _ specs: [(Float, [String])]) {
      var layers: [Layer] = []
      for (vel, names) in specs {
        let takes = names.compactMap { read($0) }
        if !takes.isEmpty { layers.append(Layer(vel: vel, takes: takes)) }
      }
      if !layers.isEmpty { built[voice] = layers }
    }
    put(.kick, [
      (0.28, ["kick_v2"]),
      (0.68, ["kick_v5"]),
      (1.00, ["kick_v7"]),
    ])
    put(.snare, [
      (0.35, ["snare_v3"]),
      (0.68, ["snare_v5", "snare_v5b"]),
      (1.00, ["snare_v7"]),
    ])
    put(.hat, [
      (0.30, ["hat_v1"]),
      (0.62, ["hat_v3"]),
      (1.00, ["hat_v4"]),
    ])
    put(.ohat, [
      (1.00, ["ohat"]),
    ])
    put(.clap, [
      (0.48, ["clap_a", "clap_b"]),
      (1.00, ["clap_c", "clap_b"]),
    ])
    put(.rim, [
      (0.45, ["rim_a"]),
      (1.00, ["rim_b"]),
    ])
    put(.tom, [
      (0.45, ["tom_v2"]),
      (1.00, ["tom_v4"]),
    ])
    put(.perc, [
      (0.40, ["perc_v1"]),
      (1.00, ["perc_v3"]),
    ])
    lock.lock()
    if !loaded {
      banks = built
      loaded = true
    }
    lock.unlock()
  }

  /// Mix one hit. Returns frames written (0 = no sample; caller should analog-fallback).
  @discardableResult
  static func mix(
    _ voice: DrumVoice,
    vel: Float,
    _ L: UnsafeMutablePointer<Float>,
    _ R: UnsafeMutablePointer<Float>,
    _ frames: Int,
    _ sr: Double,
    _ at: Int,
    pan: DrumPan = .center
  ) -> Int {
    if !isLoaded { return 0 }
    let hits = pick(voice, vel: vel)
    guard !hits.isEmpty else { return 0 }
    let trim = levelTrim(voice)
    var written = 0
    for play in hits {
      let n = AudioDSP.mixSample(
        play.buf, L, R, frames, sr, at,
        gain: play.gain * trim,
        pitch: play.pitch,
        tone: play.tone,
        maxSec: play.maxSec,
        pan: pan
      )
      written = max(written, n)
    }
    return written
  }

  /// Per-voice gain so each acoustic voice hits as hard as its electronic counterpart:
  /// matched on punch (the loudest 50 ms of a hit, how loud a drum sounds) at the
  /// velocities that carry a groove, 0.8 and 1.0. A single overall boost would have made
  /// the hats harsh and left rim and perc buried. Soft hits keep the samples' wider
  /// natural dynamics.
  private static func levelTrim(_ voice: DrumVoice) -> Float {
    let dB: Float
    switch voice {
    case .kick: dB = 7.8
    case .snare: dB = 7.5
    case .hat: dB = -0.3
    case .ohat: dB = 1.3
    case .clap: dB = 4.7
    case .rim: dB = 20.7
    case .tom: dB = 12.8
    case .perc: dB = 21.3
    }
    return powf(10, dB / 20)
  }

  private struct Play {
    var buf: AVAudioPCMBuffer
    var gain: Float
    var pitch: Float
    var tone: Float
    var maxSec: Double
  }

  private static func pick(_ voice: DrumVoice, vel: Float) -> [Play] {
    guard let layers = banks[voice], !layers.isEmpty else { return [] }
    let v = max(0.05, min(1, vel))
    let idx = rr[voice, default: 0]
    rr[voice] = idx + 1

    let tone = toneFor(voice, v)
    let pitch = pitchFor(voice, v, idx)
    let maxSec = maxSecFor(voice, v)
    let residual: Float
    if layers.count == 1 {
      residual = 0.36 + 0.64 * pow(v, 1.2)
    } else {
      residual = 0.84 + 0.16 * v
    }

    if layers.count == 1 {
      let take = layers[0].takes[idx % layers[0].takes.count]
      return [Play(buf: take, gain: residual, pitch: pitch, tone: tone, maxSec: maxSec)]
    }

    var lo = 0
    while lo < layers.count - 1, layers[lo].vel < v { lo += 1 }
    if lo > 0, layers[lo].vel > v { lo -= 1 }
    let hi = min(lo + 1, layers.count - 1)
    let a = layers[lo]
    let b = layers[hi]
    let takeA = a.takes[idx % a.takes.count]
    let takeB = b.takes[idx % b.takes.count]
    if hi == lo {
      return [Play(buf: takeA, gain: residual, pitch: pitch, tone: tone, maxSec: maxSec)]
    }
    let span = max(0.0001, b.vel - a.vel)
    let xfade = max(0, min(1, (v - a.vel) / span))
    if xfade < 0.06 {
      return [Play(buf: takeA, gain: residual, pitch: pitch, tone: tone, maxSec: maxSec)]
    }
    if xfade > 0.94 {
      return [Play(buf: takeB, gain: residual, pitch: pitch, tone: tone, maxSec: maxSec)]
    }
    return [
      Play(buf: takeA, gain: residual * (1 - xfade), pitch: pitch, tone: tone, maxSec: maxSec),
      Play(buf: takeB, gain: residual * xfade, pitch: pitch, tone: tone, maxSec: maxSec),
    ]
  }

  private static func toneFor(_ voice: DrumVoice, _ v: Float) -> Float {
    switch voice {
    case .hat: return 0.22 + 0.78 * pow(v, 0.85)
    case .ohat: return 0.35 + 0.65 * v
    case .snare: return 0.28 + 0.72 * v
    case .clap: return 0.20 + 0.80 * v
    case .rim: return 0.30 + 0.70 * v
    case .kick: return 0.45 + 0.55 * v
    case .tom: return 0.32 + 0.68 * v
    case .perc: return 0.25 + 0.75 * v
    }
  }

  private static func pitchFor(_ voice: DrumVoice, _ v: Float, _ idx: Int) -> Float {
    let rrCents = Float((idx * 13 + 7) % 9) - 4
    let velCents: Float
    switch voice {
    case .kick: velCents = (v - 0.7) * 14
    case .tom: velCents = (v - 0.5) * 22
    case .hat, .ohat: velCents = (v - 0.5) * 10
    case .perc: velCents = (v - 0.5) * 18
    default: velCents = (v - 0.5) * 6
    }
    return pow(2, (rrCents + velCents) / 1200)
  }

  private static func maxSecFor(_ voice: DrumVoice, _ v: Double) -> Double {
    switch voice {
    case .kick: return 0.48 + 1.15 * v
    case .snare: return 0.18 + 0.55 * v
    case .hat: return 0.040 + 0.085 * v
    case .ohat: return 0.16 + 0.55 * v
    case .clap: return 0.10 + 0.28 * v
    case .rim: return 0.045 + 0.10 * v
    case .tom: return 0.22 + 0.70 * v
    case .perc: return 0.07 + 0.22 * v
    }
  }

  private static func maxSecFor(_ voice: DrumVoice, _ v: Float) -> Double {
    maxSecFor(voice, Double(v))
  }

  private static func read(_ name: String) -> AVAudioPCMBuffer? {
    let url =
      Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Samples/Acoustic")
      ?? Bundle.main.url(forResource: name, withExtension: "wav")
    guard let url, let file = try? AVAudioFile(forReading: url) else { return nil }
    let frames = AVAudioFrameCount(file.length)
    guard frames > 16 else { return nil }
    guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return nil }
    do {
      try file.read(into: buf)
    } catch {
      return nil
    }
    return trim(buf)
  }

  private static func trim(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
    guard let src = buf.floatChannelData else { return buf }
    let n = Int(buf.frameLength)
    let chs = Int(buf.format.channelCount)
    guard n > 64, chs > 0 else { return buf }
    let th: Float = 0.0014
    var start = 0
    var end = n - 1
    while start < n {
      var p: Float = 0
      for c in 0..<chs { p = max(p, abs(src[c][start])) }
      if p > th { break }
      start += 1
    }
    while end > start {
      var p: Float = 0
      for c in 0..<chs { p = max(p, abs(src[c][end])) }
      if p > th { break }
      end -= 1
    }
    start = max(0, start - 24)
    end = min(n - 1, end + 8)
    let len = max(1, end - start + 1)
    guard let out = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: AVAudioFrameCount(len)) else { return buf }
    out.frameLength = AVAudioFrameCount(len)
    let fadeIn = min(6, len / 8)
    let fadeOut = min(128, len / 6)
    for c in 0..<chs {
      let d = out.floatChannelData![c]
      for i in 0..<len {
        var s = src[c][start + i]
        if i < fadeIn { s *= Float(i) / Float(max(1, fadeIn)) }
        let tail = len - 1 - i
        if tail < fadeOut { s *= Float(tail) / Float(max(1, fadeOut)) }
        d[i] = s
      }
    }
    return out
  }
}
