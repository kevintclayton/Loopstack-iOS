import Foundation

/// One loop in a saved project: its audio file plus everything set on it.
struct LoopState: Codable, Equatable {
  var id: String
  var name: String
  var file: String
  var gain: Float
  var pan: Float
  var delay: Float
  var reverb: Float
  var drive: Float
  var muted: Bool
  var soloed: Bool
  var reversed: Bool
  var halfSpeed: Bool
}

/// Everything in a stack: tempo, loops, drums, sound, arp, key and mix. Loop audio lives
/// in the project's `loops` folder, and its song in `song`.
struct ProjectState: Codable, Equatable {
  var version = 1
  var name: String
  var bpm: Int
  var bars: Int
  var metronomeOn: Bool
  var countInOn: Bool
  // Drums
  var drumsOn: Bool
  var jamMode: Bool
  var drumKit: String
  var drumId: String
  var drumDrive: Float
  var drumDirt: Float
  var drumComp: Float
  var drumVinyl: Float
  var drumTape: Float
  var drumWear: Float
  var drumRoom: Float
  var drumPitch: Int
  // Mix
  var masterGain: Float
  var metroGain: Float
  var drumsGain: Float
  var loopsGain: Float
  // Sound
  var preset: String
  var patches: [String: InstrumentPatch]
  var acousticId: String?
  var acousticSustains: [String: Float]
  var layerOn: Bool
  var layerBlend: Float
  var layerOctave: Int
  // Keys, chords, arp
  var scaleRoot: Int
  var scaleMode: String
  var chordMode: Bool
  var chordSevenths: Bool
  var arpOn: Bool
  var arpLatch: Bool
  var arpDivision: Int
  var arpMode: Int
  var arpOctaves: Int
  // Loops
  var loops: [LoopState]
  var layerSerial: Int
}

/// A project in the list.
struct ProjectInfo: Identifiable, Equatable {
  var id: String
  var name: String
  var modified: Date
  var loops: Int
}

/// Projects on disk: Documents/Projects/<id>/ with project.json, loops/ and song/.
enum ProjectStore {
  static var root: URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let dir = docs.appendingPathComponent("Projects", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  static func dir(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
  static func stateURL(_ id: String) -> URL { dir(id).appendingPathComponent("project.json") }
  static func loopsDir(_ id: String) -> URL {
    let d = dir(id).appendingPathComponent("loops", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
  }
  static func songDir(_ id: String) -> URL {
    let d = dir(id).appendingPathComponent("song", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
  }

  /// The project that was open last time.
  static var currentId: String? {
    get { UserDefaults.standard.string(forKey: "currentProject") }
    set { UserDefaults.standard.set(newValue, forKey: "currentProject") }
  }

  static func list() -> [ProjectInfo] {
    let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    return ids.compactMap { id -> ProjectInfo? in
      guard let state = load(id) else { return nil }
      let modified = (try? FileManager.default.attributesOfItem(atPath: stateURL(id).path)[.modificationDate] as? Date) ?? .distantPast
      return ProjectInfo(id: id, name: state.name, modified: modified, loops: state.loops.count)
    }
    .sorted { $0.modified > $1.modified }
  }

  static func load(_ id: String) -> ProjectState? {
    guard let data = try? Data(contentsOf: stateURL(id)) else { return nil }
    return try? JSONDecoder().decode(ProjectState.self, from: data)
  }

  static func save(_ id: String, _ state: ProjectState) {
    try? FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
    guard let data = try? JSONEncoder().encode(state) else { return }
    try? data.write(to: stateURL(id), options: .atomic)
  }

  static func delete(_ id: String) {
    try? FileManager.default.removeItem(at: dir(id))
  }

  /// Copies a project folder (loops, song and all) under a new id and name.
  static func duplicate(_ id: String, name: String) -> String? {
    let newId = UUID().uuidString
    do {
      try FileManager.default.copyItem(at: dir(id), to: dir(newId))
    } catch {
      return nil
    }
    guard var state = load(newId) else { return nil }
    state.name = name
    save(newId, state)
    return newId
  }

  static func rename(_ id: String, to name: String) {
    guard var state = load(id) else { return }
    state.name = name
    save(id, state)
  }

  /// Before projects existed the song lived in Documents/Song: move it into `id`.
  static func adoptLegacySong(into id: String) {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let legacy = docs.appendingPathComponent("Song", isDirectory: true)
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: legacy.path), !files.isEmpty else { return }
    let dest = songDir(id)
    for f in files {
      try? FileManager.default.moveItem(at: legacy.appendingPathComponent(f), to: dest.appendingPathComponent(f))
    }
    try? FileManager.default.removeItem(at: legacy)
  }

  /// "Untitled", "Untitled 2", ...: the first name not in use.
  static func freshName(_ base: String = "Untitled") -> String {
    let names = Set(list().map(\.name))
    if !names.contains(base) { return base }
    var n = 2
    while names.contains("\(base) \(n)") { n += 1 }
    return "\(base) \(n)"
  }
}
