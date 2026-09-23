import AVFoundation
import Foundation

struct SavedSound: Identifiable, Codable, Equatable {
  var id: String
  var name: String
  var preset: String
  var isSampler: Bool
  var sampleFile: String?
  var sampleRoot: Int?
  var patch: InstrumentPatch
}

enum SoundLibrary {
  private static var folder: URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let url = docs.appendingPathComponent("Sounds", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static var indexURL: URL { folder.appendingPathComponent("index.json") }

  static func loadIndex() -> [SavedSound] {
    guard let data = try? Data(contentsOf: indexURL) else { return [] }
    return (try? JSONDecoder().decode([SavedSound].self, from: data)) ?? []
  }

  static func writeIndex(_ sounds: [SavedSound]) {
    guard let data = try? JSONEncoder().encode(sounds) else { return }
    try? data.write(to: indexURL, options: .atomic)
  }

  static func save(_ sound: SavedSound, sample: AVAudioPCMBuffer?) -> SavedSound {
    var stored = sound
    if let sample {
      let name = "\(sound.id).wav"
      let url = folder.appendingPathComponent(name)
      try? AudioDSP.encodeWav(sample).write(to: url, options: .atomic)
      stored.sampleFile = name
      stored.isSampler = true
    }
    var all = loadIndex().filter { $0.id != stored.id }
    all.insert(stored, at: 0)
    writeIndex(all)
    return stored
  }

  static func delete(_ id: String) {
    var all = loadIndex()
    if let hit = all.first(where: { $0.id == id }), let file = hit.sampleFile {
      try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
    }
    all.removeAll { $0.id == id }
    writeIndex(all)
  }

  static func loadSample(_ sound: SavedSound) -> (samples: [Float], rate: Double)? {
    guard let file = sound.sampleFile else { return nil }
    let url = folder.appendingPathComponent(file)
    guard let audio = try? AVAudioFile(forReading: url) else { return nil }
    let frames = AVAudioFrameCount(audio.length)
    guard frames > 16,
          let buf = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: frames)
    else { return nil }
    do { try audio.read(into: buf) } catch { return nil }
    guard let src = buf.floatChannelData else { return nil }
    let n = Int(buf.frameLength)
    let chs = Int(buf.format.channelCount)
    var mono = [Float](repeating: 0, count: n)
    if chs > 1 {
      for i in 0..<n { mono[i] = (src[0][i] + src[1][i]) * 0.5 }
    } else {
      for i in 0..<n { mono[i] = src[0][i] }
    }
    return (mono, buf.format.sampleRate)
  }

  static func bufferFromMono(_ samples: [Float], rate: Double) -> AVAudioPCMBuffer? {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let buf = AudioDSP.makeBuffer(frames: samples.count, format: format)
    guard let dst = buf.floatChannelData?[0] else { return buf }
    for i in 0..<samples.count { dst[i] = samples[i] }
    return buf
  }
}
