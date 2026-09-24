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
///
/// Threading: start/stop are queued commands the render thread applies at the top
/// of its next cycle (when their effect would first be heard anyway). It collects
/// them with `lock.try()` and never waits on the UI.
final class LiveMetro: @unchecked Sendable {
  private enum Command {
    case start(bpm: Double, beats: Int, looping: Bool, origin: TimeInterval)
    case stop
    case resync
  }

  private let lock = NSLock()
  private var pending: [Command] = []
  private var sharedRate: Double = 44100

  var sampleRate: Double {
    get { lock.lock(); defer { lock.unlock() }; return sharedRate }
    set { lock.lock(); sharedRate = newValue; lock.unlock() }
  }

  // Render thread only.
  private var inbox: [Command] = []
  private var rate: Double = 44100
  private var enabled = false
  private var bpm: Double = 96
  private var origin: TimeInterval = 0
  private var beats: Int = 4
  private var looping = false

  /// Playhead in seconds since origin, advanced by exact frame counts each render.
  /// Re-reading the wall clock every callback made windows overlap when callbacks
  /// arrived early, so parts of a click were rendered twice (heard as an echo).
  private var playhead: Double?
  /// Set by stop(): clicks that began before this time ring out instead of being cut
  /// mid-waveform (the crack heard at the record-to-loop handoff).
  private var drainUntil: Double?
  /// After a resync, clicks that began before this point are skipped rather than
  /// joined mid-waveform (a partial click is a hard onset).
  private var resyncFloor = -Double.infinity

  init() {
    pending.reserveCapacity(64)
    inbox.reserveCapacity(64)
  }

  func start(bpm: Double, beats: Int, looping: Bool, origin: TimeInterval) {
    lock.lock()
    pending.append(.start(bpm: bpm, beats: beats, looping: looping, origin: origin))
    lock.unlock()
  }

  func stop() {
    lock.lock()
    pending.append(.stop)
    lock.unlock()
  }

  /// After an engine restart: pick the grid up from the clock again.
  func resync() {
    lock.lock()
    pending.append(.resync)
    lock.unlock()
  }

  /// Render thread.
  private func apply(_ c: Command) {
    switch c {
    case let .start(bpm, beats, looping, origin):
      self.bpm = max(40, bpm)
      self.beats = max(1, beats)
      self.looping = looping
      // While running, re-express the playhead against the new origin so the click
      // stream continues without a resync (count-in flows straight into recording).
      if let p = playhead, enabled || drainUntil != nil {
        playhead = p + (self.origin - origin)
      } else {
        playhead = nil
      }
      self.origin = origin
      enabled = true
      drainUntil = nil
    case .stop:
      if enabled, let p = playhead {
        drainUntil = p
      } else if drainUntil == nil {
        playhead = nil
      }
      enabled = false
    case .resync:
      if drainUntil == nil { playhead = nil }
    }
  }

  func render(frames: Int, list: UnsafeMutablePointer<AudioBufferList>) {
    guard frames > 0 else { return }
    AudioBuf.zero(list, frames: frames)
    if lock.try() {
      swap(&pending, &inbox)
      rate = sharedRate
      lock.unlock()
      for c in inbox { apply(c) }
      inbox.removeAll(keepingCapacity: true)
    }
    let on = enabled
    let drain = drainUntil
    let sr = max(rate, 8000)
    let bpm = self.bpm
    let beats = self.beats
    let looping = self.looping
    let wall = CACurrentMediaTime() - origin
    // Resync only on start or after a big jump (interruption, route change).
    var t0 = playhead ?? wall
    if playhead == nil || abs(t0 - wall) > 0.08 {
      t0 = wall
      resyncFloor = wall
    }
    let minStart = resyncFloor
    let t1 = t0 + Double(frames) / sr
    playhead = t1
    let beatSec = MetroTiming.beatSec(bpm: bpm)
    let clickSec = 0.04
    if !on {
      guard let drain else { return }
      if t0 >= drain + clickSec {
        drainUntil = nil
        playhead = nil
        return
      }
    }
    let stopAt = on ? Double.infinity : (drain ?? 0)
    if !looping, t0 >= Double(beats) * beatSec + clickSec {
      enabled = false
      playhead = nil
      return
    }
    var b = Int(floor((t0 - clickSec) / beatSec))
    if b < 0 { b = 0 }
    let last = looping ? b + beats + 4 : beats - 1
    while b <= last {
      let bt = Double(b) * beatSec
      if bt >= t1 || bt >= stopAt { break }
      if looping || b < beats, bt + clickSec > t0, bt >= minStart {
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
