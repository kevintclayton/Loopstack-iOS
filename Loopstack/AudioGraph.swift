import AVFoundation
import Accelerate
import Foundation

enum AudioBuf {
  /// Zero every float the engine gave us (interleaved or not). Partial zeros leave a slapback in the other channel.
  static func zero(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
    let bufs = UnsafeMutableAudioBufferListPointer(list)
    for b in bufs {
      guard let raw = b.mData else { continue }
      let n = max(Int(b.mDataByteSize) / MemoryLayout<Float>.size, frames)
      let p = raw.assumingMemoryBound(to: Float.self)
      for i in 0..<n { p[i] = 0 }
    }
  }

  static func add(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, index i: Int, sample s: Float) {
    guard i >= 0, i < frames else { return }
    let bufs = UnsafeMutableAudioBufferListPointer(list)
    guard let raw0 = bufs[0].mData else { return }
    let p0 = raw0.assumingMemoryBound(to: Float.self)
    if bufs.count >= 2, let raw1 = bufs[1].mData {
      p0[i] += s
      raw1.assumingMemoryBound(to: Float.self)[i] += s
    } else {
      let n = Int(bufs[0].mDataByteSize) / MemoryLayout<Float>.size
      if n >= frames * 2 {
        p0[i * 2] += s
        p0[i * 2 + 1] += s
      } else if i < n {
        p0[i] += s
      }
    }
  }
}

/// Holds buffers the render thread may still reference until it has picked up a
/// newer state, so the final release (and the free) never lands on the render
/// thread. Control threads retire under their lock and drop the returned batch
/// after unlocking.
struct RetireBin {
  private var items: [(gen: UInt64, obj: Any)] = []

  mutating func retire(_ obj: Any, gen: UInt64) {
    items.append((gen, obj))
  }

  /// Everything retired at or before `seen` is no longer referenced by the renderer.
  mutating func collect(seen: UInt64) -> [Any] {
    guard !items.isEmpty else { return [] }
    var dead: [Any] = []
    items.removeAll { item in
      if item.gen <= seen {
        dead.append(item.obj)
        return true
      }
      return false
    }
    return dead
  }
}

/// Allocation-free xorshift for the render thread (system random can take a lock).
struct RTRandom {
  private var s: UInt64 = 0x9E37_79B9_7F4A_7C15

  mutating func unit() -> Double {
    s ^= s << 13
    s ^= s >> 7
    s ^= s << 17
    return Double(s >> 11) * (1.0 / 9_007_199_254_740_992.0)
  }
}

/// One transport timeline for drums and loops, so they can't disagree.
///
/// Time comes from the render timestamp's sample time, which is the same for every
/// node in a render cycle, anchored to the wall clock whenever the transport
/// (re)starts. The main thread sets the cycle start under `lock`; the render thread
/// reads it with `lock.try()` and never waits.
final class TransportClock: @unchecked Sendable {
  private let lock = NSLock()
  private var sharedStart: TimeInterval = 0
  private var sharedRate: Double = 44100
  private var sharedGen: UInt64 = 0

  // Render thread only.
  private var start: TimeInterval = 0
  private var rate: Double = 44100
  private var gen: UInt64 = 0
  private var anchor: (key: Double, t: Double)?
  private var fallbackKey: Double = 0

  /// Main thread: a new cycle origin (transport start / restart).
  func set(cycleStart: TimeInterval, sampleRate: Double) {
    lock.lock()
    sharedStart = cycleStart
    sharedRate = max(sampleRate, 8000)
    sharedGen &+= 1
    lock.unlock()
  }

  /// Render thread. Seconds since cycle start at the first frame of this buffer,
  /// and the cycle start it is measured from.
  func time(_ ts: UnsafePointer<AudioTimeStamp>?, frames: Int) -> (t: Double, cycleStart: TimeInterval, rate: Double) {
    if lock.try() {
      if sharedGen != gen {
        gen = sharedGen
        start = sharedStart
        rate = sharedRate
        anchor = nil  // re-anchor to the wall clock on every transport start
      }
      lock.unlock()
    }
    let key: Double
    if let ts, ts.pointee.mFlags.contains(.sampleTimeValid) {
      key = ts.pointee.mSampleTime
    } else {
      key = fallbackKey
      fallbackKey += Double(frames)
    }
    let wall = CACurrentMediaTime() - start
    if let a = anchor {
      let t = a.t + (key - a.key) / rate
      if abs(t - wall) < 0.08 { return (t, start, rate) }
    }
    // First use after a start, or a big slip (interruption, route change).
    anchor = (key, wall)
    return (wall, start, rate)
  }
}

/// Peak level feeding the master limiter, collected on the tap thread and read by
/// the UI tick. The limiter's threshold is 0 dBFS, so anything above 1.0 here is
/// how much it's pulling the mix down.
final class PeakMeter: @unchecked Sendable {
  private let lock = NSLock()
  private var peak: Float = 0

  func add(_ buffer: AVAudioPCMBuffer) {
    guard let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return }
    var m: Float = 0
    for c in 0..<Int(buffer.format.channelCount) {
      var v: Float = 0
      vDSP_maxmgv(ch[c], 1, &v, vDSP_Length(buffer.frameLength))
      m = max(m, v)
    }
    lock.lock()
    peak = max(peak, m)
    lock.unlock()
  }

  /// Highest peak since the last call.
  func take() -> Float {
    lock.lock()
    defer { peak = 0; lock.unlock() }
    return peak
  }
}

/// Tape machine on the keys channel. Not a noise layer: the processes that make tape
/// sound like tape, in the order a machine applies them.
///  1. Pre-emphasis (highs up ~3 kHz shelf) -> saturation -> de-emphasis, so loud
///     highs soften before lows do (tape's smooth, never-harsh top).
///  2. Saturation: smooth, slightly asymmetric soft clip (odd harmonics, a touch of
///     even), gently compressing peaks.
///  3. Head bump: small low lift around 80 Hz.
///  4. Top-end roll-off: 16 kHz -> 11 kHz as the amount rises.
///  5. Wow (~0.7 Hz) and flutter (~7 Hz), slightly irregular, shared by both channels.
///  6. Level compensation so the control changes character, not loudness.
/// At 0 it is bypassed (output untouched). Render thread only, apart from `amount`.
final class TapeSim: @unchecked Sendable {
  private let lock = NSLock()
  private var sharedAmount: Float = 0
  private var sharedRate: Double = 44100

  // Render thread.
  private var target: Float = 0
  private var amt: Float = 0
  /// 0...1 crossfade from the untouched signal to the tape path. Engaging adds the
  /// wobble's tiny delay, so switching on/off fades over 10 ms instead of jumping.
  private var engaged: Float = 0
  private var sr: Double = 44100
  private var ch = [Channel(), Channel()]
  private var delay = [[Float]](repeating: [Float](repeating: 0, count: 64), count: 2)
  private var w = 0
  private var wowPhase = 0.0, flutterPhase = 0.0
  private var wander = 0.0, wanderTarget = 0.0, wanderCount = 0
  private var rng = RTRandom()
  /// False only for measuring the rest of the chain without transport wobble.
  private let wobble: Bool

  init(wobble: Bool = true) {
    self.wobble = wobble
  }

  /// 2x oversampling filter around the saturator: 64-tap Blackman-windowed sinc,
  /// cutoff ~22 kHz at the 96 kHz rate. Saturation overtones above the base rate's
  /// Nyquist are filtered out instead of folding back as inharmonic grit.
  private static let taps = 64
  private static let fir: [Float] = {
    let n = taps, fc = 0.23
    var h = [Float](repeating: 0, count: n)
    let m = Double(n - 1) / 2
    for i in 0..<n {
      let x = Double(i) - m
      let sinc = x == 0 ? 2 * fc : sin(2 * Double.pi * fc * x) / (Double.pi * x)
      let w = 0.42 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1)) + 0.08 * cos(4 * Double.pi * Double(i) / Double(n - 1))
      h[i] = Float(sinc * w)
    }
    let sum = h.reduce(0, +)
    return h.map { $0 / sum }
  }()

  /// Per-channel filter state.
  private struct Channel {
    var emphLP: Float = 0       // splits pre-emphasis
    var deemphLP: Float = 0     // splits de-emphasis
    var up = [Float](repeating: 0, count: TapeSim.taps / 2)  // base-rate input history
    var upW = 0
    var down = [Float](repeating: 0, count: TapeSim.taps)    // 2x-rate saturated history
    var downW = 0
    var dc: Float = 0, dcIn: Float = 0
    var bump = Biquad()
    var top = Biquad()

    /// Back to silence without reallocating (safe on the render thread).
    mutating func clear() {
      emphLP = 0; deemphLP = 0; dc = 0; dcIn = 0
      for i in up.indices { up[i] = 0 }
      for i in down.indices { down[i] = 0 }
      upW = 0; downW = 0
      bump.z1 = 0; bump.z2 = 0; top.z1 = 0; top.z2 = 0
    }
  }

  struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0
    mutating func run(_ x: Float) -> Float {
      let y = b0 * x + z1
      z1 = b1 * x - a1 * y + z2
      z2 = b2 * x - a2 * y
      return y
    }
    /// RBJ peaking EQ.
    mutating func peak(f: Double, q: Double, gainDB: Double, sr: Double) {
      let A = pow(10, gainDB / 40), w0 = 2 * Double.pi * f / sr, al = sin(w0) / (2 * q)
      let a0 = 1 + al / A
      set(b0: (1 + al * A) / a0, b1: -2 * cos(w0) / a0, b2: (1 - al * A) / a0, a1: -2 * cos(w0) / a0, a2: (1 - al / A) / a0)
    }
    /// RBJ low-pass (Butterworth Q).
    mutating func lowpass(f: Double, sr: Double) {
      let w0 = 2 * Double.pi * min(f, sr * 0.45) / sr, al = sin(w0) / (2 * 0.7071), c = cos(w0), a0 = 1 + al
      set(b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0, a1: -2 * c / a0, a2: (1 - al) / a0)
    }
    private mutating func set(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
      self.b0 = Float(b0); self.b1 = Float(b1); self.b2 = Float(b2); self.a1 = Float(a1); self.a2 = Float(a2)
    }
  }

  /// Main thread.
  func set(amount: Float, sampleRate: Double) {
    lock.lock()
    sharedAmount = max(0, min(1, amount))
    sharedRate = max(8000, sampleRate)
    lock.unlock()
  }

  private func design() {
    let a = Double(amt)
    for c in 0..<2 {
      ch[c].bump.peak(f: 80, q: 0.9, gainDB: 2.0 * a, sr: sr)
      ch[c].top.lowpass(f: 16000 - 5000 * a, sr: sr)
    }
  }

  func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
    if lock.try() {
      target = sharedAmount
      if sharedRate != sr { sr = sharedRate; design() }
      lock.unlock()
    }
    // Fully off and settled: leave the audio untouched, and start clean next time.
    if target == 0 && engaged == 0 {
      if amt != 0 { reset() }
      return
    }
    let bufs = UnsafeMutableAudioBufferListPointer(list)
    guard frames > 0, let d0 = bufs[0].mData else { return }
    let L = d0.assumingMemoryBound(to: Float.self)
    let R: UnsafeMutablePointer<Float> = bufs.count > 1 && bufs[1].mData != nil
      ? bufs[1].mData!.assumingMemoryBound(to: Float.self) : L
    let chans = R == L ? 1 : 2
    // Smooth the control once per buffer (no zipper), redesign filters when it moves.
    let prevAmt = amt
    amt += (target - amt) * 0.25
    if abs(amt - prevAmt) > 0.0005 { design() }
    let a = amt
    let drive: Float = 1 + a * 3.2
    let emphK: Float = 1 + a * 1.5                                       // up to +8 dB shelf
    let emphA = Float(1 - exp(-2 * Double.pi * 3000 / sr))
    // Pre: (k s + w)/(s + w). Its exact inverse is a shelf cornered at w/k.
    let deemphA = Float(1 - exp(-2 * Double.pi * 3000 / Double(emphK) / sr))
    let bias: Float = 0.08 * a
    let makeup: Float = Self.nominal / Self.curve(drive * Self.nominal, bias: 0)  // keep level ~constant
    let wobbleAmt = wobble ? Double(a) : 0
    let wowDepth = 0.00055 * wobbleAmt * sr / (2 * Double.pi * 0.7)       // +/-0.055% pitch
    let flutterDepth = 0.00025 * wobbleAmt * sr / (2 * Double.pi * 7.1)   // +/-0.025% pitch
    let base = 8.0
    let fadeStep = Float(1 / (0.01 * sr))
    let fadeTo: Float = target > 0 ? 1 : 0
    for i in 0..<frames {
      if engaged != fadeTo { engaged = fadeTo > engaged ? min(1, engaged + fadeStep) : max(0, engaged - fadeStep) }
      let e = engaged
      // Transport: wow with a slowly wandering rate, plus flutter.
      if wanderCount <= 0 { wanderTarget = rng.unit() * 2 - 1; wanderCount = Int(sr * 0.25) }
      wanderCount -= 1
      wander += (wanderTarget - wander) * 0.00002
      wowPhase += 2 * Double.pi * 0.7 * (1 + 0.25 * wander) / sr
      flutterPhase += 2 * Double.pi * 7.1 / sr
      if wowPhase > 2 * Double.pi { wowPhase -= 2 * Double.pi }
      if flutterPhase > 2 * Double.pi { flutterPhase -= 2 * Double.pi }
      let dly = base + wowDepth * sin(wowPhase) + flutterDepth * sin(flutterPhase)
      for c in 0..<chans {
        let io = c == 0 ? L : R
        let dry = io[i]
        var x = dry
        // Pre-emphasis: split at 3 kHz, lift the highs into the saturator.
        ch[c].emphLP += emphA * (x - ch[c].emphLP)
        x = ch[c].emphLP + (x - ch[c].emphLP) * emphK
        // Saturation at 2x: upsample (polyphase), saturate both samples, downsample.
        x = saturate2x(&ch[c], x, drive: drive, bias: bias) * makeup
        // De-emphasis: the exact inverse shelf.
        ch[c].deemphLP += deemphA * (x - ch[c].deemphLP)
        x = ch[c].deemphLP + (x - ch[c].deemphLP) / emphK
        // Remove the DC the asymmetry adds.
        let y = x - ch[c].dcIn + 0.9995 * ch[c].dc
        ch[c].dcIn = x
        ch[c].dc = y
        x = ch[c].bump.run(y)
        x = ch[c].top.run(x)
        // Wow/flutter: fractional delay with 4-point Hermite interpolation.
        delay[c][w] = x
        let rpos = Double(w) - dly
        var ip = Int(floor(rpos))
        let f = Float(rpos - Double(ip))
        ip = (ip % 64 + 64) % 64
        let xm1 = delay[c][(ip + 63) % 64], x0 = delay[c][ip], x1 = delay[c][(ip + 1) % 64], x2 = delay[c][(ip + 2) % 64]
        let c1 = 0.5 * (x1 - xm1), c2 = xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2, c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
        let wet = ((c3 * f + c2) * f + c1) * f + x0
        io[i] = e >= 1 ? wet : dry + (wet - dry) * e
      }
      w = (w + 1) % 64
    }
  }

  /// Level the makeup gain holds constant (a typical keys level; measured to keep a
  /// keys chord within ~0.6 dB across the whole control).
  static let nominal: Float = 0.15

  @inline(__always) private func saturate2x(_ c: inout Channel, _ x: Float, drive: Float, bias: Float) -> Float {
    let h = Self.fir, half = Self.taps / 2
    c.up[c.upW] = x
    // Polyphase upsample: even and odd phases of the filter (x2 for the zero stuffing).
    var u0: Float = 0, u1: Float = 0
    var idx = c.upW
    for k in 0..<half {
      let v = c.up[idx]
      u0 += h[2 * k] * v
      u1 += h[2 * k + 1] * v
      idx = idx == 0 ? half - 1 : idx - 1
    }
    c.upW = (c.upW + 1) % half
    // Saturate at the 2x rate, then filter and keep every other sample.
    c.down[c.downW] = Self.curve(u0 * 2 * drive, bias: bias)
    c.downW = (c.downW + 1) % Self.taps
    c.down[c.downW] = Self.curve(u1 * 2 * drive, bias: bias)
    var y: Float = 0
    var j = c.downW
    for k in 0..<Self.taps {
      y += h[k] * c.down[j]
      j = j == 0 ? Self.taps - 1 : j - 1
    }
    c.downW = (c.downW + 1) % Self.taps
    return y
  }

  private func reset() {
    amt = 0
    ch[0].clear()  // in place: no allocation on the render thread
    ch[1].clear()
    for c in 0..<2 { for k in 0..<64 { delay[c][k] = 0 } }
    design()
  }

  /// Soft, slightly asymmetric saturation curve (x / (1 + |x|^2.5)^(1/2.5)).
  @inline(__always) static func curve(_ x: Float, bias: Float) -> Float {
    let u = x + bias
    let m = powf(1 + powf(abs(u), 2.5), 0.4)
    let b = bias / powf(1 + powf(abs(bias), 2.5), 0.4)
    return u / m - b
  }
}

/// Builds render callbacks in a file with no @MainActor types so the audio
/// thread never hops to the UI. Closures created inside LoopEngine.attachGraph
/// were isolated to the main actor — that underruns (echoey clicks) and
/// deadlocks when the UI does work at loop close.
enum AudioGraph {
  static func synthNode(
    format: AVAudioFormat,
    synth: LiveSynth,
    sampler: LiveSampler,
    tape: TapeSim,
    outRate: Double
  ) -> AVAudioSourceNode {
    let synth = synth
    let sampler = sampler
    let tape = tape
    let outRate = outRate
    return AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
      synth.render(frames: Int(frameCount), list: abl)
      sampler.renderAdd(frames: Int(frameCount), list: abl, dstRate: outRate)
      // Tape sits on the keys channel, before its delay and reverb.
      tape.process(abl, frames: Int(frameCount))
      return noErr
    }
  }

  /// Meters the signal going into the master limiter for the limiter light.
  static func installMeterTap(on node: AVAudioNode, format: AVAudioFormat, meter: PeakMeter) {
    let meter = meter
    node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      meter.add(buffer)
    }
  }

  /// Always-on tap, installed before engine.start. Captures keys after delay/reverb.
  static func installPostTap(on node: AVAudioNode, format: AVAudioFormat, layers: LiveLayers) {
    let layers = layers
    node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      layers.punchIn(buffer: buffer)
    }
  }

  static func layerNode(format: AVAudioFormat, layers: LiveLayers, slot: Int) -> AVAudioSourceNode {
    let layers = layers
    let slot = slot
    return AVAudioSourceNode(format: format) { _, ts, frameCount, abl -> OSStatus in
      layers.render(slot: slot, frames: Int(frameCount), list: abl, timestamp: ts)
      return noErr
    }
  }

  static func drumsNode(format: AVAudioFormat, drums: LiveDrums) -> AVAudioSourceNode {
    let drums = drums
    return AVAudioSourceNode(format: format) { _, ts, frameCount, abl -> OSStatus in
      drums.render(frames: Int(frameCount), list: abl, timestamp: ts)
      return noErr
    }
  }

  static func metroNode(format: AVAudioFormat, metro: LiveMetro) -> AVAudioSourceNode {
    let metro = metro
    return AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
      metro.render(frames: Int(frameCount), list: abl)
      return noErr
    }
  }
}
