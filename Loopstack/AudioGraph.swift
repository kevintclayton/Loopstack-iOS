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
  private var publishPending = false
  /// The render thread's current sample-time → transport-time mapping, for the record
  /// tap (tap timestamps share the render sample timeline, measured exact to the sample).
  private var sharedAnchor: (key: Double, t: Double, gen: UInt64)?

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
      if abs(t - wall) < 0.08 {
        publishAnchor()
        return (t, start, rate)
      }
    }
    // First use after a start, or a big slip (interruption, route change).
    anchor = (key, wall)
    publishPending = true
    publishAnchor()
    return (wall, start, rate)
  }

  /// Render thread. Shares a new anchor with the tap; retried next buffer if the lock is busy.
  private func publishAnchor() {
    guard publishPending, let a = anchor, lock.try() else { return }
    sharedAnchor = (a.key, a.t, gen)
    publishPending = false
    lock.unlock()
  }

  /// Tap thread. Transport time (seconds since cycle start) of a render sample time, or
  /// nil until the render thread has anchored the current transport start.
  func transportTime(sampleTime: Double) -> Double? {
    lock.lock()
    defer { lock.unlock() }
    guard let a = sharedAnchor, a.gen == sharedGen else { return nil }
    return a.t + (sampleTime - a.key) / sharedRate
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
  private var sharedWear: Float = 0
  private var sharedRate: Double = 44100

  // Render thread.
  private var target: Float = 0
  private var amt: Float = 0
  private var targetWear: Float = 0
  private var wear: Float = 0
  /// Wobble delay line length (power of two): room for Wear's deep, slow pitch bends.
  private static let lineLen = 2048
  /// Base delay (samples) glides with Wear so turning it up never jumps.
  private var base = 8.0
  private var wornPhase = 0.0, slowPhase = 0.0
  private var dropPos = 0, dropLen = 0
  private var dropFloor: Float = 1
  /// Samples written since engaging: the crossfade in waits until the line holds audio.
  private var filled = 0
  /// 0...1 crossfade from the untouched signal to the tape path. Engaging adds the
  /// wobble's tiny delay, so switching on/off fades over 10 ms instead of jumping.
  private var engaged: Float = 0
  private var sr: Double = 44100
  private var ch = [Channel(), Channel()]
  // Built separately so each channel owns its storage (a shared copy would be
  // duplicated on first write, on the render thread).
  private var delay: [[Float]] = (0..<2).map { _ in [Float](repeating: 0, count: TapeSim.lineLen) }
  private var w = 0
  private var wowPhase = 0.0, flutterPhase = 0.0
  private var wander = 0.0, wanderTarget = 0.0, wanderCount = 0
  private var rng = RTRandom()
  /// False only for measuring the rest of the chain without transport wobble.
  private let wobble: Bool
  /// Level the makeup gain holds constant: the signal's typical level (keys ~0.15;
  /// the drum bus runs hotter).
  private let nominal: Float
  /// Per-channel block scratch. Raw memory (allocated once) so the block stages never
  /// overlap Swift's exclusive access to the channel state.
  private let scratch: [UnsafeMutablePointer<Float>]

  init(wobble: Bool = true, nominal: Float = TapeSim.keysNominal) {
    self.wobble = wobble
    self.nominal = nominal
    scratch = (0..<2).map { _ in
      let p = UnsafeMutablePointer<Float>.allocate(capacity: Oversampler2x.maxFrames)
      p.initialize(repeating: 0, count: Oversampler2x.maxFrames)
      return p
    }
  }

  deinit {
    for p in scratch { p.deallocate() }
  }

  /// 2x oversampling filter around the saturator: 64-tap Blackman-windowed sinc,
  /// cutoff ~22 kHz at the 96 kHz rate. Saturation overtones above the base rate's
  /// Nyquist are filtered out instead of folding back as inharmonic grit.
  static let taps = 64
  static let fir: [Float] = {
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
    var ov = Oversampler2x()
    var dc: Float = 0, dcIn: Float = 0
    var bump = Biquad()
    var top = SVFLowpass()

    /// Back to silence without reallocating (safe on the render thread).
    mutating func clear() {
      emphLP = 0; deemphLP = 0; dc = 0; dcIn = 0
      ov.clear()
      bump.z1 = 0; bump.z2 = 0; top.clear()
    }
  }

  /// 2-pole low-pass, state-variable (TPT) form: its cutoff can move while audio runs
  /// without the transients a biquad makes when its coefficients jump (Wear sweeps the
  /// top end from 16 kHz to ~4.5 kHz). Butterworth Q, same response as the RBJ low-pass.
  struct SVFLowpass {
    private var ic1: Float = 0, ic2: Float = 0
    private var a1: Float = 1, a2: Float = 0, a3: Float = 0

    mutating func set(f: Double, sr: Double) {
      let g = tan(Double.pi * min(f, sr * 0.45) / sr), k = 2.0.squareRoot()
      let d = 1 / (1 + g * (g + k))
      a1 = Float(d)
      a2 = Float(g * d)
      a3 = Float(g * g * d)
    }

    mutating func run(_ v0: Float) -> Float {
      let v3 = v0 - ic2
      let v1 = a1 * ic1 + a2 * v3
      let v2 = ic2 + a2 * ic1 + a3 * v3
      ic1 = 2 * v1 - ic1
      ic2 = 2 * v2 - ic2
      return v2
    }

    mutating func clear() { ic1 = 0; ic2 = 0 }
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

  /// Wear: the tape's condition, from pristine to worn out and running at the wrong
  /// speed (deep irregular warble, slow drift, dull top, dropouts). Main thread.
  func set(wear: Float) {
    lock.lock()
    sharedWear = max(0, min(1, wear))
    lock.unlock()
  }

  private func design() {
    let a = Double(amt), wr = Double(wear)
    for c in 0..<2 {
      ch[c].bump.peak(f: 80, q: 0.9, gainDB: 2.0 * a, sr: sr)
      // Worn oxide loses the top end: 16 kHz down to ~4.5 kHz at full Wear.
      ch[c].top.set(f: min(16000 - 5000 * a, 16000 - 11500 * wr), sr: sr)
    }
  }

  func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
    if lock.try() {
      target = sharedAmount
      targetWear = sharedWear
      if sharedRate != sr { sr = sharedRate; design() }
      lock.unlock()
    }
    // Fully off and settled: leave the audio untouched, and start clean next time.
    if target == 0 && targetWear == 0 && engaged == 0 {
      if amt != 0 || wear != 0 { reset() }
      return
    }
    let bufs = UnsafeMutableAudioBufferListPointer(list)
    guard frames > 0, let d0 = bufs[0].mData else { return }
    let L = d0.assumingMemoryBound(to: Float.self)
    let R: UnsafeMutablePointer<Float> = bufs.count > 1 && bufs[1].mData != nil
      ? bufs[1].mData!.assumingMemoryBound(to: Float.self) : L
    let chans = R == L ? 1 : 2
    // Smooth the control once per buffer (no zipper), redesign filters when it moves.
    let prevAmt = amt, prevWear = wear
    amt += (target - amt) * 0.25
    wear += (targetWear - wear) * 0.25
    if abs(amt - prevAmt) > 0.0005 || abs(wear - prevWear) > 0.0005 { design() }
    let a = amt
    let drive: Float = 1 + a * 3.2
    let emphK: Float = 1 + a * 1.5                                       // up to +8 dB shelf
    let emphA = Float(1 - exp(-2 * Double.pi * 3000 / sr))
    // Pre: (k s + w)/(s + w). Its exact inverse is a shelf cornered at w/k.
    let deemphA = Float(1 - exp(-2 * Double.pi * 3000 / Double(emphK) / sr))
    let bias: Float = 0.08 * a
    let makeup: Float = nominal / Self.curve(drive * nominal, bias: 0)  // keep level ~constant
    let wobbleAmt = wobble ? Double(a) : 0
    let wowDepth = 0.00055 * wobbleAmt * sr / (2 * Double.pi * 0.7)       // +/-0.055% pitch
    let flutterDepth = 0.00025 * wobbleAmt * sr / (2 * Double.pi * 7.1)   // +/-0.025% pitch
    // Worn tape: deep slow warble (+/-1.2% pitch, ~0.55 Hz, wandering), a slower speed
    // drift (+/-0.4%, 0.11 Hz) and extra flutter (+/-0.15%). Depths are delay swings.
    let wr = wobble ? Double(wear) : 0
    let wornDepth = 0.012 * wr * sr / (2 * Double.pi * 0.55)
    let slowDepth = 0.004 * wr * sr / (2 * Double.pi * 0.11)
    let wornFlutter = 0.0015 * wr * sr / (2 * Double.pi * 7.1)
    let totalDepth = wowDepth + flutterDepth + wornDepth + slowDepth + wornFlutter
    let baseTarget = 8 + 1.15 * totalDepth
    // Engaging from bypass: start at the right delay (the crossfade covers the change).
    if engaged == 0 && filled == 0 { base = baseTarget }
    let dropRate = 0.4 * Double(wear) / sr                                // dropouts per sample
    let mask = Self.lineLen - 1
    let fadeStep = Float(1 / (0.01 * sr))
    let fadeTo: Float = target > 0 || targetWear > 0 ? 1 : 0
    var start = 0
    while start < frames {
      let n = min(Oversampler2x.maxFrames, frames - start)
      // Per channel, over the whole chunk: pre-emphasis, 2x-oversampled saturation (block),
      // then de-emphasis, DC removal, head bump and top roll-off.
      for c in 0..<chans {
        let io = (c == 0 ? L : R) + start
        let t = scratch[c]
        for i in 0..<n {
          let x = io[i]
          ch[c].emphLP += emphA * (x - ch[c].emphLP)
          t[i] = ch[c].emphLP + (x - ch[c].emphLP) * emphK
        }
        ch[c].ov.process(t, n, drive: drive, bias: bias, makeup: makeup)
        for i in 0..<n {
          var x = t[i]
          ch[c].deemphLP += deemphA * (x - ch[c].deemphLP)
          x = ch[c].deemphLP + (x - ch[c].deemphLP) / emphK
          let y = x - ch[c].dcIn + 0.9995 * ch[c].dc
          ch[c].dcIn = x
          ch[c].dc = y
          x = ch[c].bump.run(y)
          t[i] = ch[c].top.run(x)
        }
      }
      // Per sample: the shared transport wobble and the on/off crossfade.
      for i in 0..<n {
        if filled < Self.lineLen { filled += 1 }
        // Fade in only once the line holds more audio than the delay reads back.
        let ready = Double(filled) > base + 4
        if engaged != fadeTo, fadeTo == 0 || ready {
          engaged = fadeTo > engaged ? min(1, engaged + fadeStep) : max(0, engaged - fadeStep)
        }
        let e = engaged
        if wanderCount <= 0 { wanderTarget = rng.unit() * 2 - 1; wanderCount = Int(sr * 0.25) }
        wanderCount -= 1
        wander += (wanderTarget - wander) * 0.00002
        wowPhase += 2 * Double.pi * 0.7 * (1 + 0.25 * wander) / sr
        flutterPhase += 2 * Double.pi * 7.1 / sr
        wornPhase += 2 * Double.pi * 0.55 * (1 + 0.35 * wander) / sr
        slowPhase += 2 * Double.pi * 0.11 * (1 - 0.3 * wander) / sr
        if wowPhase > 2 * Double.pi { wowPhase -= 2 * Double.pi }
        if flutterPhase > 2 * Double.pi { flutterPhase -= 2 * Double.pi }
        if wornPhase > 2 * Double.pi { wornPhase -= 2 * Double.pi }
        if slowPhase > 2 * Double.pi { slowPhase -= 2 * Double.pi }
        base += (baseTarget - base) * 0.0002
        // The swing can never exceed the delay available, so the read never gets ahead of
        // the write; as Wear rises the base glides up and the warble grows with it.
        let k = totalDepth > 0 ? min(1, max(0, (base - 4) / totalDepth)) : 0
        let dly = base + k * (wowDepth * sin(wowPhase) + (flutterDepth + wornFlutter) * sin(flutterPhase)
          + wornDepth * sin(wornPhase) + slowDepth * sin(slowPhase))
        // Dropouts: worn oxide briefly loses level (3-9 dB, 40-200 ms, smooth edges).
        var dropGain: Float = 1
        if dropLen == 0 {
          if rng.unit() < dropRate {
            dropLen = Int(sr * (0.04 + 0.16 * rng.unit()))
            dropPos = 0
            dropFloor = powf(10, -Float(3 + 6 * rng.unit()) * wear / 20)
          }
        } else {
          dropGain = 1 - (1 - dropFloor) * Float(sin(Double.pi * Double(dropPos) / Double(dropLen)))
          dropPos += 1
          if dropPos >= dropLen { dropLen = 0 }
        }
        for c in 0..<chans {
          let io = (c == 0 ? L : R) + start
          let dry = io[i]
          // Wow/flutter: fractional delay with 4-point Hermite interpolation.
          delay[c][w] = scratch[c][i]
          let rpos = Double(w) - dly
          var ip = Int(floor(rpos))
          let f = Float(rpos - Double(ip))
          ip &= mask
          let xm1 = delay[c][(ip - 1) & mask], x0 = delay[c][ip], x1 = delay[c][(ip + 1) & mask], x2 = delay[c][(ip + 2) & mask]
          let c1 = 0.5 * (x1 - xm1), c2 = xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2, c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
          let wet = (((c3 * f + c2) * f + c1) * f + x0) * dropGain
          io[i] = e >= 1 ? wet : dry + (wet - dry) * e
        }
        w = (w + 1) & mask
      }
      start += n
    }
  }

  /// Keys level the makeup gain holds constant (measured to keep a keys chord within
  /// ~0.6 dB across the whole control).
  static let keysNominal: Float = 0.15

  /// Render thread: how late the tape path currently plays (the wobble's base delay,
  /// weighted by the on/off crossfade), in samples. The drums read ahead by this so
  /// the beat stays on the grid.
  var latency: Double { Double(engaged) * (base + Self.pathLatency) }
  /// The saturator's oversampling filters, in base-rate samples (measured: 0.73 ms at 48 kHz).
  static let pathLatency = 35.0



  private func reset() {
    amt = 0
    wear = 0
    base = 8
    dropLen = 0
    filled = 0
    ch[0].clear()  // in place: no allocation on the render thread
    ch[1].clear()
    for c in 0..<2 { for k in 0..<Self.lineLen { delay[c][k] = 0 } }
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

/// 2x oversampled saturation over a whole buffer, done with Accelerate so it's cheap in
/// any build. (The per-sample Swift version cost ~90% of a core per loop in Debug builds
/// and broke up the audio.) Same filter and curve as before: zero-stuff to 2x, 64-tap
/// low-pass, soft curve u/(1+|u|^2.5)^0.4 (with optional bias), low-pass and keep every
/// other sample. Overlap-save history carries across buffers. Render thread only.
struct Oversampler2x {
  static let maxFrames = 4096
  private static let hist = TapeSim.taps - 1
  private var up: [Float]
  private var down: [Float]
  private var mag: [Float]

  init() {
    up = [Float](repeating: 0, count: Self.hist + 2 * Self.maxFrames)
    down = [Float](repeating: 0, count: Self.hist + 2 * Self.maxFrames)
    mag = [Float](repeating: 0, count: 2 * Self.maxFrames)
  }

  /// In place on `x[0..<n]` (n <= maxFrames): output = curve(drive * x + bias) - curve(bias), * makeup.
  mutating func process(_ x: UnsafeMutablePointer<Float>, _ n: Int, drive: Float, bias: Float, makeup: Float) {
    guard n > 0, n <= Self.maxFrames else { return }
    let H = Self.hist, taps = TapeSim.taps, n2 = 2 * n
    let fir = TapeSim.fir
    // The curve's value at zero input (the DC the bias adds); subtracting it matches TapeSim.curve.
    let offset = -(bias / powf(1 + powf(abs(bias), 2.5), 0.4))
    up.withUnsafeMutableBufferPointer { U in
      down.withUnsafeMutableBufferPointer { D in
        mag.withUnsafeMutableBufferPointer { M in
          fir.withUnsafeBufferPointer { F in
            let u = U.baseAddress!, d = D.baseAddress!, m = M.baseAddress!, f = F.baseAddress!
            // Zero-stuff into the upsampling buffer after its history (x2 for the zeros).
            vDSP_vclr(u + H, 1, vDSP_Length(n2))
            var two: Float = 2
            vDSP_vsmul(x, 1, &two, u + H, 2, vDSP_Length(n))
            // Low-pass at 2x (filter is symmetric, so correlation == convolution).
            vDSP_conv(u, 1, f, 1, d + H, 1, vDSP_Length(n2), vDSP_Length(taps))
            memmove(u, u + n2, H * MemoryLayout<Float>.size)
            // Saturate at 2x: y = v / (1 + |v|^2.5)^0.4, v = drive*u + bias.
            var g = drive, b = bias, one: Float = 1, e1: Float = 2.5, e2: Float = 0.4, off = offset
            var count = Int32(n2)
            vDSP_vsmsa(d + H, 1, &g, &b, d + H, 1, vDSP_Length(n2))
            vDSP_vabs(d + H, 1, m, 1, vDSP_Length(n2))
            vvpowsf(m, &e1, m, &count)
            vDSP_vsadd(m, 1, &one, m, 1, vDSP_Length(n2))
            vvpowsf(m, &e2, m, &count)
            vDSP_vdiv(m, 1, d + H, 1, d + H, 1, vDSP_Length(n2))
            vDSP_vsadd(d + H, 1, &off, d + H, 1, vDSP_Length(n2))
            // Low-pass and keep every other sample, then level.
            vDSP_desamp(d, 2, f, x, vDSP_Length(n), vDSP_Length(taps))
            var mk = makeup
            vDSP_vsmul(x, 1, &mk, x, 1, vDSP_Length(n))
            memmove(d, d + n2, H * MemoryLayout<Float>.size)
          }
        }
      }
    }
  }

  /// Back to silence in place (no allocation).
  mutating func clear() {
    up.withUnsafeMutableBufferPointer { vDSP_vclr($0.baseAddress!, 1, vDSP_Length($0.count)) }
    down.withUnsafeMutableBufferPointer { vDSP_vclr($0.baseAddress!, 1, vDSP_Length($0.count)) }
  }
}

/// Per-loop Drive gain law: the tape effect's soft curve (processed by Oversampler2x),
/// level-compensated so the control adds character rather than volume.
enum Drive2x {
  /// Input gain for a 0...1 control, and the makeup that holds a typical level.
  static func gains(_ amount: Float) -> (drive: Float, makeup: Float) {
    let g = 1 + max(0, min(1, amount)) * 5
    let nominal: Float = 0.15
    return (g, nominal / TapeSim.curve(g * nominal, bias: 0))
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
    arp: LiveArp,
    clock: TransportClock,
    outRate: Double
  ) -> AVAudioSourceNode {
    let synth = synth
    let sampler = sampler
    let tape = tape
    let arp = arp
    let clock = clock
    let outRate = outRate
    return AVAudioSourceNode(format: format) { _, ts, frameCount, abl -> OSStatus in
      // The arp places this buffer's steps on the synth before it renders.
      arp.process(ts, frames: Int(frameCount), clock: clock, synth: synth)
      synth.render(frames: Int(frameCount), list: abl)
      sampler.renderAdd(frames: Int(frameCount), list: abl, dstRate: outRate,
                        pitchMod: synth.pitchMod, pitchModFrames: synth.pitchModFrames)
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
    node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, when in
      layers.punchIn(buffer: buffer, when: when)
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

  static func drumsNode(format: AVAudioFormat, drums: LiveDrums, tape: TapeSim) -> AVAudioSourceNode {
    let drums = drums
    let tape = tape
    let sr = format.sampleRate
    return AVAudioSourceNode(format: format) { _, ts, frameCount, abl -> OSStatus in
      // Read the beat early by the tape's delay, so through the tape it lands on the grid.
      drums.render(frames: Int(frameCount), list: abl, timestamp: ts, ahead: tape.latency / sr)
      tape.process(abl, frames: Int(frameCount))
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
