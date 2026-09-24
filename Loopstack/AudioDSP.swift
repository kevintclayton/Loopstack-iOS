import AVFoundation
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
    case .bass: return .sine
    case .pluck: return .triangle
    case .pad: return .sine
    case .noise: return .noise
    }
  }
}

enum OscWave: String, CaseIterable, Identifiable, Codable {
  case warm, sine, triangle, saw, square, pulse, noise
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
    struct Placed { var t: Double; var vel: Float; var voice: DrumVoice }
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
        placed.append(Placed(t: t, vel: vel, voice: hit.voice))
      }
    }
    placed.sort { a, b in
      if abs(a.t - b.t) > 0.0004 { return a.t < b.t }
      if a.voice == .ohat && b.voice != .ohat { return false }
      if a.voice != .ohat && b.voice == .ohat { return true }
      return a.voice.rawValue < b.voice.rawValue
    }
    for hit in placed {
      let at = Int((hit.t * sampleRate).rounded())
      let destL = hit.voice == .ohat ? oL : L
      let destR = hit.voice == .ohat ? oR : R
      if hit.voice == .hat {
        chokeOpenHats(oL, oR, from: at, frames: frames, sr: sampleRate)
      }
      if acoustic {
        let n = AcousticKit.mix(hit.voice, vel: hit.vel, destL, destR, frames, sampleRate, at)
        if n == 0 {
          renderVoice(hit.voice, destL, destR, frames, sampleRate, at, hit.vel)
        }
      } else {
        renderVoice(hit.voice, destL, destR, frames, sampleRate, at, hit.vel)
      }
    }
    for i in 0..<frames {
      L[i] += oL[i]
      R[i] += oR[i]
    }
    if let g = fixedGain {
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
    return buf
  }

  /// The gain `renderPattern` would normalize this groove with (1 if it doesn't clip).
  static func grooveGain(_ pattern: DrumPattern, bpm: Double, format: AVAudioFormat, acoustic: Bool) -> Float {
    let b = renderPattern(pattern, bpm: bpm, loopBars: max(1, pattern.bars), format: format, acoustic: acoustic, fixedGain: 1)
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
    maxSec: Double = 12
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
        L[dst] += sL * g * env
        R[dst] += sR * g * env
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
  static func colorDrums(_ buf: AVAudioPCMBuffer, drive: Float, dirt: Float, vinyl: Float) {
    let n = Int(buf.frameLength)
    guard n > 16, let data = buf.floatChannelData else { return }
    let sr = buf.format.sampleRate
    let chs = Int(buf.format.channelCount)
    let driveAmt = 1 + drive * 4.5
    let vinylAmt = Double(max(0, min(1, vinyl)))
    for c in 0..<chs {
      let ch = data[c]
      var src = [Float](repeating: 0, count: n)
      for i in 0..<n { src[i] = ch[i] }
      var lp: Float = 0
      var prev: Float = 0
      var crackle = 0
      for i in 0..<n {
        let t = Double(i) / sr
        var idx = Double(i)
        if vinylAmt > 0.001 {
          idx += sin(2 * Double.pi * 0.32 * t) * vinylAmt * 0.0022 * sr
          idx += sin(2 * Double.pi * 13.0 * t) * vinylAmt * 0.00028 * sr
        }
        let i0 = max(0, min(n - 2, Int(floor(idx))))
        let frac = Float(idx - floor(idx))
        var x = src[i0] * (1 - frac) + src[i0 + 1] * frac
        if drive > 0.01 {
          let g = driveAmt
          x = tanhf(x * g) / tanhf(g)
        }
        if dirt > 0.01 {
          let hp = x - prev
          prev = x
          x += hp * dirt * 0.22
          x += tanhf(x * x * x * (2 + dirt * 4)) * dirt * 0.18
        }
        if vinylAmt > 0.01 {
          x += Float(sin(2 * Double.pi * 31 * t) * vinylAmt * 0.035)
          if crackle > 0 {
            x += Float(crackle) * 0.012 * (Float.random(in: -1...1))
            crackle -= 1
          } else if Double.random(in: 0..<1) < vinylAmt * 0.0024 {
            crackle = Int.random(in: 2...18)
            x += Float.random(in: 0.12...0.35) * (Bool.random() ? 1 : -1)
          }
          lp += 0.12 * (x - lp)
          x = x * Float(1 - vinylAmt * 0.45) + lp * Float(vinylAmt * 0.45)
        }
        ch[i] = max(-1, min(1, x))
      }
    }
  }

  static func renderVoice(_ voice: DrumVoice, _ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double, _ at: Int, _ vel: Float) {
    switch voice {
    case .kick: kick(L, R, frames, sr, at, vel)
    case .snare: snare(L, R, frames, sr, at, vel)
    case .hat: hat(L, R, frames, sr, at, vel, open: false)
    case .ohat: hat(L, R, frames, sr, at, vel, open: true)
    case .clap: clap(L, R, frames, sr, at, vel)
    case .rim: rim(L, R, frames, sr, at, vel)
    case .tom: tom(L, R, frames, sr, at, vel)
    case .perc: perc(L, R, frames, sr, at, vel)
    }
  }

  private static func write(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ i: Int, _ l: Float, _ r: Float) {
    guard i >= 0 && i < frames else { return }
    L[i] += l
    R[i] += r
  }

  private static func kick(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double, _ at: Int, _ vel: Float) {
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
      write(L, R, frames, at + i, out, out)
    }
  }

  private static func tom(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double, _ at: Int, _ vel: Float) {
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
      write(L, R, frames, at + i, s * 0.85, s * 1.05)
    }
  }

  private static func snare(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double, _ at: Int, _ vel: Float) {
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
      write(L, R, frames, at + i, s * 1.05, s * 0.95)
    }
  }

  private static func clap(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double, _ at: Int, _ vel: Float) {
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
        write(L, R, frames, start + i, s * 0.95, s * 1.05)
      }
    }
  }

  private static func hat(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double, _ at: Int, _ vel: Float, open: Bool) {
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
      write(L, R, frames, at + i, s * 0.78, s * 1.22)
    }
  }

  private static func rim(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double, _ at: Int, _ vel: Float) {
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
      write(L, R, frames, at + i, s, s)
    }
  }

  private static func perc(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double, _ at: Int, _ vel: Float) {
    let v = Double(max(0.05, vel))
    let n = Int(sr * (0.07 + 0.09 * v))
    var phase = 0.0
    let amp = 0.34 + 0.66 * v
    let decay = 28 - 10 * v
    for i in 0..<n {
      let t = Double(i) / sr
      let freq = 360 + 140 * v + (140 + 80 * v) * exp(-t * (32 + 8 * v))
      let env = exp(-t * decay)
      phase += (2 * Double.pi * freq) / sr
      let noise = Double(white()) * exp(-t * (48 - 12 * v)) * (0.12 + 0.32 * v)
      let s = Float((sin(phase) * env + noise) * amp * 0.48)
      write(L, R, frames, at + i, s * 1.15, s * 0.8)
    }
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
