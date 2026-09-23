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

  /// Playhead in seconds since origin, advanced by exact frame counts each render.
  /// Re-reading the wall clock every callback made windows overlap when callbacks
  /// arrived early, so parts of a click were rendered twice (heard as an echo).
  private var playhead: Double?

  func start(bpm: Double, beats: Int, looping: Bool, origin: TimeInterval) {
    lock.lock()
    self.bpm = max(40, bpm)
    self.beats = max(1, beats)
    self.looping = looping
    if origin != self.origin || !enabled { playhead = nil }
    self.origin = origin
    enabled = true
    lock.unlock()
  }

  func stop() {
    lock.lock()
    enabled = false
    playhead = nil
    lock.unlock()
  }

  func render(frames: Int, list: UnsafeMutablePointer<AudioBufferList>) {
    guard frames > 0 else { return }
    AudioBuf.zero(list, frames: frames)
    lock.lock()
    let on = enabled
    let sr = max(sampleRate, 8000)
    let bpm = self.bpm
    let beats = self.beats
    let looping = self.looping
    let wall = CACurrentMediaTime() - origin
    // Resync only on start or after a big jump (interruption, route change).
    var t0 = playhead ?? wall
    if abs(t0 - wall) > 0.08 { t0 = wall }
    let t1 = t0 + Double(frames) / sr
    playhead = t1
    lock.unlock()
    guard on else { return }
    let beatSec = MetroTiming.beatSec(bpm: bpm)
    let clickSec = 0.04
    if !looping, t0 >= Double(beats) * beatSec + clickSec {
      lock.lock()
      enabled = false
      playhead = nil
      lock.unlock()
      return
    }
    var b = Int(floor((t0 - clickSec) / beatSec))
    if b < 0 { b = 0 }
    let last = looping ? b + beats + 4 : beats - 1
    while b <= last {
      let bt = Double(b) * beatSec
      if bt >= t1 { break }
      if looping || b < beats, bt + clickSec > t0 {
        let down = b % 4 == 0
        let freq = down ? 1320.0 : 880.0
        let amp: Float = down ? 0.55 : 0.32
        // Walk output frames once each, so no sample is ever written twice.
        let first = max(0, Int(ceil((bt - t0) * sr)))
        let end = min(frames, Int(ceil((bt + clickSec - t0) * sr)))
        if first < end {
          for i in first..<end {
            let t = t0 + Double(i) / sr - bt
            let s = Float(sin(2 * Double.pi * freq * t) * exp(-t * 55)) * amp
            AudioBuf.add(list, frames: frames, index: i, sample: s)
          }
        }
      }
      b += 1
    }
  }
}
