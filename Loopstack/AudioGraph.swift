import AVFoundation
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

  /// Always-on tap, installed before engine.start. Captures keys after delay/reverb.
  static func installPostTap(on node: AVAudioNode, format: AVAudioFormat, layers: LiveLayers) {
    let layers = layers
    node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      layers.punchIn(buffer: buffer)
    }
  }

  static func layersNode(format: AVAudioFormat, layers: LiveLayers) -> AVAudioSourceNode {
    let layers = layers
    return AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
      layers.render(frames: Int(frameCount), list: abl)
      return noErr
    }
  }

  static func drumsNode(format: AVAudioFormat, drums: LiveDrums) -> AVAudioSourceNode {
    let drums = drums
    return AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
      drums.render(frames: Int(frameCount), list: abl)
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
