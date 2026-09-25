import AVFoundation
import Accelerate
import Foundation

enum InstrumentPreset: String, CaseIterable, Identifiable, Codable {
  case keys, bass, pluck, pad, noise
  var id: String { rawValue }
  var label: String {
    switch self {
    case .keys: return "Keys"
    case .bass: return "Bass"
    case .pluck: return "Pluck"
    case .pad: return "Pad"
    case .noise: return "Noise"
    }
  }
  var defaultWave: OscWave {
    switch self {
    case .keys: return .warm
    case .bass: return .fm
    case .pluck: return .triangle
    case .pad: return .sine
    case .noise: return .noise
    }
  }
}

enum OscWave: String, CaseIterable, Identifiable, Codable {
  case warm, sine, triangle, saw, square, pulse, noise, fm
  var id: String { rawValue }
  var label: String {
    switch self {
    case .warm: return "Warm"
    case .sine: return "Sine"
    case .triangle: return "Tri"
    case .saw: return "Saw"
    case .square: return "Sqr"
    case .pulse: return "Pulse"
    case .noise: return "Noise"
    case .fm: return "FM"
    }
  }
}

enum AudioDSP {
  static func midiToHz(_ note: Int, a4: Double) -> Double {
    a4 * pow(2.0, (Double(note) - 69) / 12)
  }

  static func makeBuffer(frames: Int, sampleRate: Double) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    return makeBuffer(frames: frames, format: format)
  }

  static func makeBuffer(frames: Int, format: AVAudioFormat) -> AVAudioPCMBuffer {
    let n = max(1, frames)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
    buf.frameLength = AVAudioFrameCount(n)
    return buf
  }

  static func click(sampleRate: Double, downbeat: Bool) -> AVAudioPCMBuffer {
    let n = Int(sampleRate * 0.04)
    let buf = makeBuffer(frames: n, sampleRate: sampleRate)
    let l = buf.floatChannelData![0]
    let r = buf.floatChannelData![1]
    let freq: Double = downbeat ? 1320 : 880
    var phase = 0.0
    for i in 0..<n {
      let t = Double(i) / sampleRate
      let env = exp(-t * 55)
      phase += (2 * Double.pi * freq) / sampleRate
      let s = Float(sin(phase) * env * (downbeat ? 0.55 : 0.32))
      l[i] = s
      r[i] = s
    }
    return buf
  }

  static func renderMetronome(bpm: Double, bars: Int, beatsPerBar: Int, format: AVAudioFormat) -> AVAudioPCMBuffer {
    let sampleRate = format.sampleRate
    let duration = Double(bars * beatsPerBar) * 60 / bpm
    let frames = max(1, Int((duration * sampleRate).rounded()))
    let buf = makeBuffer(frames: frames, format: format)
    let l = buf.floatChannelData![0]
    let r = buf.format.channelCount > 1 ? buf.floatChannelData![1] : l
    let beatSec = 60 / bpm
    let beats = bars * beatsPerBar
    for b in 0..<beats {
      let at = Int((Double(b) * beatSec * sampleRate).rounded())
      let down = b % beatsPerBar == 0
      let freq: Double = down ? 1320 : 880
      let n = Int(sampleRate * 0.04)
      var phase = 0.0
      for i in 0..<n {
        let idx = at + i
        if idx >= frames { break }
        let t = Double(i) / sampleRate
        let env = exp(-t * 55)
        phase += (2 * Double.pi * freq) / sampleRate
        let s = Float(sin(phase) * env * (down ? 0.55 : 0.32))
        l[idx] += s
        r[idx] += s
      }
    }
    return buf
  }

  static func renderPattern(
    _ pattern: DrumPattern,
    bpm: Double,
    loopBars: Int,
    format: AVAudioFormat,
    acoustic: Bool = false,
    analog: Bool = false,
    neon: Bool = false,
    sampler: SamplerCharacter? = nil,
    fixedGain: Float? = nil
  ) -> AVAudioPCMBuffer {
    let sampleRate = format.sampleRate
    let duration = Double(loopBars * 4) * 60 / bpm
    let frames = max(1, Int((duration * sampleRate).rounded()))
    let buf = makeBuffer(frames: frames, format: format)
    let L = buf.floatChannelData![0]
    let R = buf.format.channelCount > 1 ? buf.floatChannelData![1] : L
    let oL = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    let oR = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    oL.initialize(repeating: 0, count: frames)
    oR.initialize(repeating: 0, count: frames)
    defer {
      oL.deinitialize(count: frames)
      oR.deinitialize(count: frames)
      oL.deallocate()
      oR.deallocate()
    }
    let beatSec = 60 / bpm
    let sixteenth = beatSec / 4
    let repeats = max(1, loopBars / max(1, pattern.bars))
    var rng = DrumRng(seed: drumSeed(pattern, bpm: bpm, bars: loopBars))
    struct Placed { var t: Double; var vel: Float; var voice: DrumVoice; var pan: DrumPan; var step: Int }
    var placed: [Placed] = []
    placed.reserveCapacity(pattern.hits.count * repeats)
    for rep in 0..<repeats {
      let barOffsetBeats = Double(rep * pattern.bars * 4)
      for hit in pattern.hits {
        var t = (Double(hit.step) / 4 + barOffsetBeats) * beatSec
        if pattern.swing > 0 && hit.step % 2 == 1 {
          t += Double(pattern.swing) * sixteenth * 0.5
        }
        var vel = hit.vel
        humanize(hit.voice, t: &t, vel: &vel, rng: &rng)
        placed.append(Placed(t: t, vel: vel, voice: hit.voice, pan: DrumPan.kit(hit.voice, step: hit.step), step: hit.step))
      }
    }
    placed.sort { a, b in
      if abs(a.t - b.t) > 0.0004 { return a.t < b.t }
      if a.voice == .ohat && b.voice != .ohat { return false }
      if a.voice != .ohat && b.voice == .ohat { return true }
      return a.voice.rawValue < b.voice.rawValue
    }
    // Neon: what the snare, clap and toms send to the gated reverb, and where each opens the gate.
    var send: [Float] = neon ? [Float](repeating: 0, count: frames) : []
    var gateAt: [Int] = []
    for hit in placed {
      let at = Int((hit.t * sampleRate).rounded())
      let destL = hit.voice == .ohat ? oL : L
      let destR = hit.voice == .ohat ? oR : R
      if hit.voice == .hat {
        chokeOpenHats(oL, oR, from: at, frames: frames, sr: sampleRate)
      }
      if neon {
        send.withUnsafeMutableBufferPointer { s in
          renderNeon(hit.voice, destL, destR, s.baseAddress!, frames, sampleRate, at, hit.vel, step: hit.step, pan: hit.pan)
        }
        if hit.voice == .snare || hit.voice == .clap || hit.voice == .tom { gateAt.append(at) }
      } else if analog {
        renderAnalog(hit.voice, destL, destR, frames, sampleRate, at, hit.vel, step: hit.step, pan: hit.pan)
      } else if acoustic {
        let n = AcousticKit.mix(hit.voice, vel: hit.vel, destL, destR, frames, sampleRate, at, pan: hit.pan)
        if n == 0 {
          renderVoice(hit.voice, destL, destR, frames, sampleRate, at, hit.vel, pan: hit.pan)
        }
      } else {
        renderVoice(hit.voice, destL, destR, frames, sampleRate, at, hit.vel, pan: hit.pan)
      }
    }
    for i in 0..<frames {
      L[i] += oL[i]
      R[i] += oR[i]
    }
    if let character = sampler {
      applySampler(character, L, R, frames, sampleRate)
    }
    if neon {
      // After the sampler: the era's digital reverbs were cleaner than its drum samples.
      addGatedReverb(L, R, send: send, gateAt: gateAt, frames: frames, sr: sampleRate, bpm: bpm)
    }
    if acoustic {
      // Recorded drums peak far above their body. Instead of turning the whole pattern
      // down to fit the loudest spike, catch the spikes (like a mix engineer would), so
      // the kit sits at the electronic kit's level. Deterministic, so jam phrases match.
      limitDrums(L, R, frames, sampleRate, preGain: acousticPreGain)
    } else if let g = fixedGain {
      // Jam phrases use the groove's own level so a loud fill can't dip a whole phrase.
      if g != 1 {
        for i in 0..<frames {
          L[i] *= g
          R[i] *= g
        }
      }
    } else {
      normalize(L, R, frames)
    }
    if let character = sampler {
      // Set after normalising (which would undo it before).
      var g = character.level
      vDSP_vsmul(L, 1, &g, L, 1, vDSP_Length(frames))
      if R != L { vDSP_vsmul(R, 1, &g, R, 1, vDSP_Length(frames)) }
    }
    return buf
  }

  /// Runs the rendered kit through a vintage sampler. Works at a fixed internal level
  /// (peak to 0.95) so quiet patterns aren't crushed harder, then restores the level.
  static func applySampler(_ c: SamplerCharacter, _ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double) {
    var peak: Float = 1e-6
    for i in 0..<frames { peak = max(peak, abs(L[i]), abs(R[i])) }
    let pre = 0.95 / peak
    let steps = Double(1 << (c.bits - 1))
    let hold = sr / c.rate
    let drive = c.drive, norm = tanh(c.drive)
    var lpL = Biquad2(), lpR = Biquad2(), lpL2 = Biquad2(), lpR2 = Biquad2()
    lpL.lowpass(c.lowpass, 0.707, sr); lpR.lowpass(c.lowpass, 0.707, sr)
    lpL2.lowpass(c.lowpass, 0.707, sr); lpR2.lowpass(c.lowpass, 0.707, sr)
    var acc = hold, heldL = 0.0, heldR = 0.0
    for i in 0..<frames {
      acc += 1
      if acc >= hold {
        acc -= hold
        func crush(_ x: Double) -> Double {
          let sat = tanh(drive * x) / norm
          return (sat * steps).rounded() / steps
        }
        heldL = crush(Double(L[i] * pre))
        heldR = crush(Double(R[i] * pre))
      }
      L[i] = Float(lpL2.run(lpL.run(heldL))) / pre
      R[i] = Float(lpR2.run(lpR.run(heldR))) / pre
    }
  }

  /// Drive into the acoustic kit's limiter. With voices punch-matched, 1.7 brings acoustic
  /// patterns within ~1.4 dB of the electronic kit while limiting >1 dB only ~9% of the
  /// time (transients); the kit stays a touch more dynamic, like real drums.
  static let acousticPreGain: Float = 1.7
  /// Fast release so a caught transient barely ducks the rest of the kit (~0.1 s at most).
  static let drumLimiterRelease: Double = 0.025

  /// Offline lookahead peak limiter for rendered drums: stereo-linked, 1.5 ms lookahead
  /// (the gain eases down before a transient, no clipping), 25 ms release, ceiling 0.98.
  static func limitDrums(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double, preGain: Float) {
    guard frames > 0 else { return }
    let ceiling: Float = 0.98
    let la = max(1, Int(sr * 0.0015))
    // Gain each sample needs on its own.
    var need = [Float](repeating: 1, count: frames)
    for i in 0..<frames {
      let p = max(abs(L[i]), abs(R[i])) * preGain
      if p > ceiling { need[i] = ceiling / p }
    }
    // Lookahead: the lowest gain needed within the next `la` samples.
    var ahead = [Float](repeating: 1, count: frames)
    var deque: [Int] = []
    deque.reserveCapacity(la + 1)
    var head = 0
    var j = 0
    for i in 0..<frames {
      while j < frames, j <= i + la {
        while deque.count > head, need[deque[deque.count - 1]] >= need[j] { deque.removeLast() }
        deque.append(j)
        j += 1
      }
      while deque[head] < i { head += 1 }
      ahead[i] = need[deque[head]]
      if head > 4096 { deque.removeFirst(head); head = 0 }
    }
    // Ramp into it (moving average over the lookahead keeps the peak under the ceiling),
    // then release slowly.
    let rel = Float(1 - exp(-1 / (drumLimiterRelease * sr)))
    var sum: Float = 0
    var g: Float = 1
    for i in 0..<frames {
      sum += ahead[i]
      if i >= la { sum -= ahead[i - la] }
      let avg = sum / Float(min(i + 1, la))
      g = avg <= g ? avg : g + (avg - g) * rel
      L[i] *= preGain * g
      R[i] *= preGain * g
    }
  }

  /// The gain `renderPattern` would normalize this groove with (1 if it doesn't clip).
  static func grooveGain(_ pattern: DrumPattern, bpm: Double, format: AVAudioFormat, acoustic: Bool, analog: Bool = false, neon: Bool = false, sampler: SamplerCharacter? = nil) -> Float {
    let b = renderPattern(pattern, bpm: bpm, loopBars: max(1, pattern.bars), format: format, acoustic: acoustic, analog: analog, neon: neon, sampler: sampler, fixedGain: 1)
    var peak: Float = 0
    for c in 0..<Int(b.format.channelCount) {
      let p = b.floatChannelData![c]
      for i in 0..<Int(b.frameLength) { peak = max(peak, abs(p[i])) }
    }
    return peak > 1 ? 1 / peak : 1
  }

  @discardableResult
  static func mixSample(
    _ sample: AVAudioPCMBuffer,
    _ L: UnsafeMutablePointer<Float>,
    _ R: UnsafeMutablePointer<Float>,
    _ frames: Int,
    _ sr: Double,
    _ at: Int,
    gain: Float,
    pitch: Float = 1,
    tone: Float = 1,
    maxSec: Double = 12,
    pan: DrumPan = .center
  ) -> Int {
    guard let src = sample.floatChannelData, gain != 0 else { return 0 }
    let sn = Int(sample.frameLength)
    guard sn > 1 else { return 0 }
    let ssr = sample.format.sampleRate
    let chs = Int(sample.format.channelCount)
    let g = gain
    let step = (ssr / sr) * Double(max(0.25, pitch))
    let maxN = min(frames - at, Int((maxSec * sr).rounded()))
    guard maxN > 8, at < frames else { return 0 }
    let fc = 700.0 + Double(max(0, min(1, tone))) * 15_400.0
    let a = Float(1 - exp(-2 * Double.pi * fc / sr))
    var lpL: Float = 0
    var lpR: Float = 0
    var srcPos = 0.0
    var written = 0
    let fadeN = min(maxN / 4, max(24, Int(sr * 0.008)))
    while srcPos < Double(sn - 1) && written < maxN {
      let dst = at + written
      if dst >= 0 && dst < frames {
        let i0 = Int(srcPos)
        let i1 = min(i0 + 1, sn - 1)
        let frac = Float(srcPos - Double(i0))
        var sL = src[0][i0] * (1 - frac) + src[0][i1] * frac
        var sR = chs > 1 ? src[1][i0] * (1 - frac) + src[1][i1] * frac : sL
        lpL += a * (sL - lpL)
        lpR += a * (sR - lpR)
        sL = lpL
        sR = lpR
        let tail = maxN - 1 - written
        var env: Float = 1
        if written < 4 { env = Float(written) / 4 }
        if tail < fadeN { env *= Float(tail) / Float(fadeN) }
        L[dst] += sL * g * env * pan.l
        R[dst] += sR * g * env * pan.r
      }
      srcPos += step
      written += 1
    }
    return written
  }

  private static func chokeOpenHats(
    _ L: UnsafeMutablePointer<Float>,
    _ R: UnsafeMutablePointer<Float>,
    from: Int,
    frames: Int,
    sr: Double
  ) {
    let fade = max(8, Int(sr * 0.007))
    var i = max(0, from)
    while i < frames {
      let w: Float
      let k = i - from
      if k < fade {
        w = 1 - Float(k) / Float(fade)
      } else {
        w = 0
      }
      L[i] *= w
      R[i] *= w
      if w == 0 {
        i += 1
        while i < frames {
          L[i] = 0
          R[i] = 0
          i += 1
        }
        return
      }
      i += 1
    }
  }

  private static func humanize(_ voice: DrumVoice, t: inout Double, vel: inout Float, rng: inout DrumRng) {
    let (velAmt, timeAmt): (Double, Double)
    switch voice {
    case .kick: velAmt = 0.028; timeAmt = 0.0011
    case .snare: velAmt = 0.055; timeAmt = 0.0022
    case .hat: velAmt = 0.08; timeAmt = 0.0036
    case .ohat: velAmt = 0.05; timeAmt = 0.0024
    case .clap: velAmt = 0.04; timeAmt = 0.0018
    case .rim: velAmt = 0.06; timeAmt = 0.002
    case .tom: velAmt = 0.045; timeAmt = 0.0016
    case .perc: velAmt = 0.07; timeAmt = 0.0028
    }
    vel = max(0.05, min(1, vel * Float(1 + rng.bipolar() * velAmt)))
    t += rng.bipolar() * timeAmt
    t = max(0, t)
  }

  private static func drumSeed(_ pattern: DrumPattern, bpm: Double, bars: Int) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in pattern.id.utf8 {
      h ^= UInt64(b)
      h = h &* 0x100000001b3
    }
    h ^= UInt64(pattern.hits.count) &* 0x9E3779B97F4A7C15
    h ^= UInt64(Int(bpm.rounded()))
    h ^= UInt64(bars) &* 0xBF58476D1CE4E5B9
    return h
  }

  /// Drive, dirt, and vinyl (wow/flutter, rumble, crackle) — not a noise pad.
  /// Offline drum colouring for export: the same chain and crackle as live playback.
  static func colorDrums(_ buf: AVAudioPCMBuffer, drive: Float, dirt: Float, vinyl: Float, comp: Float, crackle: [Float]) {
    let n = Int(buf.frameLength)
    guard n > 16, let data = buf.floatChannelData else { return }
    let sr = buf.format.sampleRate
    let L = data[0]
    let R = buf.format.channelCount > 1 ? data[1] : data[0]
    let srcL = Array(UnsafeBufferPointer(start: L, count: n))
    let srcR = Array(UnsafeBufferPointer(start: R, count: n))
    var chain = DrumColor()
    for i in 0..<n {
      let t = Double(i) / sr
      var idx = Double(i) + DrumColor.wobble(t: t, vinyl: vinyl) * sr
      idx = min(Double(n - 2), max(0, idx))
      let i0 = Int(idx), frac = Float(idx - floor(idx))
      var x = srcL[i0] * (1 - frac) + srcL[i0 + 1] * frac
      var y = srcR[i0] * (1 - frac) + srcR[i0 + 1] * frac
      let c = crackle.count == n ? crackle[i0] * (1 - frac) + crackle[i0 + 1] * frac : 0
      chain.process(&x, &y, crackle: c, drive: drive, dirt: dirt, vinyl: vinyl, comp: comp, sampleRate: sr)
      L[i] = x
      if R != L { R[i] = y }
    }
    normalize(L, R, n)
  }

  /// One pattern-length of record surface: soft band-limited ticks, the odd low pop,
  /// and a hiss bed, tiled across `frames` so it repeats with the break the way
  /// crackle does in a sampled loop. Unit level; the Vinyl slider scales it.
  static func vinylTrack(frames: Int, period: Int, sampleRate sr: Double, seed: UInt64) -> [Float] {
    let p = max(64, min(frames, period))
    var rng = DrumRng(seed: seed)
    var one = [Float](repeating: 0, count: p)
    // Hiss: white noise band-passed to ~1-7 kHz, like surface noise through a cartridge.
    let hpA = Float(exp(-2 * Double.pi * 1000 / sr)), lpA = Float(1 - exp(-2 * Double.pi * 7000 / sr))
    var hpPrevIn: Float = 0, hpOut: Float = 0, lp: Float = 0
    for i in 0..<p {
      let w = Float(rng.bipolar())
      hpOut = hpA * (hpOut + w - hpPrevIn)
      hpPrevIn = w
      lp += lpA * (hpOut - lp)
      one[i] = lp * 0.035
    }
    // Ticks: mostly tiny, a few louder (heavy-tailed), short band-limited bursts.
    func burst(at start: Int, amp: Float, freq: Double, decay: Double, length: Int) {
      let phase = rng.unit() * 2 * Double.pi
      for k in 0..<length where start + k < p {
        let e = exp(-Double(k) / (decay * sr))
        one[start + k] += amp * Float(e * sin(2 * Double.pi * freq * Double(k) / sr + phase))
      }
    }
    let seconds = Double(p) / sr
    let ticks = Int(seconds * 14)
    for _ in 0..<ticks {
      let at = Int(rng.unit() * Double(p - 128))
      let amp = Float(0.05 + 0.55 * pow(rng.unit(), 4)) * (rng.unit() < 0.5 ? 1 : -1)
      burst(at: at, amp: amp, freq: 1800 + rng.unit() * 3400, decay: 0.00025 + rng.unit() * 0.0003, length: 96)
    }
    // The odd low pop: a scratch or dust thump.
    let pops = max(0, Int((seconds * 0.5).rounded(.down)) + (rng.unit() < seconds * 0.5 - floor(seconds * 0.5) ? 1 : 0))
    for _ in 0..<pops {
      let at = Int(rng.unit() * Double(max(1, p - 400)))
      burst(at: at, amp: Float(0.6 + rng.unit() * 0.4) * (rng.unit() < 0.5 ? 1 : -1),
            freq: 300 + rng.unit() * 600, decay: 0.0012 + rng.unit() * 0.0015, length: 360)
    }
    var out = [Float](repeating: 0, count: frames)
    for i in 0..<frames { out[i] = one[i % p] }
    return out
  }

  /// Seed so a groove always sits on the same "record".
  static func vinylSeed(_ id: String) -> UInt64 {
    var h: UInt64 = 0x84222325CBF29CE4
    for b in id.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return h
  }


  static func renderVoice(_ voice: DrumVoice, _ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double, _ at: Int, _ vel: Float, pan: DrumPan = .center) {
    switch voice {
    case .kick: kick(L, R, frames, sr, at, vel, pan: pan)
    case .snare: snare(L, R, frames, sr, at, vel, pan: pan)
    case .hat: hat(L, R, frames, sr, at, vel, open: false, pan: pan)
    case .ohat: hat(L, R, frames, sr, at, vel, open: true, pan: pan)
    case .clap: clap(L, R, frames, sr, at, vel, pan: pan)
    case .rim: rim(L, R, frames, sr, at, vel, pan: pan)
    case .tom: tom(L, R, frames, sr, at, vel, pan: pan)
    case .perc: perc(L, R, frames, sr, at, vel, pan: pan)
    }
  }

  private static func write(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ i: Int, _ l: Float, _ r: Float) {
    guard i >= 0 && i < frames else { return }
    L[i] += l
    R[i] += r
  }

  private static func kick(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double, _ at: Int, _ vel: Float, pan: DrumPan) {
    let v = Double(max(0.05, vel))
    let n = Int(sr * (0.22 + 0.28 * v))
    var phase = 0.0
    var clickPh = 0.0
    let clickAmt = 0.04 + 0.28 * v
    let decay = 8.4 - 3.2 * v
    let amp = 0.42 + 0.58 * v
    for i in 0..<n {
      let t = Double(i) / sr
      let freq = 38 + 22 * v + (70 + 110 * v) * exp(-t * (22 + 10 * v))
      let env = exp(-t * decay)
      clickPh += (2 * Double.pi * (1600 + 900 * v)) / sr
      let click = sin(clickPh) * exp(-t * (70 + 40 * v)) + Double(white()) * exp(-t * 160) * 0.35
      phase += (2 * Double.pi * freq) / sr
      var s = (sin(phase) * env * (0.78 + 0.18 * v) + click * clickAmt) * amp
      if v > 0.75 {
        s = tanh(s * (1.0 + (v - 0.75) * 1.4))
      }
      let out = Float(s)
      write(L, R, frames, at + i, out * pan.l, out * pan.r)
    }
  }

  private static func tom(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double, _ at: Int, _ vel: Float, pan: DrumPan) {
    let v = Double(max(0.05, vel))
    let n = Int(sr * (0.14 + 0.24 * v))
    var phase = 0.0
    let decay = 14 - 6.5 * v
    let amp = 0.38 + 0.62 * v
    for i in 0..<n {
      let t = Double(i) / sr
      let freq = 88 + 55 * v + (50 + 40 * v) * exp(-t * (16 + 6 * v))
      let env = exp(-t * decay)
      phase += (2 * Double.pi * freq) / sr
      let noise = Double(white()) * exp(-t * (50 + 20 * v)) * (0.08 + 0.18 * v)
      let s = Float((sin(phase) * env + noise) * amp * 0.72)
      write(L, R, frames, at + i, s * pan.l, s * pan.r)
    }
  }

  private static func snare(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double, _ at: Int, _ vel: Float, pan: DrumPan) {
    let v = Double(max(0.05, vel))
    let n = Int(sr * (0.10 + 0.16 * v))
    var phase = 0.0
    var hp: Float = 0
    var lp: Float = 0
    let lpA = Float(0.16 + 0.58 * v)
    let amp = 0.40 + 0.60 * v
    let bodyMix = 0.62 - 0.28 * v
    let noiseMix = 0.38 + 0.42 * v
    for i in 0..<n {
      let t = Double(i) / sr
      phase += (2 * Double.pi * (155 + 55 * v)) / sr
      let body = sin(phase) * exp(-t * (11 - 3 * v))
      let raw = white()
      hp += 0.22 * (raw - hp)
      lp += lpA * ((raw - hp) - lp)
      let noise = Double(lp) * exp(-t * (16 - 7 * v))
      let s = Float((body * bodyMix + noise * noiseMix) * amp * 0.7)
      write(L, R, frames, at + i, s * pan.l, s * pan.r)
    }
  }

  private static func clap(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double, _ at: Int, _ vel: Float, pan: DrumPan) {
    let v = Double(max(0.05, vel))
    let delays: [Double]
    if v < 0.35 {
      delays = [0.0, 0.013]
    } else if v < 0.7 {
      delays = [0.0, 0.011, 0.024]
    } else {
      delays = [0.0, 0.008, 0.017, 0.036]
    }
    let amp = 0.34 + 0.66 * v
    let decay = 34 - 12 * v
    let lpA = Float(0.18 + 0.55 * v)
    for delay in delays {
      let start = at + Int(delay * sr)
      let n = Int(sr * (0.055 + 0.05 * v))
      var lp: Float = 0
      for i in 0..<n {
        let t = Double(i) / sr
        let raw = white()
        lp += lpA * (raw - lp)
        let s = lp * Float(exp(-t * decay)) * Float(amp * 0.46)
        write(L, R, frames, start + i, s * pan.l, s * pan.r)
      }
    }
  }

  private static func hat(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double, _ at: Int, _ vel: Float, open: Bool, pan: DrumPan) {
    let v = Double(max(0.05, vel))
    let n = Int(sr * (open ? (0.14 + 0.20 * v) : (0.026 + 0.042 * v)))
    let decay = open ? (12.0 - 5.0 * v) : (58.0 - 20.0 * v)
    let amp = (0.38 + 0.62 * v) * (open ? 0.34 : 0.28)
    var hp: Float = 0
    var lp: Float = 0
    let lpA = Float(0.14 + 0.62 * v)
    for i in 0..<n {
      let t = Double(i) / sr
      let raw = white()
      hp += 0.18 * (raw - hp)
      let high = raw - hp
      lp += lpA * (high - lp)
      let s = lp * Float(exp(-t * decay)) * Float(amp)
      write(L, R, frames, at + i, s * pan.l, s * pan.r)
    }
  }

  private static func rim(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double, _ at: Int, _ vel: Float, pan: DrumPan) {
    let v = Double(max(0.05, vel))
    let n = Int(sr * (0.028 + 0.022 * v))
    var p1 = 0.0
    var p2 = 0.0
    let amp = 0.36 + 0.64 * v
    let highMix = 0.28 + 0.55 * v
    for i in 0..<n {
      let t = Double(i) / sr
      let env = exp(-t * (88 - 22 * v))
      p1 += (2 * Double.pi * (780 + 80 * v)) / sr
      p2 += (2 * Double.pi * (1180 + 220 * v)) / sr
      let click = Double(white()) * exp(-t * 140) * (0.08 + 0.2 * v)
      let s = Float((sin(p1) * (1 - highMix * 0.35) + sin(p2) * highMix + click) * env * amp * 0.38)
      write(L, R, frames, at + i, s * pan.l, s * pan.r)
    }
  }

  /// Perc is a soft shaker on every kit (it was a cowbell-like blip that stuck out).
  private static func perc(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double, _ at: Int, _ vel: Float, pan: DrumPan) {
    shaker(L, R, frames, sr, at, vel, pan: pan, bright: false)
  }


  private static func white() -> Float { Float.random(in: -1...1) }

  static func normalize(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int) {
    var peak: Float = 1e-6
    for i in 0..<frames {
      peak = max(peak, abs(L[i]), abs(R[i]))
    }
    if peak > 1 {
      let g = 1 / peak
      for i in 0..<frames {
        L[i] *= g
        R[i] *= g
      }
    }
  }

  static func peaks(from buffer: AVAudioPCMBuffer, buckets: Int = 180) -> [Float] {
    let n = Int(buffer.frameLength)
    guard n > 0, let ch = buffer.floatChannelData?[0] else { return Array(repeating: 0, count: buckets) }
    var out = [Float](repeating: 0, count: buckets)
    let step = max(1, n / buckets)
    for b in 0..<buckets {
      let start = b * step
      let end = min(n, start + step)
      var p: Float = 0
      var i = start
      while i < end {
        p = max(p, abs(ch[i]))
        i += 1
      }
      out[b] = p
    }
    return out
  }

  static func slice(_ buffer: AVAudioPCMBuffer, from start: Int, fadeIn: Int = 64) -> AVAudioPCMBuffer? {
    let n = Int(buffer.frameLength)
    guard start > 0, start < n - 8, let src = buffer.floatChannelData else { return nil }
    let len = n - start
    let out = makeBuffer(frames: len, format: buffer.format)
    let chs = Int(buffer.format.channelCount)
    let fade = min(fadeIn, max(8, len / 8))
    for c in 0..<chs {
      let s = src[c]
      let d = out.floatChannelData![c]
      for i in 0..<len {
        var x = s[start + i]
        if i < fade { x *= Float(i) / Float(fade) }
        d[i] = x
      }
    }
    return out
  }

  /// Crossfade the loop join and fade the edges so playback doesn’t pop.
  static func sealLoop(_ buffer: AVAudioPCMBuffer, fadeMs: Double = 8) {
    let n = Int(buffer.frameLength)
    guard n > 64, let channels = buffer.floatChannelData else { return }
    let fade = min(n / 6, max(32, Int(buffer.format.sampleRate * fadeMs / 1000.0)))
    let chCount = Int(buffer.format.channelCount)
    for c in 0..<chCount {
      let ch = channels[c]
      var mean: Float = 0
      for i in 0..<n { mean += ch[i] }
      mean /= Float(n)
      for i in 0..<n { ch[i] -= mean }
      for i in 0..<fade {
        let w = Float(i) / Float(fade)
        let a = ch[i]
        let b = ch[n - fade + i]
        ch[i] = b * (1 - w) + a * w
        ch[n - fade + i] = b * (1 - w)
      }
    }
  }

  static func reverse(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
    let n = Int(buffer.frameLength)
    let out = makeBuffer(frames: n, format: buffer.format)
    for ch in 0..<Int(buffer.format.channelCount) {
      let src = buffer.floatChannelData![ch]
      let dst = out.floatChannelData![ch]
      for i in 0..<n { dst[i] = src[n - 1 - i] }
    }
    return out
  }

  static func renderNote(
    midi: Int,
    preset: InstrumentPreset,
    velocity: Float,
    a4: Double,
    format: AVAudioFormat,
    drift: Float = 0,
    ring: Float = 0,
    glitch: Float = 0
  ) -> AVAudioPCMBuffer {
    let sampleRate = format.sampleRate
    let freq = midiToHz(midi, a4: a4)
    let seconds: Double = preset == .pluck ? 1.2 : 4
    let frames = Int(sampleRate * seconds)
    let buf = makeBuffer(frames: frames, format: format)
    let L = buf.floatChannelData![0]
    let R = buf.format.channelCount > 1 ? buf.floatChannelData![1] : L
    var pA = 0.0
    var pB = 0.0
    let detune: Double = preset == .keys ? 7 : preset == .bass ? 3 : preset == .pad ? 14 : 12
    let detuneRatio = pow(2.0, detune / 1200)
    let ringHz = 80.0 + Double(ring) * 300
    let driftAmt = Double(drift)
    for i in 0..<frames {
      let t = Double(i) / sampleRate
      let wander = 1 + driftAmt * 0.012 * (sin(t * 0.071 * 2 * .pi) + 0.6 * sin(t * 0.13 * 2 * .pi) + 0.4 * sin(t * 0.27 * 2 * .pi))
      var s: Double
      if preset == .noise {
        let n = Double.random(in: -1...1)
        s = n * exp(-t * 2.2) * Double(velocity) * 0.35
      } else {
        pA += (2 * Double.pi * freq * wander) / sampleRate
        pB += (2 * Double.pi * freq * detuneRatio * wander) / sampleRate
        let a: Double
        let b: Double
        switch preset {
        case .pad, .pluck, .bass: a = saw(pA); b = preset == .bass ? sin(pB) : square(pB)
        case .keys: a = triangle(pA); b = square(pB)
        case .noise: a = 0; b = 0
        }
        var env: Double
        switch preset {
        case .pluck: env = exp(-t * 6)
        case .bass: env = min(1, t / 0.01) * exp(-t * 2.4)
        case .pad: env = min(1, t / 0.12) * (0.7 + 0.3 * exp(-t * 0.4))
        default: env = min(1, t / 0.008) * (0.85 + 0.15 * exp(-t * 1.2))
        }
        s = (a * 0.55 + b * 0.45) * env * Double(velocity) * (preset == .bass ? 0.7 : 0.45)
      }
      if ring > 0.01 {
        let carrier = sin(2 * Double.pi * ringHz * t)
        s = s * (1 - Double(ring) * 0.6) + s * carrier * Double(ring) * 0.6
      }
      if glitch > 0.01 {
        let crush = pow(2.0, 4 + (1 - Double(glitch)) * 8)
        s = (s * crush).rounded() / crush
        s += Double.random(in: -1...1) * Double(glitch) * 0.08
      }
      let f = Float(max(-1, min(1, s)))
      L[i] = f
      R[i] = f
    }
    return buf
  }

  private static func saw(_ p: Double) -> Double {
    let x = p.truncatingRemainder(dividingBy: 2 * Double.pi) / Double.pi - 1
    return x
  }

  private static func square(_ p: Double) -> Double {
    sin(p) >= 0 ? 0.55 : -0.55
  }

  private static func triangle(_ p: Double) -> Double {
    2 / Double.pi * asin(sin(p))
  }

  /// 24-bit PCM WAV: the pro standard for stems and sessions, readable everywhere.
  static func encodeWav(_ buffer: AVAudioPCMBuffer) -> Data {
    let sr = Int(buffer.format.sampleRate)
    let ch = Int(buffer.format.channelCount)
    let n = Int(buffer.frameLength)
    let bytes = 3
    var samples = Data(count: n * ch * bytes)
    samples.withUnsafeMutableBytes { raw in
      let dst = raw.bindMemory(to: UInt8.self)
      for i in 0..<n {
        for c in 0..<ch {
          let v = buffer.floatChannelData![c][i]
          let clamped = Double(max(-1, min(1, v)))
          let q = Int32((clamped * 8_388_607).rounded())
          let o = (i * ch + c) * bytes
          dst[o] = UInt8(truncatingIfNeeded: q)
          dst[o + 1] = UInt8(truncatingIfNeeded: q >> 8)
          dst[o + 2] = UInt8(truncatingIfNeeded: q >> 16)
        }
      }
    }
    var data = Data()
    func four(_ s: String) { data.append(contentsOf: s.utf8) }
    func u16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
    func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
    four("RIFF")
    u32(UInt32(36 + samples.count))
    four("WAVE")
    four("fmt ")
    u32(16)
    u16(1)
    u16(UInt16(ch))
    u32(UInt32(sr))
    u32(UInt32(sr * ch * bytes))
    u16(UInt16(ch * bytes))
    u16(UInt16(bytes * 8))
    four("data")
    u32(UInt32(samples.count))
    data.append(samples)
    return data
  }

  static func zipStore(files: [(name: String, data: Data)]) -> Data {
    var out = Data()
    var central = Data()
    var offset: UInt32 = 0
    for file in files {
      let name = Data(file.name.utf8)

      func u16(_ d: inout Data, _ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
      func u32(_ d: inout Data, _ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
      let crc = crc32(file.data)
      var local = Data()
      u32(&local, 0x04034b50)
      u16(&local, 20)
      u16(&local, 0)
      u16(&local, 0)
      u16(&local, 0)
      u16(&local, 0)
      u32(&local, crc)
      u32(&local, UInt32(file.data.count))
      u32(&local, UInt32(file.data.count))
      u16(&local, UInt16(name.count))
      u16(&local, 0)
      local.append(name)
      local.append(file.data)
      u32(&central, 0x02014b50)
      u16(&central, 20)
      u16(&central, 20)
      u16(&central, 0)
      u16(&central, 0)
      u16(&central, 0)
      u16(&central, 0)
      u32(&central, crc)
      u32(&central, UInt32(file.data.count))
      u32(&central, UInt32(file.data.count))
      u16(&central, UInt16(name.count))
      u16(&central, 0)
      u16(&central, 0)
      u16(&central, 0)
      u16(&central, 0)
      u32(&central, 0)
      u32(&central, offset)
      central.append(name)
      offset += UInt32(local.count)
      out.append(local)
    }
    let centralOffset = offset
    out.append(central)
    func u16(_ v: UInt16) { var x = v.littleEndian; out.append(Data(bytes: &x, count: 2)) }
    func u32(_ v: UInt32) { var x = v.littleEndian; out.append(Data(bytes: &x, count: 4)) }
    u32(0x06054b50)
    u16(0)
    u16(0)
    u16(UInt16(files.count))
    u16(UInt16(files.count))
    u32(UInt32(central.count))
    u32(centralOffset)
    u16(0)
    return out
  }

  private static func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    for b in data {
      crc ^= UInt32(b)
      for _ in 0..<8 {
        let mix = crc & 1
        crc >>= 1
        if mix != 0 { crc ^= 0xEDB88320 }
      }
    }
    return crc ^ 0xFFFFFFFF
  }

  private struct DrumRng {
    var s: UInt64
    init(seed: UInt64) { s = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
      s &+= 0x9E3779B97F4A7C15
      var z = s
      z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
      z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
      return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) * 0x1.0p-53 }
    mutating func bipolar() -> Double { unit() * 2 - 1 }
  }
}


/// Drum colouring shared by live playback and export, so both sound the same.
/// Order follows a real sampled break: the record (drums + surface noise together),
/// then the sampler (dulling, narrower image), then Drive and Dirt on the whole thing.
struct DrumColor {
  private var lpL: Float = 0
  private var lpR: Float = 0
  private var prev: Float = 0
  // Parallel compressor state.
  private var env: Float = 0
  private var coefRate: Double = 0
  private var rel: Float = 0

  /// Parallel ("New York") drum compression: a heavily compressed copy is blended under
  /// the untouched kit, so transients stay intact and the body (snare sustain, room,
  /// hat detail) comes up. Clean: no saturation. Stereo-linked, instant attack (the copy
  /// must lose its transients, or it adds them back with makeup and spikes the peaks),
  /// 100 ms release, 8:1 above -28 dBFS with a 6 dB soft knee.
  static let compThresholdDB: Float = -28
  static let compRatio: Float = 8
  static let compMakeupDB: Float = 20

  /// Record-speed wobble in seconds of displacement: wow ~0.32 Hz up to ±0.3% pitch,
  /// flutter 13 Hz up to ±0.1%, at full Vinyl. (Was scaled by loop length before.)
  static func wobble(t: Double, vinyl: Float) -> Double {
    let v = Double(max(0, min(1, vinyl)))
    guard v > 0.001 else { return 0 }
    return v * (sin(2 * Double.pi * 0.32 * t) * 0.0015 + sin(2 * Double.pi * 13 * t) * 0.000012)
  }

  mutating func process(_ x: inout Float, _ y: inout Float, crackle c: Float, drive: Float, dirt: Float, vinyl: Float, comp: Float = 0, sampleRate sr: Double = 48000) {
    let v = max(0, min(1, vinyl))
    if v > 0.001 {
      // Surface noise sits under the drums, in the same "sample".
      let s = c * v * 0.1
      x += s
      y += s
      // Records being sampled are close to mono.
      let mid = (x + y) * 0.5, side = (x - y) * 0.5 * (1 - v * 0.5)
      x = mid + side
      y = mid - side
      // Dulled top end, as before.
      lpL += 0.12 * (x - lpL)
      lpR += 0.12 * (y - lpR)
      x = x * (1 - v * 0.45) + lpL * v * 0.45
      y = y * (1 - v * 0.45) + lpR * v * 0.45
    }
    if comp > 0.001 {
      if sr != coefRate {
        coefRate = sr
        rel = Float(1 - exp(-1 / (0.1 * sr)))
      }
      let level = max(abs(x), abs(y))
      env = level > env ? level : env + rel * (level - env)
      let over = 20 * log10f(max(env, 1e-6)) - Self.compThresholdDB
      let slope = 1 - 1 / Self.compRatio
      let grDB: Float
      if over <= -3 {
        grDB = 0
      } else if over < 3 {
        grDB = -slope * (over + 3) * (over + 3) / 12
      } else {
        grDB = -slope * over
      }
      let g = powf(10, (grDB + Self.compMakeupDB) / 20) * min(1, comp)
      x += x * g
      y += y * g
    }
    if drive > 0.01 {
      let g = 1 + drive * 4.5
      x = tanhf(x * g) / tanhf(g)
      y = tanhf(y * g) / tanhf(g)
    }
    if dirt > 0.01 {
      let hp = x - prev
      prev = x
      x += hp * dirt * 0.22
      y += hp * dirt * 0.18
      x += tanhf(x * x * x * (2 + dirt * 4)) * dirt * 0.18
    }
    // Loose safety only: the parallel blend can peak a little over full scale, which the
    // drum bus trim and the master limiter handle (a hard clip here would distort it).
    x = max(-4, min(4, x))
    y = max(-4, min(4, y))
  }
}


/// Stereo placement for a drum hit: constant-power pan law, normalised so a centred
/// voice is exactly unity on both sides (no level change for kick and snare).
struct DrumPan {
  var l: Float
  var r: Float

  static let center = DrumPan(l: 1, r: 1)

  /// -1 = hard left, 0 = centre, +1 = hard right.
  init(_ position: Float) {
    let a = Double((max(-1, min(1, position)) + 1) * Float.pi / 4)
    l = Float(cos(a) * 2.0.squareRoot())
    r = Float(sin(a) * 2.0.squareRoot())
  }

  init(l: Float, r: Float) {
    self.l = l
    self.r = r
  }

  /// Audience-perspective kit: kick, snare, rim and clap centred; hi-hats 30% right;
  /// perc 35% left to balance them; toms sweep from 30% right (high) to 35% left
  /// (floor) across the bar, so fills move down the kit like a drummer's.
  static func kit(_ voice: DrumVoice, step: Int) -> DrumPan {
    switch voice {
    case .kick, .snare, .rim, .clap: return .center
    case .hat, .ohat: return DrumPan(0.3)
    case .perc: return DrumPan(-0.35)
    case .tom:
      let pos = Float(((step % 16) + 16) % 16) / 15
      return DrumPan(0.3 - 0.65 * pos)
    }
  }
}

/// The drum kit a pattern is rendered with.
enum DrumKit: String, CaseIterable, Identifiable {
  /// Analog drum machine through a dark 12-bit, 26 kHz sampler: warm, hazy downtempo.
  case dusty
  /// The same machine pushed harder through a rougher 10-bit, 22 kHz sampler: gritty
  /// and bright for fast, chopped braindance.
  case crunch
  /// Big mid-80s drum machine: punchy kick, snare and clap in a huge gated reverb,
  /// swooping electronic toms, through a cleaner 12-bit sampler.
  case neon
  /// Recorded one-shots (VCSL, CC0).
  case acoustic
  var id: String { rawValue }
  var label: String {
    switch self {
    case .dusty: return "Dusty"
    case .crunch: return "Crunch"
    case .neon: return "Neon"
    case .acoustic: return "Acoustic"
    }
  }
  /// Voiced by the analog machine (Dusty, Crunch).
  var analog: Bool { self == .dusty || self == .crunch }
  /// The classic-sampler character this kit renders through (nil for acoustic).
  var sampler: SamplerCharacter? {
    switch self {
    case .dusty: return .dusty
    case .crunch: return .crunch
    case .neon: return .neon
    case .acoustic: return nil
    }
  }
}

/// Vintage sampler emulation: the machine sampled through old gear. Saturation, then
/// sample-rate reduction (zero-order hold, no anti-alias: the classic grit), bit
/// reduction, then a reconstruction low-pass.
struct SamplerCharacter {
  var drive: Double
  var rate: Double
  var bits: Int
  var lowpass: Double
  /// Output level after normalising.
  var level: Float

  // Levels put both at the old default kit's loudness (1.4 dB over Acoustic), so the
  // drums/keys balance set by ear is unchanged.
  static let dusty = SamplerCharacter(drive: 1.6, rate: 26_040, bits: 12, lowpass: 9_000, level: 0.45)
  static let crunch = SamplerCharacter(drive: 2.6, rate: 22_050, bits: 10, lowpass: 13_000, level: 0.38)
  /// Cleaner and brighter: the 12-bit, ~30 kHz machines of the mid-80s.
  static let neon = SamplerCharacter(drive: 1.2, rate: 30_000, bits: 12, lowpass: 13_500, level: 0.77)
}

extension AudioDSP {
  /// Analog drum machine voices, modelled on the classic circuits:
  /// - kick: struck resonator (a decaying sine) with a fast pitch drop, a click, soft saturation
  /// - snare: two tuned resonators for the body plus high-passed noise for the snare wires
  /// - clap: four noise bursts ~9 ms apart through a band-pass, then a short tail
  /// - hats: six detuned square oscillators through band-pass and high-pass filters
  /// - rim: two short high resonators; tom: pitch falls across the bar (high -> floor)
  /// - perc: the two-oscillator cowbell
  /// Oscillators are band-limited (PolyBLEP). `step` sets the tom's pitch.
  static func renderAnalog(
    _ voice: DrumVoice, _ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>,
    _ frames: Int, _ sr: Double, _ at: Int, _ vel: Float, step: Int, pan: DrumPan
  ) {
    var rng = DrumRng(seed: UInt64(truncatingIfNeeded: at) &* 0x9E37_79B9 &+ UInt64(voice.rawValue.count) &* 0xBF58_476D)
    let v = Double(max(0.05, min(1, vel)))
    // Per-voice level so the kit's balance matches the acoustic kit's (each voice's punch
    // relative to its kick, at vel 0.8/1.0).
    let trimDB: Double
    switch voice {
    case .kick: trimDB = -2.5
    case .snare: trimDB = -3.8
    case .hat: trimDB = 0.3
    case .ohat: trimDB = 1.8
    case .clap: trimDB = 4.2
    case .rim: trimDB = -4.4
    case .tom: trimDB = -6.0
    case .perc: trimDB = 8.2
    }
    let trim = pow(10, trimDB / 20)
    func put(_ i: Int, _ s: Double) {
      let j = at + i
      guard j >= 0, j < frames else { return }
      L[j] += Float(s * trim) * pan.l
      R[j] += Float(s * trim) * pan.r
    }
    func square(_ phase: Double, _ inc: Double) -> Double {
      let t = phase - floor(phase)
      var s = t < 0.5 ? 1.0 : -1.0
      s += blep(t, inc)
      s -= blep((t + 0.5).truncatingRemainder(dividingBy: 1), inc)
      return s
    }
    switch voice {
    case .kick:
      // Deep body with a punchy sweep from ~150 Hz, a short noise click, and saturation
      // so it has weight rather than a clean sine "boop".
      let decay = 0.3 + 0.38 * v
      let n = Int(sr * min(1.8, decay * 5))
      var ph = 0.0
      var lp = 0.0
      let amp = 0.6 + 0.4 * v
      for i in 0..<n {
        let t = Double(i) / sr
        let f = 46 * (1 + 2.2 * exp(-t / 0.018) + 0.4 * exp(-t / 0.08))
        ph += 2 * .pi * f / sr
        let body = sin(ph) * exp(-t / decay) * (1 + 0.25 * exp(-t / 0.04))
        lp += 0.35 * (rng.bipolar() - lp)
        let click = lp * exp(-t / 0.0025) * 0.5 * v
        put(i, tanh(2.2 * (body * 0.85 + click)) / tanh(2.2) * amp)
      }
    case .snare:
      // Body at ~185/330 Hz with a pitch drop, and snare wires as band-limited noise
      // (1-9 kHz) with a longer tail: a crack with weight, not a thin tick.
      let n = Int(sr * 0.45)
      var hp1 = Biquad2(), hp2 = Biquad2(), lp1 = Biquad2()
      hp1.highpass(1000, 0.707, sr); hp2.highpass(1000, 0.707, sr); lp1.lowpass(9000, 0.707, sr)
      let noiseDecay = 0.12 + 0.07 * v
      let amp = 0.5 + 0.5 * v
      var ph1 = 0.0, ph2 = 0.0
      for i in 0..<n {
        let t = Double(i) / sr
        let drop = 1 + 0.18 * exp(-t / 0.012)
        ph1 += 2 * .pi * 185 * drop / sr
        ph2 += 2 * .pi * 330 * drop / sr
        let tone = (0.6 * sin(ph1) + 0.35 * sin(ph2)) * exp(-t / 0.07)
        let noise = lp1.run(hp2.run(hp1.run(rng.bipolar()))) * exp(-t / noiseDecay)
        put(i, tanh(1.4 * (tone * 0.7 + noise * 0.95)) / tanh(1.4) * amp)
      }
    case .clap:
      let n = Int(sr * 0.42)
      var bp = Biquad2()
      bp.bandpass(1150, 1.1, sr)
      let bursts = [0.0, 0.009, 0.018, 0.027]
      let amp = 0.5 + 0.5 * v
      for i in 0..<n {
        let t = Double(i) / sr
        var env = 0.0
        for b in bursts where t >= b { env = max(env, exp(-(t - b) / 0.0042)) }
        if t >= bursts[3] { env = max(env, 0.55 * exp(-(t - bursts[3]) / 0.11)) }
        put(i, bp.run(rng.bipolar()) * env * amp * 1.6)
      }
    case .hat, .ohat:
      let open = voice == .ohat
      let decay = open ? 0.22 + 0.16 * v : 0.032 + 0.022 * v
      let n = Int(sr * min(1.2, decay * 6))
      let freqs = [205.3, 304.4, 369.6, 522.7, 540.0, 800.0]
      var phases = freqs.map { _ in rng.unit() }
      var bp = Biquad2(), hp = Biquad2()
      bp.bandpass(7100, 1.4, sr); hp.highpass(6200, 0.707, sr)
      let amp = (0.35 + 0.65 * v) * (open ? 0.9 : 0.8)
      for i in 0..<n {
        let t = Double(i) / sr
        var metal = 0.0
        for k in 0..<freqs.count {
          let inc = freqs[k] / sr
          metal += square(phases[k], inc)
          phases[k] += inc
          if phases[k] >= 1 { phases[k] -= 1 }
        }
        // Half metallic oscillators, half noise: dusty rather than a pure "toy" ring.
        let s = hp.run(bp.run(metal / 6 * 0.55 + rng.bipolar() * 0.45)) * exp(-t / decay)
        put(i, s * amp * 2.2)
      }
    case .rim:
      let n = Int(sr * 0.05)
      let amp = 0.45 + 0.55 * v
      for i in 0..<n {
        let t = Double(i) / sr
        let s = 0.6 * sin(2 * .pi * 455 * t) * exp(-t / 0.008) + 0.5 * sin(2 * .pi * 1667 * t) * exp(-t / 0.005)
        put(i, s * amp)
      }
    case .tom:
      // High tom early in the bar, floor tom at the end (matches the pan sweep).
      let pos = Double(((step % 16) + 16) % 16) / 15
      let f0 = 190 * pow(0.5, pos)
      let decay = 0.16 + 0.12 * v + 0.08 * pos
      let n = Int(sr * min(1.2, decay * 5))
      var ph = 0.0
      let amp = 0.5 + 0.5 * v
      for i in 0..<n {
        let t = Double(i) / sr
        ph += 2 * .pi * f0 * (1 + 0.3 * exp(-t / 0.02)) / sr
        let s = sin(ph) * exp(-t / decay) + rng.bipolar() * 0.05 * exp(-t / 0.02)
        put(i, s * amp)
      }
    case .perc:
      // Machine maracas (the kit's perc is a shaker, not a cowbell).
      shaker(L, R, frames, sr, at, Float(v), pan: DrumPan(l: pan.l * Float(trim), r: pan.r * Float(trim)), bright: true)
    }
  }

  /// Shaker: high-passed noise with a quick grain attack, a second smaller grain and a
  /// short decay. `bright` is the analog kit's tighter, brighter machine maracas.
  static func shaker(
    _ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double,
    _ at: Int, _ vel: Float, pan: DrumPan, bright: Bool
  ) {
    let v = Double(max(0.05, min(1, vel)))
    var rng = DrumRng(seed: UInt64(truncatingIfNeeded: at) &* 0xD1B5_4A32 &+ (bright ? 7 : 3))
    var hp1 = Biquad2(), hp2 = Biquad2()
    let fc = bright ? 7000.0 : 4500.0
    hp1.highpass(fc, 0.707, sr); hp2.highpass(fc, 0.707, sr)
    let decay = (bright ? 0.018 : 0.03) * (0.8 + 0.4 * v)
    let n = Int(sr * decay * 6)
    // Sits ~2 dB under the closed hats: texture, not a lead voice (noise carries far more
    // energy than the hats' short hits, so this is well down from unity).
    let amp = (0.25 + 0.55 * v) * (bright ? 0.9 : 0.75) * 0.085
    for i in 0..<n {
      let t = Double(i) / sr
      let grain1 = min(1, t / 0.0025) * exp(-t / decay)
      let grain2 = t > 0.012 ? 0.4 * exp(-(t - 0.012) / decay) : 0
      let s = hp2.run(hp1.run(rng.bipolar())) * (grain1 + grain2) * amp
      let j = at + i
      guard j >= 0, j < frames else { continue }
      L[j] += Float(s) * pan.l
      R[j] += Float(s) * pan.r
    }
  }

  /// PolyBLEP step correction for band-limited square edges.
  fileprivate static func blep(_ t: Double, _ dt: Double) -> Double {
    if t < dt { let x = t / dt; return x + x - x * x - 1 }
    if t > 1 - dt { let x = (t - 1) / dt; return x * x + x + x + 1 }
    return 0
  }

  /// Small RBJ biquad (Double precision) for offline voice rendering.
  fileprivate struct Biquad2 {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0, z1 = 0.0, z2 = 0.0
    mutating func run(_ x: Double) -> Double {
      let y = b0 * x + z1
      z1 = b1 * x - a1 * y + z2
      z2 = b2 * x - a2 * y
      return y
    }
    mutating func bandpass(_ f: Double, _ q: Double, _ sr: Double) {
      let w = 2 * .pi * f / sr, al = sin(w) / (2 * q), a0 = 1 + al
      b0 = al / a0; b1 = 0; b2 = -al / a0; a1 = -2 * cos(w) / a0; a2 = (1 - al) / a0
    }
    mutating func lowpass(_ f: Double, _ q: Double, _ sr: Double) {
      let w = 2 * .pi * min(f, sr * 0.45) / sr, al = sin(w) / (2 * q), c = cos(w), a0 = 1 + al
      b0 = (1 - c) / 2 / a0; b1 = (1 - c) / a0; b2 = (1 - c) / 2 / a0; a1 = -2 * c / a0; a2 = (1 - al) / a0
    }
    mutating func highpass(_ f: Double, _ q: Double, _ sr: Double) {
      let w = 2 * .pi * f / sr, al = sin(w) / (2 * q), c = cos(w), a0 = 1 + al
      b0 = (1 + c) / 2 / a0; b1 = -(1 + c) / a0; b2 = (1 + c) / 2 / a0; a1 = -2 * c / a0; a2 = (1 - al) / a0
    }
  }
}

// MARK: - Neon kit (big mid-80s machine)

extension AudioDSP {
  /// One Neon hit into the dry mix, plus its share into the gated-reverb send (mono).
  static func renderNeon(
    _ voice: DrumVoice, _ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>,
    _ send: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double, _ at: Int, _ vel: Float,
    step: Int, pan: DrumPan
  ) {
    var rng = DrumRng(seed: UInt64(truncatingIfNeeded: at) &* 0x2545_F491 &+ UInt64(voice.rawValue.count) &* 0x9E37_79B9)
    let v = Double(max(0.05, min(1, vel)))
    // Per-voice level (balanced against the acoustic kit) and reverb send.
    let trimDB: Double, sendAmt: Double
    switch voice {
    // The acoustic kit's balance, except the snare (+2 dB), clap and toms (+1 dB) are
    // pushed forward on purpose: the oversized snare is the sound.
    case .kick: trimDB = 0; sendAmt = 0
    case .snare: trimDB = 0.5; sendAmt = 1
    case .hat: trimDB = 3.3; sendAmt = 0
    case .ohat: trimDB = 5.9; sendAmt = 0
    case .clap: trimDB = 4.5; sendAmt = 0.9
    case .rim: trimDB = -2.0; sendAmt = 0.25
    case .tom: trimDB = -4.6; sendAmt = 0.6
    case .perc: trimDB = 9.3; sendAmt = 0
    }
    let trim = pow(10, trimDB / 20)
    func put(_ i: Int, _ s: Double) {
      let j = at + i
      guard j >= 0, j < frames else { return }
      let x = s * trim
      L[j] += Float(x) * pan.l
      R[j] += Float(x) * pan.r
      if sendAmt > 0 { send[j] += Float(x * sendAmt) }
    }
    switch voice {
    case .kick:
      // Tight and punchy: a fast sweep from ~180 Hz onto a short body, and a hard beater click.
      let decay = 0.2 + 0.12 * v
      let n = Int(sr * min(1.2, decay * 5))
      var ph = 0.0
      var hp = Biquad2()
      hp.highpass(2500, 0.707, sr)
      let amp = 0.6 + 0.4 * v
      for i in 0..<n {
        let t = Double(i) / sr
        let f = 52 * (1 + 2.5 * exp(-t / 0.011) + 0.35 * exp(-t / 0.05))
        ph += 2 * .pi * f / sr
        let body = sin(ph) * exp(-t / decay)
        let click = (hp.run(rng.bipolar()) * 0.6 + sin(2 * .pi * 1500 * t) * 0.5) * exp(-t / 0.003) * v
        put(i, tanh(2.6 * (body * 0.9 + click * 0.45)) / tanh(2.6) * amp)
      }
    case .snare:
      // Crisp and bright: a short tuned body under wide, hissy wires. Most of its size
      // comes from the gated reverb.
      let n = Int(sr * 0.35)
      var hp1 = Biquad2(), hp2 = Biquad2(), lp = Biquad2()
      hp1.highpass(1500, 0.707, sr); hp2.highpass(1500, 0.707, sr); lp.lowpass(11_000, 0.707, sr)
      let noiseDecay = 0.1 + 0.06 * v
      let amp = 0.5 + 0.5 * v
      var ph1 = 0.0, ph2 = 0.0
      for i in 0..<n {
        let t = Double(i) / sr
        let drop = 1 + 0.25 * exp(-t / 0.01)
        ph1 += 2 * .pi * 200 * drop / sr
        ph2 += 2 * .pi * 360 * drop / sr
        let tone = (0.6 * sin(ph1) + 0.4 * sin(ph2)) * exp(-t / 0.05)
        let noise = lp.run(hp2.run(hp1.run(rng.bipolar()))) * exp(-t / noiseDecay)
        put(i, tanh(1.6 * (tone * 0.6 + noise * 1.1)) / tanh(1.6) * amp)
      }
    case .clap:
      // A stack of four hands, a wider band than the analog clap, and a short tail.
      let n = Int(sr * 0.35)
      var bp1 = Biquad2(), bp2 = Biquad2()
      bp1.bandpass(1300, 0.9, sr); bp2.bandpass(2600, 1.2, sr)
      let bursts = [0.0, 0.011, 0.021, 0.033]
      let amp = 0.5 + 0.5 * v
      for i in 0..<n {
        let t = Double(i) / sr
        var env = 0.0
        for b in bursts where t >= b { env = max(env, exp(-(t - b) / 0.005)) }
        if t >= bursts[3] { env = max(env, 0.5 * exp(-(t - bursts[3]) / 0.09)) }
        let x = rng.bipolar()
        put(i, (bp1.run(x) + 0.6 * bp2.run(x)) * env * amp * 1.5)
      }
    case .hat, .ohat:
      // Bright and tight, mostly metal.
      let open = voice == .ohat
      let decay = open ? 0.24 + 0.12 * v : 0.026 + 0.016 * v
      let n = Int(sr * min(1.2, decay * 6))
      let freqs = [263.0, 400.0, 421.0, 474.0, 587.0, 845.0]
      var phases = freqs.map { _ in rng.unit() }
      var bp = Biquad2(), hp = Biquad2()
      bp.bandpass(9000, 1.1, sr); hp.highpass(7500, 0.707, sr)
      let amp = (0.35 + 0.65 * v) * (open ? 0.85 : 0.8)
      for i in 0..<n {
        let t = Double(i) / sr
        var metal = 0.0
        for k in 0..<freqs.count {
          let inc = freqs[k] / sr
          let p = phases[k]
          metal += (p < 0.5 ? 1 : -1) + blep(p, inc) - blep((p + 0.5).truncatingRemainder(dividingBy: 1), inc)
          phases[k] = p + inc >= 1 ? p + inc - 1 : p + inc
        }
        let s = hp.run(bp.run(metal / 6 * 0.75 + rng.bipolar() * 0.25)) * exp(-t / decay)
        put(i, s * amp * 2.4)
      }
    case .rim:
      let n = Int(sr * 0.06)
      let amp = 0.45 + 0.55 * v
      for i in 0..<n {
        let t = Double(i) / sr
        let s = 0.5 * sin(2 * .pi * 520 * t) * exp(-t / 0.01) + 0.55 * sin(2 * .pi * 1800 * t) * exp(-t / 0.006)
          + rng.bipolar() * 0.25 * exp(-t / 0.002)
        put(i, s * amp)
      }
    case .tom:
      // Electronic tom: a big downward pitch swoop, a noisy stick attack. High early in the
      // bar, low at the end (matches the pan sweep).
      let pos = Double(((step % 16) + 16) % 16) / 15
      let f0 = 230 * pow(0.5, pos * 1.2)
      let decay = 0.26 + 0.14 * v + 0.08 * pos
      let n = Int(sr * min(1.5, decay * 5))
      var ph = 0.0
      var lp = Biquad2()
      lp.lowpass(3000, 0.707, sr)
      let amp = 0.5 + 0.5 * v
      for i in 0..<n {
        let t = Double(i) / sr
        ph += 2 * .pi * f0 * (1 + 0.9 * exp(-t / 0.08)) / sr
        let tri = 2 * abs(2 * (ph / (2 * .pi) - floor(ph / (2 * .pi) + 0.5))) - 1
        let tone = (0.75 * sin(ph) + 0.25 * tri) * exp(-t / decay)
        let stick = lp.run(rng.bipolar()) * 0.5 * exp(-t / 0.012)
        put(i, tanh(1.5 * (tone + stick)) / tanh(1.5) * amp)
      }
    case .perc:
      shaker(L, R, frames, sr, at, Float(v), pan: DrumPan(l: pan.l * Float(trim), r: pan.r * Float(trim)), bright: true)
    }
  }

  /// The big gated reverb: a bright, dense room (four-line feedback delay network, ~1.6 s)
  /// opened by each snare, clap and tom, held for about a quarter note, then shut hard.
  /// The loop repeats, so a gate running past the end carries on at the start, and the
  /// reverb is warmed up on the loop's last stretch first.
  static func addGatedReverb(
    _ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>,
    send: [Float], gateAt: [Int], frames: Int, sr: Double, bpm: Double
  ) {
    guard frames > 1, !gateAt.isEmpty else { return }
    let hold = Int(sr * min(0.3, 60 / bpm * 0.55))
    let close = Int(sr * 0.03)
    let open = Int(sr * 0.002)
    var gate = [Float](repeating: 0, count: frames)
    for a in gateAt {
      for k in 0..<(hold + close) {
        let g: Float = k < open ? Float(k) / Float(open)
          : k < hold ? 1 : 1 - Float(k - hold) / Float(close)
        let j = ((a + k) % frames + frames) % frames
        if g > gate[j] { gate[j] = g }
      }
    }
    var verb = GatedRoom(sr: sr)
    let warm = min(frames, Int(sr * 1.5))
    for i in (frames - warm)..<frames { _ = verb.run(Double(send[i])) }
    let wet = 0.85
    for i in 0..<frames {
      let (l, r) = verb.run(Double(send[i]))
      let g = Double(gate[i]) * wet
      L[i] += Float(l * g)
      R[i] += Float(r * g)
    }
  }

  /// Dense, bright room: 10 ms pre-delay, two diffusers, four damped delay lines mixed by
  /// a Hadamard matrix, stereo taps.
  private struct GatedRoom {
    var pre: [Double], preIdx = 0
    var ap: [[Double]], apIdx = [0, 0]
    let apG = 0.7
    var lines: [[Double]], idx = [0, 0, 0, 0]
    var fbGain: [Double]
    var damp = [0.0, 0.0, 0.0, 0.0]
    let dampK: Double

    init(sr: Double) {
      pre = [Double](repeating: 0, count: max(1, Int(sr * 0.01)))
      ap = [4.7, 1.7].map { [Double](repeating: 0, count: max(1, Int(sr * $0 / 1000))) }
      let ms = [29.7, 37.1, 41.1, 43.7]
      lines = ms.map { [Double](repeating: 0, count: max(1, Int(sr * $0 / 1000))) }
      let rt60 = 1.6
      fbGain = ms.map { pow(10, -3 * ($0 / 1000) / rt60) }
      dampK = 1 - exp(-2 * .pi * 8000 / sr)
    }

    mutating func run(_ x: Double) -> (Double, Double) {
      var s = pre[preIdx]
      pre[preIdx] = x
      preIdx = (preIdx + 1) % pre.count
      for k in 0..<2 {
        let d = ap[k][apIdx[k]]
        let y = -apG * s + d
        ap[k][apIdx[k]] = s + apG * y
        apIdx[k] = (apIdx[k] + 1) % ap[k].count
        s = y
      }
      var o = [0.0, 0.0, 0.0, 0.0]
      for k in 0..<4 {
        damp[k] += dampK * (lines[k][idx[k]] - damp[k])
        o[k] = damp[k]
      }
      let h0 = o[0] + o[1] + o[2] + o[3], h1 = o[0] - o[1] + o[2] - o[3]
      let h2 = o[0] + o[1] - o[2] - o[3], h3 = o[0] - o[1] - o[2] + o[3]
      let mixed = [h0, h1, h2, h3]
      for k in 0..<4 {
        lines[k][idx[k]] = s + 0.5 * mixed[k] * fbGain[k]
        idx[k] = (idx[k] + 1) % lines[k].count
      }
      return ((o[0] + o[2]) * 0.7, (o[1] + o[3]) * 0.7)
    }
  }
}
