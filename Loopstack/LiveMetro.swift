import AVFoundation
import Foundation

enum MetroTiming {
  static func beatSec(bpm: Double) -> Double { 60 / max(bpm, 1) }
  static func countInDuration(bpm: Double, beats: Int = 4) -> Double {
    beatSec(bpm: bpm) * Double(max(1, beats))
  }
  static func beatTimes(bpm: Double, beats: Int) -> [Double] {
    let step = beatSec(bpm: bpm)
    return (0..<max(0, beats)).map { Double($0) * step }
  }
}

/// Click track generated in an already-running source node. No player play()/stop().
final class LiveMetro: @unchecked Sendable {
  var sampleRate: Double = 44100
  private let lock = NSLock()
  private var enabled = false
  private var bpm: Double = 96
  private var origin: TimeInterval = 0
  private var beats: Int = 4
  private var looping = false

  func start(bpm: Double, beats: Int, looping: Bool, origin: TimeInterval) {
    lock.lock()
    self.bpm = max(40, bpm)
    self.beats = max(1, beats)
    self.looping = looping
    self.origin = origin
    enabled = true
    lock.unlock()
  }

  func stop() {
    lock.lock()
    enabled = false
    lock.unlock()
  }

  func render(frames: Int, list: UnsafeMutablePointer<AudioBufferList>) {
    guard frames > 0 else { return }
    AudioBuf.zero(list, frames: frames)
    lock.lock()
    let on = enabled
    let sr = max(sampleRate, 8000)
    let bpm = self.bpm
    let origin = self.origin
    let beats = self.beats
    let looping = self.looping
    lock.unlock()
    guard on else { return }
    let beatSec = MetroTiming.beatSec(bpm: bpm)
    let clickSec = 0.04
    let t0 = CACurrentMediaTime() - origin
    let t1 = t0 + Double(frames) / sr
    if !looping, t0 >= Double(beats) * beatSec + clickSec {
      lock.lock()
      enabled = false
      lock.unlock()
      return
    }
    var b = Int(floor((t0 - clickSec) / beatSec))
    if b < 0 { b = 0 }
    let last = looping ? b + beats + 4 : beats - 1
    while b <= last {
      let bt = Double(b) * beatSec
      if bt >= t1 { break }
      if looping || b < beats, bt + clickSec >= t0 {
        let down = b % 4 == 0
        let freq = down ? 1320.0 : 880.0
        let amp: Float = down ? 0.55 : 0.32
        let clickN = Int(sr * clickSec)
        for i in 0..<clickN {
          let t = Double(i) / sr
          let absT = bt + t
          if absT < t0 || absT >= t1 { continue }
          let idx = Int(((absT - t0) * sr).rounded())
          guard idx >= 0, idx < frames else { continue }
          let s = Float(sin(2 * Double.pi * freq * t) * exp(-t * 55)) * amp
          AudioBuf.add(list, frames: frames, index: idx, sample: s)
        }
      }
      b += 1
    }
  }
}
