import AVFoundation
import Foundation

/// One of the bundled acoustic instruments (VCSL / VSCO 2 CE, public domain), built by
/// tools/acoustic/prepare.py: recordings at several pitches and velocity layers, with
/// seamless loops for sustained instruments.
final class AcousticInstrument: @unchecked Sendable {
  struct Zone {
    let root: Int
    /// Measured tuning of the recording, in cents from `root`.
    let cents: Double
    let layer: Int
    /// Loop points in frames (0...0 = no loop: plays through and ends).
    let loopStart: Int
    let loopEnd: Int
    let data: [Float]
    let rate: Double
  }

  let id: String
  let name: String
  /// Seconds for a released note to fade out.
  let release: Double
  let zones: [Zone]
  let layers: Int
  /// Zone to play for [layer][midi note]: the nearest recording in that velocity layer.
  let lookup: [[Int]]
  /// Output gain that seats the instrument at the Keys synth's loudness.
  let level: Float

  /// Measured: a triad at velocity 0.85 around the middle of each instrument's range,
  /// matched to the Keys synth over the first 1.2 s (sustained sounds come down most).
  static let levelDB: [String: Double] = [
    "upright": -4.3, "grand": -2.6, "harpsichord": -5.0, "organ": -0.6, "strings": -10.4, "cello": -6.1,
    "pizzicato": 2.7, "harp": -4.1, "flute": -6.7, "clarinet": -6.7, "sax": -6.7, "horn": -11.5,
    "vibraphone": -8.0, "marimba": -5.0, "glockenspiel": -2.0, "kalimba": 6.3,
  ]

  /// The instruments in the order they're offered.
  static let catalog: [(id: String, name: String)] = [
    ("upright", "Upright Piano"), ("grand", "Grand Piano"), ("harpsichord", "Harpsichord"), ("organ", "Organ"),
    ("strings", "Strings"), ("cello", "Cello"), ("pizzicato", "Pizzicato"), ("harp", "Harp"),
    ("flute", "Flute"), ("clarinet", "Clarinet"), ("sax", "Tenor Sax"), ("horn", "French Horn"),
    ("vibraphone", "Vibraphone"), ("marimba", "Marimba"), ("glockenspiel", "Glockenspiel"), ("kalimba", "Kalimba"),
  ]

  private init(id: String, name: String, release: Double, zones: [Zone]) {
    self.id = id
    self.name = name
    self.release = release
    self.zones = zones
    level = Float(pow(10, (Self.levelDB[id] ?? 0) / 20))
    let layers = (zones.map(\.layer).max() ?? 0) + 1
    self.layers = layers
    var table = [[Int]](repeating: [Int](repeating: 0, count: 128), count: layers)
    for layer in 0..<layers {
      for midi in 0..<128 {
        // Nearest root in this layer (else any layer, nearest layer first); on a tie the
        // recording above wins (pitching down sounds more natural than up).
        var best = 0, bestScore = Double.infinity
        for (i, z) in zones.enumerated() {
          let dist = Double(abs(z.root - midi)) + (z.root < midi ? 0.1 : 0)
          let score = dist + (z.layer == layer ? 0 : 1000 + Double(abs(z.layer - layer)) * 100)
          if score < bestScore { bestScore = score; best = i }
        }
        table[layer][midi] = best
      }
    }
    lookup = table
  }

  /// Loads an instrument from the app bundle (decodes its files; call off the main thread).
  static func load(_ id: String) -> AcousticInstrument? {
    let folder = "Samples/Instruments/\(id)"
    guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: folder),
          let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let entries = json["zones"] as? [[String: Any]] else { return nil }
    var zones: [Zone] = []
    for e in entries {
      guard let file = e["file"] as? String, let root = e["root"] as? Int,
            let fileURL = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: folder),
            let audio = try? AVAudioFile(forReading: fileURL, commonFormat: .pcmFormatFloat32, interleaved: false),
            let buf = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)),
            (try? audio.read(into: buf)) != nil, let ch = buf.floatChannelData else { continue }
      let n = Int(buf.frameLength)
      let samples = Array(UnsafeBufferPointer(start: ch[0], count: n))
      let loopEnd = min(n, e["loopEnd"] as? Int ?? 0)
      let loopStart = e["loopStart"] as? Int ?? 0
      zones.append(Zone(root: root, cents: e["cents"] as? Double ?? 0, layer: e["layer"] as? Int ?? 0,
                        loopStart: loopEnd > loopStart + 64 ? loopStart : 0, loopEnd: loopEnd > loopStart + 64 ? loopEnd : 0,
                        data: samples, rate: audio.processingFormat.sampleRate))
    }
    guard !zones.isEmpty else { return nil }
    return AcousticInstrument(id: id, name: json["name"] as? String ?? id, release: json["release"] as? Double ?? 0.3, zones: zones)
  }
}

/// Plays the selected acoustic instrument. Render is additive, after the synth, and
/// follows the synth's pitch bend / vibrato curve.
///
/// Threading as elsewhere: note events and the instrument are handed over under `lock`;
/// the render thread takes them with `lock.try()` and never waits. A replaced instrument
/// is retired and freed off the render thread.
final class AcousticPlayer: @unchecked Sendable {
  private struct Voice {
    var midi: Int
    var zone: Int
    var gain: Float
    var pos: Double
    /// Playback rate at no bend: the note's distance from the recording's pitch.
    var step: Double
    var env: Double = 0
    var releasing = false
    var dying = false
    /// Frames of silence before the note starts (arp notes placed mid-buffer).
    var delay = 0
    /// Frames until it releases on its own (-1 = on key up).
    var releaseIn = -1
  }

  private enum Event {
    case on(midi: Int, vel: Float)
    case off(midi: Int)
    case allOff
    case reset
  }

  private let lock = NSLock()
  private var shared: AcousticInstrument?
  /// Tuning reference (A4, Hz), shared with the synth's Tune so the two sit together.
  private var sharedA4: Double = 440
  /// Sustain: multiplies the instrument's natural release (1 = natural).
  private var sharedReleaseScale: Double = 1
  private var pending: [Event] = []
  private var gen: UInt64 = 0
  private var seenGen: UInt64 = 0
  private var retired = RetireBin()

  // Render thread.
  private var inst: AcousticInstrument?
  private var a4: Double = 440
  private var releaseScale: Double = 1
  private var renderGen: UInt64 = 0
  private var inbox: [Event] = []
  private var voices: [Voice] = []
  private var outRate: Double = 44100
  static let maxVoices = 32

  init() {
    pending.reserveCapacity(256)
    inbox.reserveCapacity(256)
    voices.reserveCapacity(Self.maxVoices + 8)
  }

  /// Main thread (or a loader thread). nil = off.
  func setInstrument(_ instrument: AcousticInstrument?) {
    lock.lock()
    if let old = shared { retired.retire(old, gen: gen &+ 1) }
    shared = instrument
    pending.append(.reset)
    gen &+= 1
    let dead = retired.collect(seen: seenGen)
    lock.unlock()
    _ = dead
  }

  /// Main thread: A4 in Hz (the synth's Tune). Applies to notes started after it.
  func setTuning(a4 hz: Double) {
    lock.lock()
    sharedA4 = max(400, min(480, hz))
    lock.unlock()
  }

  /// Main thread: Sustain as a multiple of the instrument's natural release.
  func setReleaseScale(_ scale: Double) {
    lock.lock()
    sharedReleaseScale = max(0.05, min(60, scale))
    lock.unlock()
  }

  /// Sustain slider (0...1) to a release multiple: 0.5 is the instrument's natural
  /// release, 0 about a tenth of it, 1 forty times (pedal down: pianos ring out fully).
  static func releaseScale(forSustain v: Float) -> Double {
    let x = Double(min(1, max(0, v)))
    return x < 0.5 ? pow(0.1, (0.5 - x) / 0.5) : pow(40, (x - 0.5) / 0.5)
  }

  /// Frees instruments the renderer has let go of. Call from the UI tick.
  func collect() {
    lock.lock()
    let dead = retired.collect(seen: seenGen)
    lock.unlock()
    _ = dead
  }

  func noteOn(midi: Int, velocity: Float) {
    lock.lock()
    pending.append(.on(midi: midi, vel: max(0.02, min(1, velocity))))
    lock.unlock()
  }

  func noteOff(midi: Int) {
    lock.lock()
    pending.append(.off(midi: midi))
    lock.unlock()
  }

  func allOff() {
    lock.lock()
    pending.append(.allOff)
    lock.unlock()
  }

  /// Render thread (the arp): a note `offset` frames into the next buffer that releases
  /// `gate` frames later.
  func renderThreadNote(midi: Int, velocity: Float, offset: Int, gate: Int) {
    guard var v = makeVoice(midi: midi, vel: velocity) else { return }
    for i in voices.indices where voices[i].midi == midi && !voices[i].releasing {
      if voices[i].releaseIn < 0 || voices[i].releaseIn > offset { voices[i].releaseIn = offset }
    }
    makeRoom()
    v.delay = max(0, offset)
    v.releaseIn = max(1, gate)
    voices.append(v)
  }

  /// Render thread.
  private func makeVoice(midi: Int, vel: Float) -> Voice? {
    guard let inst, !inst.zones.isEmpty else { return nil }
    let layer = min(inst.layers - 1, max(0, Int(Double(vel) * Double(inst.layers) - 1e-9)))
    let zi = inst.lookup[layer][min(127, max(0, midi))]
    let z = inst.zones[zi]
    let semis = Double(midi - z.root) - z.cents / 100
    let step = pow(2, semis / 12) * (a4 / 440) * z.rate / outRate
    // Within a layer, velocity still shades the level (the layer sets the timbre).
    let gain = Float(0.5 + 0.5 * Double(vel)) * inst.level
    return Voice(midi: midi, zone: zi, gain: gain, pos: 0, step: step)
  }

  /// Render thread. Past the voice limit the oldest fades out quickly (no click).
  private func makeRoom() {
    let live = voices.filter { !$0.dying }.count
    if live >= Self.maxVoices, let i = voices.firstIndex(where: { !$0.dying }) { voices[i].dying = true }
    if voices.count >= Self.maxVoices + 6 { voices.removeFirst(voices.count - Self.maxVoices - 5) }
  }

  private func apply(_ e: Event) {
    switch e {
    case let .on(midi, vel):
      // A repeated note lets the previous one ring out (like a real key re-struck).
      for i in voices.indices where voices[i].midi == midi { voices[i].releasing = true }
      makeRoom()
      if let v = makeVoice(midi: midi, vel: vel) { voices.append(v) }
    case let .off(midi):
      for i in voices.indices where voices[i].midi == midi && voices[i].releaseIn < 0 { voices[i].releasing = true }
    case .allOff:
      for i in voices.indices { voices[i].releasing = true }
    case .reset:
      voices.removeAll(keepingCapacity: true)
    }
  }

  func renderAdd(frames: Int, list: UnsafeMutablePointer<AudioBufferList>, dstRate: Double,
                 pitchMod: UnsafePointer<Double>?, pitchModFrames: Int) {
    let buffers = UnsafeMutableAudioBufferListPointer(list)
    guard frames > 0, let data = buffers.first?.mData else { return }
    let left = data.assumingMemoryBound(to: Float.self)
    let right: UnsafeMutablePointer<Float> = buffers.count > 1 && buffers[1].mData != nil
      ? buffers[1].mData!.assumingMemoryBound(to: Float.self) : left
    outRate = max(8000, dstRate)
    if lock.try() {
      if gen != renderGen {
        inst = shared  // the one it replaces is held in `retired`, so no free here
        renderGen = gen
        seenGen = gen
      }
      a4 = sharedA4
      releaseScale = sharedReleaseScale
      swap(&pending, &inbox)
      lock.unlock()
      for e in inbox { apply(e) }
      inbox.removeAll(keepingCapacity: true)
    }
    guard let inst, !voices.isEmpty else { return }
    let sr = outRate
    let attack = 1 / (0.003 * sr)
    let releaseCoef = exp(-1 / (max(0.02, inst.release * releaseScale) / 4.6 * sr))
    let killCoef = exp(-1 / (0.003 * sr))
    var i = 0
    while i < voices.count {
      var v = voices[i]
      let z = inst.zones[v.zone]
      let n = z.data.count
      let looped = z.loopEnd > 0
      let loopLen = Double(z.loopEnd - z.loopStart)
      var done = false
      z.data.withUnsafeBufferPointer { d in
        for f in 0..<frames {
          if v.delay > 0 { v.delay -= 1; continue }
          if v.releaseIn >= 0 {
            if v.releaseIn == 0 { v.releasing = true }
            v.releaseIn -= 1
          }
          if v.dying {
            v.env *= killCoef
          } else if v.releasing {
            v.env *= releaseCoef
          } else if v.env < 1 {
            v.env = min(1, v.env + attack)
          }
          // Looped: past the loop end, jump back; the sample after the last one in the
          // loop is the loop start (so the seam interpolates across the wrap).
          if looped, v.pos >= Double(z.loopEnd) { v.pos -= loopLen }
          let i0 = Int(v.pos)
          let i1: Int
          if looped {
            i1 = i0 + 1 >= z.loopEnd ? z.loopStart : i0 + 1
          } else {
            if i0 + 1 >= n { done = true; break }
            i1 = i0 + 1
          }
          let frac = Float(v.pos - Double(i0))
          let s = (d[i0] + (d[i1] - d[i0]) * frac) * v.gain * Float(v.env)
          left[f] += s
          if right != left { right[f] += s }
          let pm = pitchModFrames > 0 ? pitchMod![min(f, pitchModFrames - 1)] : 1
          v.pos += v.step * pm
          if (v.releasing || v.dying) && v.env < 0.0005 { done = true; break }
        }
      }
      if done {
        voices.remove(at: i)
      } else {
        voices[i] = v
        i += 1
      }
    }
  }
}
