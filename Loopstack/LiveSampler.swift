import AVFoundation
import Foundation

/// One-shot sample, pitched from a root note. Render is additive.
///
/// Threading: control threads queue note events and publish sample data under
/// `lock`; the render thread collects them with `lock.try()` and never waits.
/// Replaced sample buffers are retired and freed off the render thread.
final class LiveSampler: @unchecked Sendable {
  struct Voice {
    var midi: Int
    var vel: Float
    var pos: Double
    var env: Double
    var releasing: Bool
  }

  private enum Event {
    case on(midi: Int, vel: Float)
    case off(midi: Int)
    case allOff
    /// New sample or cleared: drop sounding voices (in order with notes).
    case reset
  }

  private let lock = NSLock()
  private var sample: [Float] = []
  private var srcRate: Double = 44100
  private var rootMidi: Int = 60
  private var pending: [Event] = []
  private var gen: UInt64 = 0
  private var seenGen: UInt64 = 0
  private var retired = RetireBin()

  // Render thread only.
  private var rSample: [Float] = []
  private var rSrcRate: Double = 44100
  private var rRoot: Int = 60
  private var renderGen: UInt64 = 0
  private var inbox: [Event] = []
  private var voices: [Voice] = []

  init() {
    pending.reserveCapacity(256)
    inbox.reserveCapacity(256)
    voices.reserveCapacity(16)
  }

  var hasSample: Bool {
    lock.lock()
    defer { lock.unlock() }
    return sample.count > 32
  }

  var root: Int {
    lock.lock()
    defer { lock.unlock() }
    return rootMidi
  }

  /// Frees sample buffers the renderer has let go of. Call from the UI tick.
  func collect() {
    lock.lock()
    let dead = retired.collect(seen: seenGen)
    lock.unlock()
    _ = dead
  }

  func setRoot(_ midi: Int) {
    lock.lock()
    rootMidi = min(96, max(24, midi))
    gen &+= 1
    lock.unlock()
  }

  func setSample(_ samples: [Float], sampleRate: Double, root: Int) {
    lock.lock()
    retired.retire(sample, gen: gen &+ 1)
    sample = samples
    srcRate = max(8000, sampleRate)
    rootMidi = min(96, max(24, root))
    pending.append(.reset)
    gen &+= 1
    let dead = retired.collect(seen: seenGen)
    lock.unlock()
    _ = dead
  }

  func clear() {
    lock.lock()
    retired.retire(sample, gen: gen &+ 1)
    sample = []
    pending.append(.reset)
    gen &+= 1
    let dead = retired.collect(seen: seenGen)
    lock.unlock()
    _ = dead
  }

  func noteOn(midi: Int, velocity: Float) {
    lock.lock()
    pending.append(.on(midi: midi, vel: max(0.05, min(1, velocity))))
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

  /// Render thread. Voices has reserved capacity, so none of this allocates.
  private func apply(_ e: Event) {
    switch e {
    case let .on(midi, vel):
      voices.removeAll { $0.midi == midi }
      if voices.count >= 8 { voices.removeFirst(voices.count - 7) }
      voices.append(Voice(midi: midi, vel: vel, pos: 0, env: 1, releasing: false))
    case let .off(midi):
      for i in voices.indices where voices[i].midi == midi {
        voices[i].releasing = true
      }
    case .allOff:
      for i in voices.indices { voices[i].releasing = true }
    case .reset:
      voices.removeAll(keepingCapacity: true)
    }
  }

  /// Adds into a buffer already filled (usually zeros from the synth). Never hops threads.
  func renderAdd(frames: Int, list: UnsafeMutablePointer<AudioBufferList>, dstRate: Double) {
    let buffers = UnsafeMutableAudioBufferListPointer(list)
    guard frames > 0, let data = buffers.first?.mData else { return }
    let left = data.assumingMemoryBound(to: Float.self)
    let right: UnsafeMutablePointer<Float> = {
      if buffers.count > 1, let r = buffers[1].mData {
        return r.assumingMemoryBound(to: Float.self)
      }
      return left
    }()
    if lock.try() {
      swap(&pending, &inbox)
      if gen != renderGen {
        rSample = sample  // the buffer it replaces is retired, so no free here
        rSrcRate = srcRate
        rRoot = rootMidi
        renderGen = gen
        seenGen = gen
      }
      lock.unlock()
      for e in inbox { apply(e) }
      inbox.removeAll(keepingCapacity: true)
    }
    let n = rSample.count
    let sr = rSrcRate
    let root = rRoot
    let outRate = max(8000, dstRate)
    if n < 32 || voices.isEmpty { return }
    var i = 0
    while i < voices.count {
      var v = voices[i]
      let step = PitchMath.step(midi: v.midi, root: root, srcRate: sr, dstRate: outRate)
      for f in 0..<frames {
        if v.releasing {
          v.env *= 0.92
        }
        if v.pos >= Double(n - 1) || v.env < 0.0008 {
          v.env = 0
          break
        }
        let i0 = Int(v.pos)
        let i1 = min(i0 + 1, n - 1)
        let frac = Float(v.pos - Double(i0))
        let s = (rSample[i0] * (1 - frac) + rSample[i1] * frac) * v.vel * Float(v.env) * 0.95
        left[f] += s
        if right != left { right[f] += s }
        v.pos += step
      }
      if v.env < 0.0008 || v.pos >= Double(n - 1) {
        voices.remove(at: i)
      } else {
        voices[i] = v
        i += 1
      }
    }
  }
}

final class SampleCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var active = false
  private var samples: [Float] = []
  private var target = 0

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return samples.count
  }

  func start(maxFrames: Int) {
    lock.lock()
    samples.removeAll(keepingCapacity: true)
    target = max(maxFrames, 2048)
    active = true
    lock.unlock()
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    defer { lock.unlock() }
    guard active, let data = buffer.floatChannelData else { return }
    let n = Int(buffer.frameLength)
    let chs = Int(buffer.format.channelCount)
    let room = max(0, target - samples.count)
    let take = min(n, room)
    if take <= 0 {
      active = false
      return
    }
    if chs > 1 {
      for i in 0..<take {
        samples.append((data[0][i] + data[1][i]) * 0.5)
      }
    } else {
      samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: take))
    }
    if samples.count >= target { active = false }
  }

  func take() -> [Float] {
    lock.lock()
    active = false
    let out = samples
    samples = []
    lock.unlock()
    return trim(out)
  }

  private func trim(_ src: [Float]) -> [Float] {
    guard src.count > 64 else { return src }
    let th: Float = 0.008
    var start = 0
    var end = src.count - 1
    while start < src.count, abs(src[start]) < th { start += 1 }
    while end > start, abs(src[end]) < th { end -= 1 }
    start = max(0, start - 32)
    end = min(src.count - 1, end + 32)
    if end <= start { return src }
    var out = Array(src[start...end])
    let fade = min(96, out.count / 8)
    if fade > 1 {
      for i in 0..<fade {
        let w = Float(i) / Float(fade)
        out[i] *= w
        out[out.count - 1 - i] *= w
      }
    }
    return out
  }
}
