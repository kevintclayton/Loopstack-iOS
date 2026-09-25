import AVFoundation
import Foundation

/// One block in the song: a loopstack captured exactly as it sounded (every loop with its
/// effects, mutes and solos mixed to one stereo file; the drums with their effects in a
/// second), played `repeats` times.
struct SongBlock: Codable, Identifiable, Equatable {
  var id: String
  var name: String
  var bpm: Int
  var bars: Int
  /// Length of one pass, in frames at `sampleRate`.
  var frames: Int
  var sampleRate: Double
  var repeats: Int
  /// What was playing, for the block's label ("Dusty · Hazy").
  var detail: String

  var seconds: Double { Double(frames) / max(sampleRate, 1) }
}

/// The song on disk: an ordered index (song.json) and each block's two audio files.
enum SongStore {
  static var folder: URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let dir = docs.appendingPathComponent("Song", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  static func loopsURL(_ id: String) -> URL { folder.appendingPathComponent("\(id)-loops.caf") }
  static func drumsURL(_ id: String) -> URL { folder.appendingPathComponent("\(id)-drums.caf") }
  private static var indexURL: URL { folder.appendingPathComponent("song.json") }

  static func load() -> [SongBlock] {
    guard let data = try? Data(contentsOf: indexURL),
          let blocks = try? JSONDecoder().decode([SongBlock].self, from: data) else { return [] }
    // Keep only blocks whose audio is still there.
    return blocks.filter { FileManager.default.fileExists(atPath: loopsURL($0.id).path) }
  }

  static func save(_ blocks: [SongBlock]) {
    guard let data = try? JSONEncoder().encode(blocks) else { return }
    try? data.write(to: indexURL, options: .atomic)
  }

  static func delete(_ id: String) {
    try? FileManager.default.removeItem(at: loopsURL(id))
    try? FileManager.default.removeItem(at: drumsURL(id))
  }

  /// Copies a block's audio under a new id (for Duplicate).
  static func copy(_ id: String, to newId: String) -> Bool {
    do {
      try FileManager.default.copyItem(at: loopsURL(id), to: loopsURL(newId))
      try FileManager.default.copyItem(at: drumsURL(id), to: drumsURL(newId))
      return true
    } catch {
      return false
    }
  }

  /// Writes one stereo pass as 32-bit float CAF.
  static func write(_ l: [Float], _ r: [Float], sampleRate: Double, to url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let n = min(l.count, r.count)
    guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return }
    buf.frameLength = AVAudioFrameCount(n)
    l.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: n) }
    r.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress!, count: n) }
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
      AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buf)
  }

  /// Reads a block file into a buffer at `format` (converting if the audio route's rate
  /// has changed since it was captured).
  static func read(_ url: URL, as format: AVAudioFormat) -> AVAudioPCMBuffer? {
    guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
          let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: src)) != nil else { return nil }
    if src.format.sampleRate == format.sampleRate && src.format.channelCount == format.channelCount { return src }
    guard let conv = AVAudioConverter(from: src.format, to: format) else { return nil }
    let cap = AVAudioFrameCount(Double(src.frameLength) * format.sampleRate / src.format.sampleRate) + 1024
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return nil }
    var fed = false
    var err: NSError?
    conv.convert(to: out, error: &err) { _, status in
      if fed { status.pointee = .endOfStream; return nil }
      fed = true
      status.pointee = .haveData
      return src
    }
    return err == nil ? out : nil
  }
}

/// Records exactly one cycle of the stack from three taps: the loops bus (loops with
/// their delay/reverb returns), the drums bus and the drum room. Like a loop take, each
/// tap buffer is written at its place in the cycle from its render timestamp and wraps
/// round, so a capture started anywhere in the loop is complete and aligned to the
/// downbeat.
final class StackCapture: @unchecked Sendable {
  enum Source: Int { case loops = 0, drums, room }

  private let lock = NSLock()
  private let clock: TransportClock
  private var active = false
  private var n = 0
  private var sampleRate: Double = 48000
  private var loopsL: [Float] = [], loopsR: [Float] = []
  private var drumsL: [Float] = [], drumsR: [Float] = []
  private var start = [-1, -1, -1]
  private var written = [0, 0, 0]

  init(clock: TransportClock) { self.clock = clock }

  /// Main thread: start capturing one cycle of `frames`.
  func begin(frames: Int, sampleRate: Double) {
    let z = [Float](repeating: 0, count: max(1, frames))
    lock.lock()
    n = max(1, frames)
    self.sampleRate = sampleRate
    loopsL = z; loopsR = z; drumsL = z; drumsR = z
    start = [-1, -1, -1]
    written = [0, 0, 0]
    active = true
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    active = false
    loopsL = []; loopsR = []; drumsL = []; drumsR = []
    lock.unlock()
  }

  /// 0...1: how much of the cycle every source has.
  var progress: Double {
    lock.lock()
    defer { lock.unlock() }
    guard active, n > 0 else { return 0 }
    return Double(written.min() ?? 0) / Double(n)
  }

  /// Tap thread.
  func append(_ source: Source, _ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
    guard let data = buffer.floatChannelData else { return }
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return }
    let srcL = data[0]
    let srcR = buffer.format.channelCount > 1 ? data[1] : data[0]
    let t0 = when.isSampleTimeValid ? clock.transportTime(sampleTime: Double(when.sampleTime)) : nil
    lock.lock()
    defer { lock.unlock() }
    guard active else { return }
    let s = source.rawValue
    guard written[s] < n else { return }
    var from = 0
    if start[s] < 0 {
      // Wait for the render thread's timing; skip the lead-in before the transport starts.
      guard let t0 else { return }
      let skip = t0 < 0 ? Int((-t0 * sampleRate).rounded(.up)) : 0
      if skip >= frames { return }
      from = skip
      let f = Int((t0 * sampleRate).rounded()) + from
      start[s] = ((f % n) + n) % n
    }
    var k = written[s]
    var i = from
    let st = start[s]
    switch source {
    case .loops:
      while i < frames, k < n {
        let idx = (st + k) % n
        loopsL[idx] = srcL[i]
        loopsR[idx] = srcR[i]
        i += 1; k += 1
      }
    case .drums, .room:
      // The dry drums and the room both land in the drums file.
      while i < frames, k < n {
        let idx = (st + k) % n
        drumsL[idx] += srcL[i]
        drumsR[idx] += srcR[i]
        i += 1; k += 1
      }
    }
    written[s] = k
  }

  /// Main thread: the finished cycle, once every source has it all.
  func take() -> (loopsL: [Float], loopsR: [Float], drumsL: [Float], drumsR: [Float], sampleRate: Double)? {
    lock.lock()
    defer { lock.unlock() }
    guard active, written.allSatisfy({ $0 >= n }) else { return nil }
    active = false
    let out = (loopsL, loopsR, drumsL, drumsR, sampleRate)
    loopsL = []; loopsR = []; drumsL = []; drumsR = []
    return out
  }
}
