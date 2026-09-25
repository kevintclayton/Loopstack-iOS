import AVFoundation
import Foundation

/// Which set of recorded one-shots a sample kit plays. All VCSL (CC0).
enum SampleKit: String, CaseIterable {
  /// The original kit: Bass Drum 1, Snare Modern 1, low tom.
  case acoustic
  /// A second kit: muted concert bass drum, Snare Modern 2 with cross-stick, high tom,
  /// single claps, tambourine.
  case studio
  /// Hand percussion: cajon bass and slap, shaker, tambourine, congas, bongo, claps.
  case hand

  /// Clean gain after the kit limiter so a whole pattern sits as loud as the acoustic
  /// kit. (Driving the limiter harder instead squashed the kick and shifted the balance.)
  var postGain: Float {
    switch self {
    case .acoustic: return 1
    case .studio: return 1.2   // +1.6 dB
    case .hand: return 1.4     // +2.9 dB
    }
  }

  var folder: String {
    switch self {
    case .acoustic: return "Samples/Acoustic"
    case .studio: return "Samples/Studio"
    case .hand: return "Samples/Hand"
    }
  }
}

/// Velocity-layered VCSL one-shots. Layer pick + residual gain + tone + length;
/// velocity is timbre, not a volume knob on one sample.
enum AcousticKit {
  struct Layer {
    var vel: Float
    var takes: [AVAudioPCMBuffer]
  }

  private static var banks: [SampleKit: [DrumVoice: [Layer]]] = [:]
  private static var rr: [SampleKit: [DrumVoice: Int]] = [:]
  private static var loaded: Set<SampleKit> = []
  private static let lock = NSLock()

  static var isLoaded: Bool { isLoaded(.acoustic) }

  static func isLoaded(_ kit: SampleKit) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return loaded.contains(kit)
  }

  /// Velocity layers per voice: (velocity it sits at, round-robin takes).
  private static func specs(_ kit: SampleKit) -> [DrumVoice: [(Float, [String])]] {
    switch kit {
    case .acoustic:
      return [
        .kick: [(0.28, ["kick_v2"]), (0.68, ["kick_v5"]), (1.00, ["kick_v7"])],
        .snare: [(0.35, ["snare_v3"]), (0.68, ["snare_v5", "snare_v5b"]), (1.00, ["snare_v7"])],
        .hat: [(0.30, ["hat_v1"]), (0.62, ["hat_v3"]), (1.00, ["hat_v4"])],
        .ohat: [(1.00, ["ohat"])],
        .clap: [(0.48, ["clap_a", "clap_b"]), (1.00, ["clap_c", "clap_b"])],
        .rim: [(0.45, ["rim_a"]), (1.00, ["rim_b"])],
        .tom: [(0.45, ["tom_v2"]), (1.00, ["tom_v4"])],
        // No perc samples: the kit's perc is the synthesised shaker (these were a cowbell).
      ]
    case .studio:
      return [
        .kick: [(0.25, ["kick_v1"]), (0.55, ["kick_v2", "kick_v2b"]), (0.8, ["kick_v3"]), (1.00, ["kick_v4", "kick_v4b"])],
        .snare: [(0.25, ["snare_v2"]), (0.5, ["snare_v3", "snare_v3b"]), (0.75, ["snare_v4"]), (1.00, ["snare_v5", "snare_v5b"])],
        .hat: [(0.25, ["hat_v1"]), (0.5, ["hat_v2"]), (0.75, ["hat_v3"]), (1.00, ["hat_v4"])],
        .ohat: [(1.00, ["ohat", "ohat_b"])],
        .clap: [(0.3, ["clap_a"]), (0.55, ["clap_b"]), (0.8, ["clap_d"]), (1.00, ["clap_c"])],
        .rim: [(1.00, ["rim_a", "rim_b"])],
        .tom: [(0.35, ["tom_v2"]), (0.7, ["tom_v3"]), (1.00, ["tom_v4"])],
        .perc: [(0.5, ["perc_v1"]), (1.00, ["perc_v2"])],
      ]
    case .hand:
      return [
        .kick: [(0.3, ["kick_v1"]), (0.65, ["kick_v2", "kick_v2b"]), (1.00, ["kick_v3", "kick_v3b"])],
        .snare: [(0.35, ["snare_v1", "snare_v1b"]), (0.7, ["snare_v2", "snare_v2b"]), (1.00, ["snare_v3", "snare_v3b"])],
        .hat: [(0.5, ["hat_c", "hat_d"]), (1.00, ["hat_a", "hat_b"])],
        .ohat: [(1.00, ["ohat", "ohat_b"])],
        .clap: [(1.00, ["clap_a", "clap_b", "clap_c"])],
        .rim: [(0.5, ["rim_a"]), (1.00, ["rim_b"])],
        .tom: [(0.35, ["tom_v1"]), (0.7, ["tom_v2"]), (1.00, ["tom_v3"])],
        .perc: [(0.5, ["perc_v1"]), (1.00, ["perc_v2"])],
      ]
    }
  }

  static func load() { load(.acoustic) }

  static func load(_ kit: SampleKit) {
    if isLoaded(kit) { return }
    var built: [DrumVoice: [Layer]] = [:]
    for (voice, layerSpecs) in specs(kit) {
      var layers: [Layer] = []
      for (vel, names) in layerSpecs {
        let takes = names.compactMap { read($0, folder: kit.folder) }
        if !takes.isEmpty { layers.append(Layer(vel: vel, takes: takes)) }
      }
      if !layers.isEmpty { built[voice] = layers }
    }
    lock.lock()
    if !loaded.contains(kit) {
      banks[kit] = built
      loaded.insert(kit)
    }
    lock.unlock()
  }

  /// Mix one hit. Returns frames written (0 = no sample; caller should analog-fallback).
  @discardableResult
  static func mix(
    _ voice: DrumVoice,
    kit: SampleKit = .acoustic,
    vel: Float,
    _ L: UnsafeMutablePointer<Float>,
    _ R: UnsafeMutablePointer<Float>,
    _ frames: Int,
    _ sr: Double,
    _ at: Int,
    pan: DrumPan = .center
  ) -> Int {
    if !isLoaded(kit) { return 0 }
    let hits = pick(voice, kit: kit, vel: vel)
    guard !hits.isEmpty else { return 0 }
    let trim = levelTrim(voice, kit: kit)
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
  /// natural dynamics. Studio and Hand are matched to the acoustic kit's balance.
  private static func levelTrim(_ voice: DrumVoice, kit: SampleKit) -> Float {
    let dB: Float
    switch kit {
    case .acoustic:
      switch voice {
      case .kick: dB = 7.8
      case .snare: dB = 7.5
      case .hat: dB = -0.3
      case .ohat: dB = 1.3
      case .clap: dB = 4.7
      case .rim: dB = 15.4   // punch-matched at 20.7, but its sharp ~3 kHz click peaked over the snare
      case .tom: dB = 12.8
      case .perc: dB = 21.3
      }
    case .studio:
      switch voice {
      case .kick: dB = 3.0
      case .snare: dB = 2.6
      case .hat: dB = -0.6
      case .ohat: dB = -1.0
      case .clap: dB = 8.0  // a single hand: peaky, the kit limiter holds it ~4 dB under a group clap
      case .rim: dB = 9.8
      case .tom: dB = 6.2
      case .perc: dB = -5.1
      }
    case .hand:
      switch voice {
      case .kick: dB = 3.0
      case .snare: dB = 1.8
      case .hat: dB = 17.5
      case .ohat: dB = 18.1
      case .clap: dB = -0.8
      case .rim: dB = -4.8
      case .tom: dB = 8.9
      case .perc: dB = -6.3
      }
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

  private static func pick(_ voice: DrumVoice, kit: SampleKit, vel: Float) -> [Play] {
    // Jam phrases render off the main thread while a kit may be loading: the banks and
    // round-robin counters are only touched under the lock.
    lock.lock()
    let layers = banks[kit]?[voice] ?? []
    let idx = rr[kit]?[voice] ?? 0
    rr[kit, default: [:]][voice] = idx + 1
    lock.unlock()
    guard !layers.isEmpty else { return [] }
    let v = max(0.05, min(1, vel))

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

  private static func read(_ name: String, folder: String) -> AVAudioPCMBuffer? {
    let url =
      Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: folder)
      ?? (folder == SampleKit.acoustic.folder ? Bundle.main.url(forResource: name, withExtension: "wav") : nil)
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
