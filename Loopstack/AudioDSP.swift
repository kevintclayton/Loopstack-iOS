import AVFoundation
import Foundation

enum InstrumentPreset: String, CaseIterable, Identifiable {
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
}

enum AudioDSP {
  static func midiToHz(_ note: Int, a4: Double) -> Double {
    a4 * pow(2.0, (Double(note) - 69) / 12)
  }

  static func makeBuffer(frames: Int, sampleRate: Double) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buf.frameLength = AVAudioFrameCount(frames)
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

  static func renderMetronome(bpm: Double, bars: Int, beatsPerBar: Int, sampleRate: Double) -> AVAudioPCMBuffer {
    let duration = Double(bars * beatsPerBar) * 60 / bpm
    let frames = max(1, Int((duration * sampleRate).rounded()))
    let buf = makeBuffer(frames: frames, sampleRate: sampleRate)
    let l = buf.floatChannelData![0]
    let r = buf.floatChannelData![1]
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

  static func renderPattern(_ pattern: DrumPattern, bpm: Double, loopBars: Int, sampleRate: Double) -> AVAudioPCMBuffer {
    let duration = Double(loopBars * 4) * 60 / bpm
    let frames = max(1, Int((duration * sampleRate).rounded()))
    let buf = makeBuffer(frames: frames, sampleRate: sampleRate)
    let L = buf.floatChannelData![0]
    let R = buf.floatChannelData![1]
    let beatSec = 60 / bpm
    let sixteenth = beatSec / 4
    let repeats = max(1, loopBars / max(1, pattern.bars))
    for rep in 0..<repeats {
      let barOffsetBeats = Double(rep * pattern.bars * 4)
      for hit in pattern.hits {
        var t = (Double(hit.step) / 4 + barOffsetBeats) * beatSec
        if pattern.swing > 0 && hit.step % 2 == 1 {
          t += Double(pattern.swing) * sixteenth * 0.5
        }
        let at = Int((t * sampleRate).rounded())
        renderVoice(hit.voice, L, R, frames, sampleRate, at, hit.vel)
      }
    }
    normalize(L, R, frames)
    return buf
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
    let n = Int(sr * 0.42)
    var phase = 0.0
    for i in 0..<n {
      let t = Double(i) / sr
      let freq = 46 + 130 * exp(-t * 32)
      let env = exp(-t * 8.2)
      let click = exp(-t * 110)
      phase += (2 * Double.pi * freq) / sr
      let s = Float((sin(phase) * env + click * 0.18) * Double(vel) * 0.95)
      write(L, R, frames, at + i, s, s)
    }
  }

  private static func tom(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double, _ at: Int, _ vel: Float) {
    let n = Int(sr * 0.28)
    var phase = 0.0
    for i in 0..<n {
      let t = Double(i) / sr
      let freq = 110 + 70 * exp(-t * 22)
      let env = exp(-t * 10)
      phase += (2 * Double.pi * freq) / sr
      let s = Float(sin(phase) * env * Double(vel) * 0.7)
      write(L, R, frames, at + i, s * 0.85, s * 1.05)
    }
  }

  private static func snare(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double, _ at: Int, _ vel: Float) {
    let n = Int(sr * 0.22)
    var phase = 0.0
    for i in 0..<n {
      let t = Double(i) / sr
      let noiseEnv = exp(-t * 14)
      phase += (2 * Double.pi * 186) / sr
      let noise = (Float.random(in: -1...1)) * Float(noiseEnv)
      let body = Float(sin(phase) * exp(-t * 12))
      let s = (body * 0.45 + noise * 0.7) * vel * 0.8
      write(L, R, frames, at + i, s * 1.05, s * 0.95)
    }
  }

  private static func clap(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double, _ at: Int, _ vel: Float) {
    for delay in [0.0, 0.012, 0.024, 0.048] {
      let start = at + Int(delay * sr)
      let n = Int(sr * 0.09)
      for i in 0..<n {
        let t = Double(i) / sr
        let s = Float.random(in: -1...1) * Float(exp(-t * 28)) * vel * 0.42
        write(L, R, frames, start + i, s * 0.95, s * 1.05)
      }
    }
  }

  private static func hat(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double, _ at: Int, _ vel: Float, open: Bool) {
    let n = Int(sr * (open ? 0.28 : 0.055))
    let decay = open ? 9.0 : 55.0
    var hp: Float = 0
    for i in 0..<n {
      let t = Double(i) / sr
      let white = Float.random(in: -1...1)
      hp += 0.35 * (white - hp)
      let high = white - hp
      let s = high * Float(exp(-t * decay)) * vel * (open ? 0.38 : 0.32)
      write(L, R, frames, at + i, s * 0.8, s * 1.2)
    }
  }

  private static func rim(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double, _ at: Int, _ vel: Float) {
    let n = Int(sr * 0.04)
    var p1 = 0.0
    var p2 = 0.0
    for i in 0..<n {
      let t = Double(i) / sr
      let env = exp(-t * 70)
      p1 += (2 * Double.pi * 845) / sr
      p2 += (2 * Double.pi * 1280) / sr
      let s = Float((sin(p1) + sin(p2) * 0.5) * env * Double(vel) * 0.35)
      write(L, R, frames, at + i, s, s)
    }
  }

  private static func perc(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ frames: Int, _ sr: Double, _ at: Int, _ vel: Float) {
    let n = Int(sr * 0.12)
    var phase = 0.0
    for i in 0..<n {
      let t = Double(i) / sr
      let freq = 420 + 180 * exp(-t * 40)
      let env = exp(-t * 22)
      phase += (2 * Double.pi * freq) / sr
      let noise = Float.random(in: -1...1) * Float(exp(-t * 40)) * 0.25
      let s = (Float(sin(phase) * env) + noise) * vel * 0.45
      write(L, R, frames, at + i, s * 1.15, s * 0.8)
    }
  }

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

  static func reverse(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
    let n = Int(buffer.frameLength)
    let out = makeBuffer(frames: n, sampleRate: buffer.format.sampleRate)
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
    sampleRate: Double,
    drift: Float = 0,
    ring: Float = 0,
    glitch: Float = 0
  ) -> AVAudioPCMBuffer {
    let freq = midiToHz(midi, a4: a4)
    let seconds: Double = preset == .pluck ? 1.2 : 4
    let frames = Int(sampleRate * seconds)
    let buf = makeBuffer(frames: frames, sampleRate: sampleRate)
    let L = buf.floatChannelData![0]
    let R = buf.floatChannelData![1]
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

  static func encodeWav(_ buffer: AVAudioPCMBuffer) -> Data {
    let sr = Int(buffer.format.sampleRate)
    let ch = Int(buffer.format.channelCount)
    let n = Int(buffer.frameLength)
    var samples = Data(count: n * ch * 2)
    samples.withUnsafeMutableBytes { raw in
      let dst = raw.bindMemory(to: Int16.self)
      for i in 0..<n {
        for c in 0..<ch {
          let v = buffer.floatChannelData![c][i]
          let clamped = max(-1, min(1, v))
          dst[i * ch + c] = Int16(clamped * 32767)
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
    u32(UInt32(sr * ch * 2))
    u16(UInt16(ch * 2))
    u16(16)
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
}
