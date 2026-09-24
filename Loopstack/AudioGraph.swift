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

/// Builds render callbacks in a file with no @MainActor types so the audio
/// thread never hops to the UI. Closures created inside LoopEngine.attachGraph
/// were isolated to the main actor — that underruns (echoey clicks) and
/// deadlocks when the UI does work at loop close.
enum AudioGraph {
  static func synthNode(
    format: AVAudioFormat,
    synth: LiveSynth,
    sampler: LiveSampler,
    outRate: Double
  ) -> AVAudioSourceNode {
    let synth = synth
    let sampler = sampler
    let outRate = outRate
    return AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
      synth.render(frames: Int(frameCount), list: abl)
      sampler.renderAdd(frames: Int(frameCount), list: abl, dstRate: outRate)
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
