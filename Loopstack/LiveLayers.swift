import AVFoundation
import Foundation

/// A take is one full cycle, whenever record is pressed: each tap buffer is written at its
/// place in the cycle (from its render timestamp, not the wall clock, which smeared
/// writes), wrapping round until the whole loop is filled, and the join is crossfaded.
/// Playback reads 0..<n on a sample counter, sample 0 on the cycle start.
///
/// Threading: control threads (UI, record tap) change `slots` under `lock`. The
/// render thread never waits on it: it syncs its own copy with `lock.try()` and,
/// if the lock is busy, plays on with the copy it has. Buffers the renderer may
/// still hold are retired, not freed, until it has synced past them.
final class LiveLayers: @unchecked Sendable {
  struct Slot {
    var left: [Float] = []
    var right: [Float] = []
    var revL: [Float] = []
    var revR: [Float] = []
    var n = 0
    var gain: Float = 0.9
    var pan: Float = 0
    var muted = false
    var reversed = false
    var active = false
    /// Per-loop Drive 0...1 (applied at playback, non-destructive).
    var drive: Float = 0
    /// Playback speed: 1, or 0.5 for half speed (an octave down, over two cycles).
    var rate: Double = 1
    var rateGen = 0
    /// Bumped whenever playback should (re)start (activation, transport start, replacement).
    var activation = 0
    var activatedAt: TimeInterval = 0
    /// Place the loop on the transport timeline (transport start) rather than at 0.
    var align = false
    /// Where in the cycle (seconds) sample 0 plays, when the take knows it; -1 to learn it.
    var phase: Double = -1
  }

  /// Render-thread copy of a slot plus its playhead.
  private struct Voice {
    var left: [Float] = []
    var right: [Float] = []
    var revL: [Float] = []
    var revR: [Float] = []
    var n = 0
    var gain: Float = 0.9
    var pan: Float = 0
    var muted = false
    var reversed = false
    var active = false
    var activation = 0
    /// Position in samples. Whole numbers at normal speed (read exactly, as before);
    /// fractional at half speed (cubic interpolation).
    var playhead: Double = 0
    var rate: Double = 1
    var rateGen = 0
    /// Speed change: the old position fades out over 10 ms while the new one fades in.
    var xHead: Double = 0
    var xRate: Double = 1
    var xLeft = 0
    var xLen = 1
    var drive: Float = 0
    /// Crossfade into the Drive path (it adds the oversampler's ~0.7 ms delay, so
    /// switching it on/off fades over 10 ms instead of jumping).
    var driveMix: Float = 0
    var ovL = Oversampler2x()
    var ovR = Oversampler2x()
    /// Where in the cycle (seconds) this loop's first sample plays; learned the first
    /// time it plays, then used to place it whenever the transport starts.
    var phase: Double = 0
    /// Frames of silence before the transport's start time arrives.
    var wait = 0
    /// Frames left of a 5 ms fade-in after starting mid-loop (no click from silence).
    var fadeIn = 0
  }

  /// Slot count is fixed, so index checks outside the lock don't read `slots`.
  private static let slotRange = 0..<8

  private let lock = NSLock()
  private var slots: [Slot] = Array(repeating: Slot(), count: slotRange.count)
  private var recIndex = 0
  private var recWritten = 0
  private var recording = false
  /// Cycle frame the take's first sample lands on; -1 until the first buffer arrives.
  private var recStart = -1
  /// Whether recStart came from a timestamp (else the old way: phase learned at playback).
  private var recAligned = false
  /// Frames waited for a timestamp before falling back.
  private var recSkipped = 0
  /// What was played just past a full cycle, crossfaded over the take's first frames so
  /// the join (where record was pressed) is seamless.
  private var recTailL: [Float] = []
  private var recTailR: [Float] = []
  private var complete = false
  private var sampleRate: Double = 44100
  private var gen: UInt64 = 0
  /// Shared with the drums: loops are placed on the same timeline.
  private let clock: TransportClock
  private var seenGen: UInt64 = 0
  private var retired = RetireBin()

  // Render thread only.
  private var sampleRateForRender: Double = 44100
  // Built one by one so every voice owns its saturator buffers (a repeated copy would
  // share them and be duplicated on first use, on the render thread).
  private var voices: [Voice] = slotRange.map { _ in Voice() }
  /// Per-voice block scratch (dry L/R, driven L/R), raw memory allocated once so the
  /// block stages never overlap Swift's exclusive access to `voices`.
  private let scratch: [[UnsafeMutablePointer<Float>]] = slotRange.map { _ in
    (0..<4).map { _ in
      let p = UnsafeMutablePointer<Float>.allocate(capacity: Oversampler2x.maxFrames)
      p.initialize(repeating: 0, count: Oversampler2x.maxFrames)
      return p
    }
  }

  deinit {
    for v in scratch { for p in v { p.deallocate() } }
  }
  private var renderGen: UInt64 = 0

  init(clock: TransportClock) {
    self.clock = clock
  }

  /// The transport timeline itself lives in the shared TransportClock; only the
  /// rate is needed here.
  func setClock(start: TimeInterval, dur: Double, sampleRate: Double) {
    _ = start; _ = dur
    lock.lock()
    self.sampleRate = max(sampleRate, 8000)
    changed()
    lock.unlock()
  }

  /// Call with lock held after changing anything the renderer reads.
  private func changed() {
    gen &+= 1
  }

  /// Call with lock held; the returned batch must be dropped after unlocking.
  private func retire(_ slot: Slot) {
    retired.retire([slot.left, slot.right, slot.revL, slot.revR], gen: gen &+ 1)
  }

  /// Frees buffers the renderer has let go of. Call from the UI tick.
  func collect() {
    lock.lock()
    let dead = retired.collect(seen: seenGen)
    lock.unlock()
    _ = dead
  }

  func beginRecord(index: Int, frames: Int, gain: Float) {
    guard Self.slotRange.contains(index), frames > 1 else { return }
    let n = frames
    var slot = Slot()
    slot.left = [Float](repeating: 0, count: n)
    slot.right = [Float](repeating: 0, count: n)
    slot.revL = [Float](repeating: 0, count: n)
    slot.revR = [Float](repeating: 0, count: n)
    slot.n = n
    slot.gain = gain
    lock.lock()
    retire(slots[index])
    slot.activation = slots[index].activation &+ 1
    slots[index] = slot
    recIndex = index
    recWritten = 0
    recStart = -1
    recAligned = false
    recSkipped = 0
    let xf = max(1, min(n / 4, Int(0.01 * sampleRate)))
    recTailL = [Float](repeating: 0, count: xf)
    recTailR = [Float](repeating: 0, count: xf)
    recording = true
    complete = false
    changed()
    let dead = retired.collect(seen: seenGen)
    lock.unlock()
    _ = dead
  }

  #if DEBUG
  /// Screenshot demo only: puts a finished take in a slot, as if it had just been
  /// recorded (it starts playing on the next transport start, from the downbeat).
  func debugInstall(index: Int, l: [Float], r: [Float]) {
    guard Self.slotRange.contains(index), l.count > 1, r.count == l.count else { return }
    var slot = Slot()
    slot.left = l
    slot.right = r
    slot.revL = l.reversed()
    slot.revR = r.reversed()
    slot.n = l.count
    slot.gain = 0.9
    slot.phase = 0
    lock.lock()
    retire(slots[index])
    slot.activation = slots[index].activation &+ 1
    slots[index] = slot
    changed()
    let dead = retired.collect(seen: seenGen)
    lock.unlock()
    _ = dead
  }
  #endif

  func punchIn(buffer: AVAudioPCMBuffer, when: AVAudioTime? = nil) {
    guard let data = buffer.floatChannelData else { return }
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return }
    let srcL = data[0]
    let srcR = buffer.format.channelCount > 1 ? data[1] : data[0]
    // Outside our lock: the clock has its own.
    let t0 = when.flatMap { $0.isSampleTimeValid ? clock.transportTime(sampleTime: Double($0.sampleTime)) : nil }
    lock.lock()
    defer { lock.unlock() }
    guard recording, slots.indices.contains(recIndex) else { return }
    let n = slots[recIndex].n
    guard n > 1, slots[recIndex].left.count == n else { return }
    let sr = sampleRate
    var from = 0
    if recStart < 0 {
      if let t0 {
        // Nothing from before the transport starts (the click lead-in).
        let skip = t0 < 0 ? Int((-t0 * sr).rounded(.up)) : 0
        if skip >= frames { return }
        from = skip
        let f = Int((t0 * sr).rounded()) + from
        recStart = ((f % n) + n) % n
        recAligned = true
      } else {
        recSkipped += frames
        if recSkipped < Int(0.25 * sr) { return }
        recStart = 0
        recAligned = false
      }
    }
    // The slot isn't active yet, so the renderer holds no reference to these
    // arrays and writing in place never triggers a copy.
    let xf = recTailL.count
    let total = n + xf
    var k = recWritten
    var i = from
    while i < frames, k < total {
      if k < n {
        let idx = (recStart + k) % n
        slots[recIndex].left[idx] = srcL[i]
        slots[recIndex].right[idx] = srcR[i]
      } else {
        recTailL[k - n] = srcL[i]
        recTailR[k - n] = srcR[i]
      }
      k += 1
      i += 1
    }
    recWritten = k
    if recWritten >= total { closeTake() }
  }

  /// Lock held. The whole cycle is in: blend the overrun into the take's start so the
  /// join plays straight through, and start the loop at its place in the cycle.
  private func closeTake() {
    let i = recIndex, n = slots[i].n, xf = recTailL.count
    for j in 0..<xf {
      let idx = (recStart + j) % n
      let g = Float(j) / Float(xf)
      slots[i].left[idx] = slots[i].left[idx] * g + recTailL[j] * (1 - g)
      slots[i].right[idx] = slots[i].right[idx] * g + recTailR[j] * (1 - g)
    }
    recording = false
    activate(i)
    if recAligned {
      slots[i].align = true
      slots[i].phase = 0
    }
    complete = true
  }

  /// UI: where in the cycle the take began (0..<1, or nil before its first buffer) and
  /// how much of the loop it has (0...1). Nil when not recording.
  func captureProgress() -> (start: Double?, done: Double)? {
    lock.lock()
    defer { lock.unlock() }
    guard recording, slots.indices.contains(recIndex), slots[recIndex].n > 1 else { return nil }
    let n = slots[recIndex].n
    guard recStart >= 0 else { return (nil, 0) }
    return (Double(recStart) / Double(n), min(1, Double(recWritten) / Double(n)))
  }

  func endRecord(activate on: Bool) {
    lock.lock()
    recording = false
    // punchIn already started playback when the take filled; resetting the playhead
    // again here (up to one UI tick later) jumped the loop back to 0 and tore.
    if on, slots.indices.contains(recIndex), !slots[recIndex].active {
      declick(recIndex, length: recWritten)
      activate(recIndex)
    }
    complete = on
    lock.unlock()
  }

  /// Lock held. Starts the slot from its first sample.
  private func activate(_ i: Int) {
    slots[i].active = true
    slots[i].activation &+= 1
    slots[i].activatedAt = CACurrentMediaTime()
    slots[i].align = false
    changed()
  }

  /// Transport start (play/resume/record from stop): every recorded loop is placed
  /// on the transport timeline set by `setClock`, together with drums and metronome.
  func restartAll() {
    lock.lock()
    for i in slots.indices where slots[i].n > 1 {
      slots[i].active = true
      slots[i].activation &+= 1
      slots[i].align = true
    }
    changed()
    lock.unlock()
  }

  /// Short fade at both ends of a take so the first entry and every wrap
  /// start and end near zero instead of jumping mid-waveform. Call with lock held.
  private func declick(_ i: Int, length: Int) {
    let len = min(length, slots[i].left.count, slots[i].right.count)
    let f = min(128, len / 4)
    guard f > 1 else { return }
    for k in 0..<f {
      let g = Float(k) / Float(f)
      slots[i].left[k] *= g
      slots[i].right[k] *= g
      slots[i].left[len - 1 - k] *= g
      slots[i].right[len - 1 - k] *= g
    }
  }

  func consumeComplete() -> Bool {
    lock.lock()
    let c = complete
    complete = false
    lock.unlock()
    return c
  }

  func snapshot(index: Int) -> (l: [Float], r: [Float])? {
    lock.lock()
    defer { lock.unlock() }
    guard slots.indices.contains(index), slots[index].n > 1 else { return nil }
    return (slots[index].left, slots[index].right)
  }

  func setReverse(index: Int, buffer: AVAudioPCMBuffer) {
    guard Self.slotRange.contains(index), let ch = buffer.floatChannelData else { return }
    let frames = Int(buffer.frameLength)
    guard frames > 1 else { return }
    let L = Array(UnsafeBufferPointer(start: ch[0], count: frames))
    let R = buffer.format.channelCount > 1
      ? Array(UnsafeBufferPointer(start: ch[1], count: frames))
      : L
    lock.lock()
    retired.retire([slots[index].revL, slots[index].revR], gen: gen &+ 1)
    slots[index].revL = L
    slots[index].revR = R
    changed()
    let dead = retired.collect(seen: seenGen)
    lock.unlock()
    _ = dead
  }

  func setMix(index: Int, gain: Float, pan: Float, muted: Bool, drive: Float = 0) {
    guard Self.slotRange.contains(index) else { return }
    lock.lock()
    slots[index].gain = gain
    slots[index].pan = pan
    slots[index].muted = muted
    slots[index].drive = drive
    changed()
    lock.unlock()
  }

  /// Half speed on/off. The loop is re-placed on the transport timeline for its new speed
  /// (a half-speed loop starts on every second cycle's downbeat), crossfading 10 ms.
  func setHalfSpeed(index: Int, _ on: Bool) {
    guard Self.slotRange.contains(index) else { return }
    lock.lock()
    slots[index].rate = on ? 0.5 : 1
    slots[index].rateGen &+= 1
    changed()
    lock.unlock()
  }

  /// Where a loop should be (in samples) at transport time `t`: its first sample plays at
  /// `phase` in the cycle, and at `rate` it takes 1/rate cycles to play through.
  private static func place(t: Double, phase: Double, rate: Double, n: Int, sr: Double) -> Double {
    let period = Double(max(n, 1)) / sr
    let span = period / rate
    var pos = (t - phase).truncatingRemainder(dividingBy: span)
    if pos < 0 { pos += span }
    return min(max(0, (pos * rate * sr).rounded()), Double(max(0, n - 1)))
  }

  func setReversed(index: Int, _ on: Bool) {
    guard Self.slotRange.contains(index) else { return }
    lock.lock()
    slots[index].reversed = on
    changed()
    lock.unlock()
  }

  func clear(index: Int) {
    guard Self.slotRange.contains(index) else { return }
    lock.lock()
    if recIndex == index {
      recording = false
      complete = false
    }
    retire(slots[index])
    let next = slots[index].activation &+ 1
    slots[index] = Slot()
    slots[index].activation = next
    changed()
    let dead = retired.collect(seen: seenGen)
    lock.unlock()
    _ = dead
  }

  func setTransportPlaying(_ on: Bool) {
    lock.lock()
    // Mute is handled in render (silent but still advancing), not by deactivating.
    for i in slots.indices {
      if slots[i].n > 1 { slots[i].active = on }
    }
    changed()
    lock.unlock()
  }

  func clearAll() {
    lock.lock()
    recording = false
    complete = false
    recWritten = 0
    for i in slots.indices {
      retire(slots[i])
      let next = slots[i].activation &+ 1
      slots[i] = Slot()
      slots[i].activation = next
    }
    changed()
    let dead = retired.collect(seen: seenGen)
    lock.unlock()
    _ = dead
  }

  /// Lock held, render thread. Copies what changed; array assignments only retain.
  /// `transportT` is the shared transport time at this buffer's first frame.
  private func syncVoices(transportT: Double) {
    let sr = sampleRate
    sampleRateForRender = sr
    let now = CACurrentMediaTime()
    for i in slots.indices {
      let s = slots[i]
      if s.activation != voices[i].activation {
        voices[i].activation = s.activation
        voices[i].wait = 0
        voices[i].rate = s.rate
        voices[i].rateGen = s.rateGen
        voices[i].xLeft = 0
        voices[i].fadeIn = s.align ? max(1, Int(0.005 * sr)) : 0
        if s.phase >= 0 { voices[i].phase = s.phase }
        let period = Double(max(s.n, 1)) / sr
        if s.align {
          // Transport start: silent until the start time, then at this loop's place in the cycle.
          var t = transportT
          if t < 0 {
            voices[i].wait = Int((-t * sr).rounded())
            t = 0
          }
          voices[i].playhead = Self.place(t: t, phase: voices[i].phase, rate: s.rate, n: s.n, sr: sr)
        } else {
          // Normally 0. If the lock was busy when the loop started, pick up where it
          // should be now instead of starting late and staying late.
          let late = now - s.activatedAt
          voices[i].playhead = s.active && late > 0.005 ? Double(Int(late * sr)) : 0
          // Remember where in the cycle its first sample plays.
          var ph = (transportT - voices[i].playhead / sr).truncatingRemainder(dividingBy: period)
          if ph < 0 { ph += period }
          voices[i].phase = ph
        }
      }
      if s.rateGen != voices[i].rateGen {
        voices[i].rateGen = s.rateGen
        if s.active, s.rate != voices[i].rate, s.n > 1 {
          voices[i].xHead = voices[i].playhead
          voices[i].xRate = voices[i].rate
          voices[i].xLen = max(1, Int(0.01 * sr))
          voices[i].xLeft = voices[i].xLen
          voices[i].playhead = Self.place(t: transportT, phase: voices[i].phase, rate: s.rate, n: s.n, sr: sr)
        }
        voices[i].rate = s.rate
      }
      voices[i].n = s.n
      voices[i].gain = s.gain
      voices[i].pan = s.pan
      voices[i].muted = s.muted
      voices[i].reversed = s.reversed
      voices[i].active = s.active
      voices[i].drive = s.drive
      if s.active {
        voices[i].left = s.left
        voices[i].right = s.right
        voices[i].revL = s.revL
        voices[i].revR = s.revR
      } else {
        voices[i].left = []
        voices[i].right = []
        voices[i].revL = []
        voices[i].revR = []
      }
    }
    renderGen = gen
    seenGen = gen
  }

  /// 4-point cubic (Hermite) read at a fractional position, wrapping around the loop.
  @inline(__always) private static func cubic(_ a: [Float], _ b: [Float], _ h: Double, _ n: Int) -> (Float, Float) {
    var p = h.truncatingRemainder(dividingBy: Double(n))
    if p < 0 { p += Double(n) }
    let i0 = Int(p)
    let f = Float(p - Double(i0))
    let im1 = (i0 + n - 1) % n, i1 = (i0 + 1) % n, i2 = (i0 + 2) % n
    func h4(_ xm1: Float, _ x0: Float, _ x1: Float, _ x2: Float) -> Float {
      let c1 = 0.5 * (x1 - xm1), c2 = xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2, c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
      return ((c3 * f + c2) * f + c1) * f + x0
    }
    return (h4(a[im1], a[i0], a[i1], a[i2]), h4(b[im1], b[i0], b[i1], b[i2]))
  }

  /// Renders one slot. Each loop has its own source node so the engine can give it
  /// its own delay/reverb send levels.
  func render(slot si: Int, frames: Int, list: UnsafeMutablePointer<AudioBufferList>, timestamp: UnsafePointer<AudioTimeStamp>?) {
    let buffers = UnsafeMutableAudioBufferListPointer(list)
    guard frames > 0, let data = buffers.first?.mData else { return }
    let outL = data.assumingMemoryBound(to: Float.self)
    let outR: UnsafeMutablePointer<Float> = {
      if buffers.count > 1, let r = buffers[1].mData {
        return r.assumingMemoryBound(to: Float.self)
      }
      return outL
    }()
    AudioBuf.zero(list, frames: frames)
    let transportT = clock.time(timestamp, frames: frames).t
    if lock.try() {
      if gen != renderGen { syncVoices(transportT: transportT) }
      lock.unlock()
    }
    guard voices.indices.contains(si), voices[si].active, voices[si].n > 1 else { return }
    let n = voices[si].n
    var wait = voices[si].wait
    var head = voices[si].playhead
    let rate = voices[si].rate
    if voices[si].muted {
      // Keep time while muted so it's in step when unmuted.
      let w = min(wait, frames)
      wait -= w
      head += Double(frames - w) * rate
      voices[si].wait = wait
      voices[si].playhead = head
      voices[si].xLeft = 0
      return
    }
    let a = voices[si].reversed && voices[si].revL.count == n ? voices[si].revL : voices[si].left
    let b = voices[si].reversed && voices[si].revR.count == n ? voices[si].revR : voices[si].right
    guard a.count == n, b.count == n else { return }
    let gl = voices[si].gain * min(1, max(0, 1 - voices[si].pan))
    let gr = voices[si].gain * min(1, max(0, 1 + voices[si].pan))
    let driveOn = voices[si].drive > 0.001
    let useDrive = driveOn || voices[si].driveMix > 0
    let (g, makeup) = useDrive ? Drive2x.gains(voices[si].drive) : (Float(1), Float(1))
    let fade = Float(1 / (0.01 * sampleRateForRender))
    // Normal speed with no speed change fading: read whole samples exactly, as before.
    let exact = rate == 1 && voices[si].xLeft == 0
    var xLeft = voices[si].xLeft
    let xLen = max(1, voices[si].xLen)
    var xHead = voices[si].xHead
    let xRate = voices[si].xRate
    var fin = voices[si].fadeIn
    let finLen = Float(max(1, Int(0.005 * sampleRateForRender)))
    let dryL = scratch[si][0], dryR = scratch[si][1], wetL = scratch[si][2], wetR = scratch[si][3]
    var start = 0
    while start < frames {
      let cnt = min(Oversampler2x.maxFrames, frames - start)
      // Pass 1: the loop's dry signal for this chunk.
      for i in 0..<cnt {
        if wait > 0 {
          wait -= 1
          dryL[i] = 0
          dryR[i] = 0
          continue
        }
        var sl: Float, sr: Float
        if exact {
          let idx = Int(head) % n
          sl = a[idx]
          sr = b[idx]
        } else {
          (sl, sr) = Self.cubic(a, b, head, n)
          if xLeft > 0 {
            let w = Float(xLeft) / Float(xLen)
            let (ol, or) = Self.cubic(a, b, xHead, n)
            sl = ol * w + sl * (1 - w)
            sr = or * w + sr * (1 - w)
            xHead += xRate
            xLeft -= 1
          }
        }
        head += rate
        if fin > 0 {
          let w = 1 - Float(fin) / finLen
          sl *= w
          sr *= w
          fin -= 1
        }
        dryL[i] = sl * gl
        dryR[i] = sr * gr
      }
      if useDrive {
        // Pass 2: Drive on the whole chunk (block, 2x oversampled), crossfaded in and out.
        wetL.update(from: dryL, count: cnt)
        wetR.update(from: dryR, count: cnt)
        voices[si].ovL.process(wetL, cnt, drive: g, bias: 0, makeup: makeup)
        voices[si].ovR.process(wetR, cnt, drive: g, bias: 0, makeup: makeup)
        var mix = voices[si].driveMix
        for i in 0..<cnt {
          mix = driveOn ? min(1, mix + fade) : max(0, mix - fade)
          outL[start + i] += dryL[i] + (wetL[i] - dryL[i]) * mix
          if outR != outL { outR[start + i] += dryR[i] + (wetR[i] - dryR[i]) * mix }
        }
        voices[si].driveMix = mix
        if mix == 0 {
          voices[si].ovL.clear()
          voices[si].ovR.clear()
        }
      } else {
        for i in 0..<cnt {
          outL[start + i] += dryL[i]
          if outR != outL { outR[start + i] += dryR[i] }
        }
      }
      start += cnt
    }
    // Keep a fractional position from growing without bound.
    if !exact || head >= Double(n) * 4096 { head = head.truncatingRemainder(dividingBy: Double(n)) }
    voices[si].xLeft = xLeft
    voices[si].fadeIn = fin
    voices[si].xHead = xHead
    voices[si].wait = wait
    voices[si].playhead = head
  }
}
