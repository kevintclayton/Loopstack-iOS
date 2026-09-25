import Foundation

enum ScaleMode: String, CaseIterable, Identifiable, Codable {
  case major, minor, chromatic
  var id: String { rawValue }
  var label: String {
    switch self {
    case .major: return "Major"
    case .minor: return "Minor"
    case .chromatic: return "Chrom"
    }
  }
  var intervals: [Int] {
    switch self {
    case .major: return [0, 2, 4, 5, 7, 9, 11]
    case .minor: return [0, 2, 3, 5, 7, 8, 10]
    case .chromatic: return [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
    }
  }
}

struct PadNote: Identifiable, Equatable {
  var midi: Int
  var label: String
  var isRoot: Bool
  var id: Int { midi }
}

enum MusicKey {
  static let pcNamesSharps = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
  static let pcNamesFlats = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
  static let flatRoots: Set<Int> = [5, 10, 3, 8, 1, 6] // F Bb Eb Ab Db Gb

  static func name(pc: Int, flats: Bool) -> String {
    let i = ((pc % 12) + 12) % 12
    return flats ? pcNamesFlats[i] : pcNamesSharps[i]
  }

  static func usesFlats(root: Int, mode: ScaleMode) -> Bool {
    if mode == .chromatic { return false }
    let r = ((root % 12) + 12) % 12
    if mode == .minor {
      let relativeMajor = (r + 3) % 12
      return flatRoots.contains(relativeMajor)
    }
    return flatRoots.contains(r)
  }

  static func contains(_ midi: Int, root: Int, mode: ScaleMode) -> Bool {
    let pc = ((midi - root) % 12 + 12) % 12
    return mode.intervals.contains(pc)
  }

  static func nextInScale(after midi: Int, root: Int, mode: ScaleMode) -> Int {
    var n = midi + 1
    while !contains(n, root: root, mode: mode) { n += 1 }
    return n
  }

  /// 16 in-key pads (two octaves including the extra tonic) or 12 chromatic pads.
  static func padNotes(root: Int, mode: ScaleMode, octave: Int) -> [PadNote] {
    let r = ((root % 12) + 12) % 12
    let flats = usesFlats(root: r, mode: mode)
    let base = 48 + octave * 12
    var start = base
    while start > 0, ((start - r) % 12 + 12) % 12 != 0 { start -= 1 }
    if start < 24 { start += 12 }
    // Chromatic: two full octaves (4 rows of 6), filling the same space as a scale's 16.
    let count = mode == .chromatic ? 24 : 16
    var notes: [PadNote] = []
    var midi = start
    while notes.count < count {
      if contains(midi, root: r, mode: mode) {
        let pc = ((midi % 12) + 12) % 12
        notes.append(PadNote(midi: midi, label: name(pc: pc, flats: flats), isRoot: pc == r))
      }
      midi += 1
      if midi > 108 { break }
    }
    return notes
  }

  /// Chord built on `midi`: stacked thirds from the key (so every chord fits it), or
  /// a major chord when there is no key (chromatic).
  static func chord(on midi: Int, root: Int, mode: ScaleMode, sevenths: Bool) -> [Int] {
    if mode == .chromatic {
      return (sevenths ? [0, 4, 7, 11] : [0, 4, 7]).map { midi + $0 }
    }
    var notes = [midi]
    var n = midi
    for _ in 0..<(sevenths ? 3 : 2) {
      n = nextInScale(after: nextInScale(after: n, root: root, mode: mode), root: root, mode: mode)
      notes.append(n)
    }
    return notes
  }

  /// Chord symbol for notes from `chord(on:)`, e.g. "Dm", "G7", "Bø7".
  static func chordName(_ notes: [Int], flats: Bool) -> String {
    guard notes.count >= 3, let r = notes.first else { return notes.first.map { name(pc: $0 % 12, flats: flats) } ?? "" }
    let third = notes[1] - r, fifth = notes[2] - r
    let base = name(pc: r % 12, flats: flats)
    let seventh = notes.count > 3 ? notes[3] - r : nil
    switch (third, fifth, seventh) {
    case (4, 7, nil): return base
    case (3, 7, nil): return base + "m"
    case (3, 6, nil): return base + "°"
    case (4, 8, nil): return base + "+"
    case (4, 7, 11): return base + "maj7"
    case (4, 7, 10): return base + "7"
    case (3, 7, 10): return base + "m7"
    case (3, 7, 11): return base + "mM7"
    case (3, 6, 10): return base + "ø7"
    case (3, 6, 9): return base + "°7"
    default: return base
    }
  }

  /// Home-row mapping onto the visible pads.
  /// Hardware keys for the pads, low to high: the A row, then the top row (skipping R,
  /// which records). Z/X and C/V are octave and velocity, as in GarageBand.
  static let typeOrder = ["a", "s", "d", "f", "g", "h", "j", "k", "l", ";", "'", "w", "e", "t", "y", "u"]

  static func midiForTypeKey(_ raw: String, pads: [PadNote]) -> Int? {
    let key = raw.lowercased()
    guard let i = typeOrder.firstIndex(of: key), i < pads.count else { return nil }
    return pads[i].midi
  }
}

enum PitchMath {
  static func step(midi: Int, root: Int, srcRate: Double, dstRate: Double) -> Double {
    let src = max(1, srcRate)
    let dst = max(1, dstRate)
    return (src / dst) * pow(2.0, Double(midi - root) / 12.0)
  }

  static func resample(_ src: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
    guard src.count > 1 else { return src }
    if abs(srcRate - dstRate) < 1 { return src }
    let step = max(srcRate, 1) / max(dstRate, 1)
    let n = max(1, Int((Double(src.count - 1) / step).rounded(.down)))
    var out = [Float](repeating: 0, count: n)
    var pos = 0.0
    for i in 0..<n {
      let i0 = min(src.count - 2, max(0, Int(pos)))
      let frac = Float(pos - Double(i0))
      out[i] = src[i0] * (1 - frac) + src[i0 + 1] * frac
      pos += step
    }
    return out
  }
}
