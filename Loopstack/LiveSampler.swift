import AVFoundation
import Foundation

/// One-shot sample, pitched from a root note. Render is additive and lock-scoped.
final class LiveSampler: @unchecked Sendable {
  struct Voice {
    var midi: Int
    var vel: Float
    var pos: Double
    var env: Double
    var releasing: Bool
  }

  private let lock = NSLock()
  private var sample: [Float] = []
  private var srcRate: Double = 44100
  private var rootMidi: Int = 60
  private var voices: [Voice] = []

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

  func setRoot(_ midi: Int) {
    lock.lock()
    rootMidi = min(96, max(24, midi))
    lock.unlock()
  }

  func setSample(_ samples: [Float], sampleRate: Double, root: Int) {
    lock.lock()
    sample = samples
    srcRate = max(8000, sampleRate)
    rootMidi = min(96, max(24, root))
    voices.removeAll()
    lock.unlock()
  }

  func clear() {
    lock.lock()
    sample = []
    voices.removeAll()
    lock.unlock()
  }

  func noteOn(midi: Int, velocity: Float) {
    lock.lock()
    voices.removeAll { $0.midi == midi }
    if voices.count >= 8 { voices.removeFirst(voices.count - 7) }
    voices.append(Voice(midi: midi, vel: max(0.05, min(1, velocity)), pos: 0, env: 1, releasing: false))
    lock.unlock()
  }

  func noteOff(midi: Int) {
    lock.lock()
    for i in voices.indices where voices[i].midi == midi {
      voices[i].releasing = true
    }
    lock.unlock()
  }

  func allOff() {
    lock.lock()
    for i in voices.indices { voices[i].releasing = true }
    lock.unlock()
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
    lock.lock()
    let src = sample
    let n = src.count
    let sr = srcRate
    let root = rootMidi
    let outRate = max(8000, dstRate)
    if n < 32 || voices.isEmpty {
      lock.unlock()
      return
    }
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
        let s = (src[i0] * (1 - frac) + src[i1] * frac) * v.vel * Float(v.env) * 0.95
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
    lock.unlock()
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
