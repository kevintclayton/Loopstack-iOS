import AVFoundation
import Foundation

/// Sequential loop: record fills 0..<n, then playback reads 0..<n on a sample counter.
/// No wall-clock indexing (that smeared writes and sounded like distortion).
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
    var playhead = 0
  }

  private let lock = NSRecursiveLock()
  private var slots: [Slot] = Array(repeating: Slot(), count: 8)
  private var recIndex = 0
  private var recWritten = 0
  private var recording = false
  private var complete = false

  func setClock(start: TimeInterval, dur: Double, sampleRate: Double) {
    // Transport clock is unused for sample I/O; kept so callers don't need to change.
    _ = start; _ = dur; _ = sampleRate
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
    slot.playhead = 0
    lock.lock()
    slots[index] = slot
    recIndex = index
    recWritten = 0
    recording = true
    complete = false
    lock.unlock()
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
      slots[recIndex].active = true
      slots[recIndex].playhead = 0
      complete = true
    }
  }

  func endRecord(activate: Bool) {
    lock.lock()
    recording = false
    if activate, slots.indices.contains(recIndex) {
      slots[recIndex].active = true
      slots[recIndex].playhead = 0
    }
    complete = activate
    lock.unlock()
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
    slots[index].revL = L
    slots[index].revR = R
    lock.unlock()
  }

  func setMix(index: Int, gain: Float, pan: Float, muted: Bool) {
    guard slots.indices.contains(index) else { return }
    lock.lock()
    slots[index].gain = gain
    slots[index].pan = pan
    slots[index].muted = muted
    lock.unlock()
  }

  func setReversed(index: Int, _ on: Bool) {
    guard slots.indices.contains(index) else { return }
    lock.lock()
    slots[index].reversed = on
    lock.unlock()
  }

  func clear(index: Int) {
    guard slots.indices.contains(index) else { return }
    lock.lock()
    if recIndex == index {
      recording = false
      complete = false
    }
    slots[index] = Slot()
    lock.unlock()
  }

  func setTransportPlaying(_ on: Bool) {
    lock.lock()
    for i in slots.indices {
      if slots[i].n > 1 { slots[i].active = on && !slots[i].muted }
    }
    lock.unlock()
  }

  func clearAll() {
    lock.lock()
    recording = false
    complete = false
    recWritten = 0
    for i in slots.indices { slots[i] = Slot() }
    lock.unlock()
  }

  func render(frames: Int, list: UnsafeMutablePointer<AudioBufferList>) {
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
    lock.lock()
    for si in slots.indices {
      guard slots[si].active, !slots[si].muted, slots[si].n > 1 else { continue }
      let n = slots[si].n
      let a = slots[si].reversed && slots[si].revL.count == n ? slots[si].revL : slots[si].left
      let b = slots[si].reversed && slots[si].revR.count == n ? slots[si].revR : slots[si].right
      guard a.count == n, b.count == n else { continue }
      let gl = slots[si].gain * min(1, max(0, 1 - slots[si].pan))
      let gr = slots[si].gain * min(1, max(0, 1 + slots[si].pan))
      var head = slots[si].playhead
      for i in 0..<frames {
        let idx = head % n
        outL[i] += a[idx] * gl
        if outR != outL { outR[i] += b[idx] * gr }
        head += 1
      }
      slots[si].playhead = head
    }
    lock.unlock()
  }
}
