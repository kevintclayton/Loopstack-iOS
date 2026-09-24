import AVFoundation
import Foundation

/// Sequential loop: record fills 0..<n, then playback reads 0..<n on a sample counter.
/// No wall-clock indexing (that smeared writes and sounded like distortion).
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
    /// Bumped whenever playback should restart from 0 (activation, replacement).
    var activation = 0
    var activatedAt: TimeInterval = 0
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
    var playhead = 0
  }

  private let lock = NSLock()
  private var slots: [Slot] = Array(repeating: Slot(), count: 8)
  private var recIndex = 0
  private var recWritten = 0
  private var recording = false
  private var complete = false
  private var sampleRate: Double = 44100
  private var gen: UInt64 = 0
  private var seenGen: UInt64 = 0
  private var retired = RetireBin()

  // Render thread only.
  private var voices: [Voice] = Array(repeating: Voice(), count: 8)
  private var renderGen: UInt64 = 0

  func setClock(start: TimeInterval, dur: Double, sampleRate: Double) {
    // Only the rate is used (to place late-synced loops); the transport clock isn't.
    _ = start; _ = dur
    lock.lock()
    self.sampleRate = max(sampleRate, 8000)
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
    guard slots.indices.contains(index), frames > 1 else { return }
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
    recording = true
    complete = false
    changed()
    let dead = retired.collect(seen: seenGen)
    lock.unlock()
    _ = dead
  }

  func punchIn(buffer: AVAudioPCMBuffer) {
    guard let data = buffer.floatChannelData else { return }
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return }
    let srcL = data[0]
    let srcR = buffer.format.channelCount > 1 ? data[1] : data[0]
    lock.lock()
    defer { lock.unlock() }
    guard recording, slots.indices.contains(recIndex) else { return }
    let n = slots[recIndex].n
    guard n > 1, slots[recIndex].left.count == n else { return }
    // The slot isn't active yet, so the renderer holds no reference to these
    // arrays and writing in place never triggers a copy.
    let take = min(frames, n - recWritten)
    if take > 0 {
      for i in 0..<take {
        slots[recIndex].left[recWritten + i] = srcL[i]
        slots[recIndex].right[recWritten + i] = srcR[i]
      }
      recWritten += take
    }
    if recWritten >= n {
      recording = false
      declick(recIndex, length: n)
      activate(recIndex)
      complete = true
    }
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
    changed()
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
    guard slots.indices.contains(index), let ch = buffer.floatChannelData else { return }
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

  func setMix(index: Int, gain: Float, pan: Float, muted: Bool) {
    guard slots.indices.contains(index) else { return }
    lock.lock()
    slots[index].gain = gain
    slots[index].pan = pan
    slots[index].muted = muted
    changed()
    lock.unlock()
  }

  func setReversed(index: Int, _ on: Bool) {
    guard slots.indices.contains(index) else { return }
    lock.lock()
    slots[index].reversed = on
    changed()
    lock.unlock()
  }

  func clear(index: Int) {
    guard slots.indices.contains(index) else { return }
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
    for i in slots.indices {
      if slots[i].n > 1 { slots[i].active = on && !slots[i].muted }
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
  private func syncVoices() {
    let sr = sampleRate
    let now = CACurrentMediaTime()
    for i in slots.indices {
      let s = slots[i]
      if s.activation != voices[i].activation {
        voices[i].activation = s.activation
        // Normally 0. If the lock was busy when the loop started, pick up where it
        // should be now instead of starting late and staying late.
        let late = now - s.activatedAt
        voices[i].playhead = s.active && late > 0.005 ? Int(late * sr) : 0
      }
      voices[i].n = s.n
      voices[i].gain = s.gain
      voices[i].pan = s.pan
      voices[i].muted = s.muted
      voices[i].reversed = s.reversed
      voices[i].active = s.active
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

  /// Renders one slot. Each loop has its own source node so the engine can give it
  /// its own delay/reverb send levels.
  func render(slot si: Int, frames: Int, list: UnsafeMutablePointer<AudioBufferList>) {
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
    if lock.try() {
      if gen != renderGen { syncVoices() }
      lock.unlock()
    }
    guard voices.indices.contains(si), voices[si].active, !voices[si].muted, voices[si].n > 1 else { return }
    let n = voices[si].n
    let a = voices[si].reversed && voices[si].revL.count == n ? voices[si].revL : voices[si].left
    let b = voices[si].reversed && voices[si].revR.count == n ? voices[si].revR : voices[si].right
    guard a.count == n, b.count == n else { return }
    let gl = voices[si].gain * min(1, max(0, 1 - voices[si].pan))
    let gr = voices[si].gain * min(1, max(0, 1 + voices[si].pan))
    var head = voices[si].playhead
    for i in 0..<frames {
      let idx = head % n
      outL[i] += a[idx] * gl
      if outR != outL { outR[i] += b[idx] * gr }
      head += 1
    }
    voices[si].playhead = head
  }
}
