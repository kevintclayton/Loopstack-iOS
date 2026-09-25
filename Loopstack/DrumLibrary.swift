import Foundation

enum DrumVoice: String, CaseIterable {
  case kick, snare, hat, ohat, clap, rim, tom, perc
  var label: String {
    switch self {
    case .kick: return "Kick"
    case .snare: return "Snare"
    case .hat: return "Hat"
    case .ohat: return "Open Hat"
    case .clap: return "Clap"
    case .rim: return "Rim"
    case .tom: return "Tom"
    case .perc: return "Perc"
    }
  }
}

struct DrumHit { var step: Int; var voice: DrumVoice; var vel: Float }

struct DrumPattern: Identifiable {
  var id: String
  var name: String
  var feel: String
  var bars: Int
  var swing: Float
  var hits: [DrumHit]
}

enum DrumLibrary {
  static let all: [DrumPattern] = [
    DrumPattern(id: "floor", name: "Four on the Floor", feel: "House pulse", bars: 1, swing: 0.0, hits: [
      .init(step: 0, voice: .kick, vel: 1),
      .init(step: 4, voice: .kick, vel: 0.92),
      .init(step: 8, voice: .kick, vel: 1),
      .init(step: 12, voice: .kick, vel: 0.92),
      .init(step: 4, voice: .clap, vel: 0.78),
      .init(step: 12, voice: .clap, vel: 0.94),
      .init(step: 0, voice: .hat, vel: 0.6),
      .init(step: 2, voice: .hat, vel: 0.22),
      .init(step: 4, voice: .hat, vel: 0.52),
      .init(step: 6, voice: .hat, vel: 0.2),
      .init(step: 8, voice: .hat, vel: 0.58),
      .init(step: 10, voice: .hat, vel: 0.24),
      .init(step: 12, voice: .hat, vel: 0.5),
      .init(step: 14, voice: .hat, vel: 0.16),
      .init(step: 10, voice: .ohat, vel: 0.32),
    ]),
    DrumPattern(id: "pocket", name: "Tight Pocket", feel: "Dry studio", bars: 1, swing: 0.08, hits: [
      .init(step: 0, voice: .kick, vel: 1),
      .init(step: 6, voice: .kick, vel: 0.7),
      .init(step: 8, voice: .kick, vel: 0.88),
      .init(step: 4, voice: .snare, vel: 0.9),
      .init(step: 12, voice: .snare, vel: 0.95),
      .init(step: 0, voice: .hat, vel: 0.54),
      .init(step: 2, voice: .hat, vel: 0.18),
      .init(step: 4, voice: .hat, vel: 0.46),
      .init(step: 6, voice: .hat, vel: 0.15),
      .init(step: 8, voice: .hat, vel: 0.52),
      .init(step: 10, voice: .hat, vel: 0.17),
      .init(step: 12, voice: .hat, vel: 0.44),
      .init(step: 14, voice: .hat, vel: 0.2),
      .init(step: 10, voice: .rim, vel: 0.38),
    ]),
    DrumPattern(id: "boombap", name: "Boom Bap", feel: "Head-nod", bars: 1, swing: 0.18, hits: [
      .init(step: 0, voice: .kick, vel: 1),
      .init(step: 10, voice: .kick, vel: 0.85),
      .init(step: 4, voice: .snare, vel: 0.92),
      .init(step: 12, voice: .snare, vel: 1),
      .init(step: 7, voice: .snare, vel: 0.22),
      .init(step: 0, voice: .hat, vel: 0.48),
      .init(step: 2, voice: .hat, vel: 0.16),
      .init(step: 4, voice: .hat, vel: 0.4),
      .init(step: 6, voice: .hat, vel: 0.14),
      .init(step: 8, voice: .hat, vel: 0.46),
      .init(step: 10, voice: .hat, vel: 0.18),
      .init(step: 12, voice: .hat, vel: 0.36),
      .init(step: 14, voice: .hat, vel: 0.12),
    ]),
    DrumPattern(id: "break", name: "Breakbeat", feel: "Open break", bars: 2, swing: 0.06, hits: [
      .init(step: 0, voice: .kick, vel: 1),
      .init(step: 6, voice: .kick, vel: 0.8),
      .init(step: 10, voice: .kick, vel: 0.7),
      .init(step: 16, voice: .kick, vel: 1),
      .init(step: 22, voice: .kick, vel: 0.75),
      .init(step: 4, voice: .snare, vel: 0.9),
      .init(step: 12, voice: .snare, vel: 1),
      .init(step: 20, voice: .snare, vel: 0.9),
      .init(step: 28, voice: .snare, vel: 1),
      .init(step: 14, voice: .snare, vel: 0.26),
      .init(step: 26, voice: .snare, vel: 0.22),
      .init(step: 18, voice: .ohat, vel: 0.42),
      .init(step: 0, voice: .hat, vel: 0.5),
      .init(step: 2, voice: .hat, vel: 0.18),
      .init(step: 4, voice: .hat, vel: 0.46),
      .init(step: 6, voice: .hat, vel: 0.16),
      .init(step: 8, voice: .hat, vel: 0.5),
      .init(step: 10, voice: .hat, vel: 0.2),
      .init(step: 12, voice: .hat, vel: 0.44),
      .init(step: 14, voice: .hat, vel: 0.15),
      .init(step: 16, voice: .hat, vel: 0.5),
      .init(step: 18, voice: .hat, vel: 0.17),
      .init(step: 20, voice: .hat, vel: 0.46),
      .init(step: 22, voice: .hat, vel: 0.16),
      .init(step: 24, voice: .hat, vel: 0.48),
      .init(step: 26, voice: .hat, vel: 0.14),
      .init(step: 28, voice: .hat, vel: 0.5),
      .init(step: 30, voice: .hat, vel: 0.2),
    ]),
    DrumPattern(id: "halftime", name: "Half Time", feel: "Heavy drop", bars: 2, swing: 0.04, hits: [
      .init(step: 0, voice: .kick, vel: 1),
      .init(step: 16, voice: .kick, vel: 0.95),
      .init(step: 14, voice: .kick, vel: 0.45),
      .init(step: 8, voice: .snare, vel: 1),
      .init(step: 24, voice: .snare, vel: 1),
      .init(step: 26, voice: .rim, vel: 0.35),
      .init(step: 0, voice: .hat, vel: 0.35),
      .init(step: 4, voice: .hat, vel: 0.22),
      .init(step: 8, voice: .hat, vel: 0.4),
      .init(step: 12, voice: .hat, vel: 0.22),
      .init(step: 16, voice: .hat, vel: 0.35),
      .init(step: 20, voice: .hat, vel: 0.22),
      .init(step: 24, voice: .hat, vel: 0.4),
      .init(step: 28, voice: .hat, vel: 0.22),
      .init(step: 20, voice: .ohat, vel: 0.3),
      .init(step: 6, voice: .perc, vel: 0.4),
      .init(step: 22, voice: .perc, vel: 0.38),
    ]),
    DrumPattern(id: "shuffle", name: "Shuffle", feel: "Swung blues", bars: 1, swing: 0.42, hits: [
      .init(step: 0, voice: .kick, vel: 1),
      .init(step: 8, voice: .kick, vel: 0.7),
      .init(step: 4, voice: .snare, vel: 0.82),
      .init(step: 12, voice: .snare, vel: 0.9),
      .init(step: 0, voice: .hat, vel: 0.5),
      .init(step: 2, voice: .hat, vel: 0.22),
      .init(step: 4, voice: .hat, vel: 0.45),
      .init(step: 6, voice: .hat, vel: 0.2),
      .init(step: 8, voice: .hat, vel: 0.5),
      .init(step: 10, voice: .hat, vel: 0.22),
      .init(step: 12, voice: .hat, vel: 0.45),
      .init(step: 14, voice: .hat, vel: 0.18),
      .init(step: 10, voice: .rim, vel: 0.3),
    ]),
    DrumPattern(id: "clave", name: "Latin Clave", feel: "3–2 son", bars: 2, swing: 0.05, hits: [
      .init(step: 0, voice: .kick, vel: 1),
      .init(step: 6, voice: .kick, vel: 0.75),
      .init(step: 12, voice: .kick, vel: 0.65),
      .init(step: 16, voice: .kick, vel: 0.9),
      .init(step: 22, voice: .kick, vel: 0.7),
      .init(step: 4, voice: .snare, vel: 0.35),
      .init(step: 12, voice: .snare, vel: 0.55),
      .init(step: 20, voice: .snare, vel: 0.4),
      .init(step: 28, voice: .snare, vel: 0.7),
      .init(step: 0, voice: .perc, vel: 0.85),
      .init(step: 3, voice: .perc, vel: 0.7),
      .init(step: 6, voice: .perc, vel: 0.8),
      .init(step: 10, voice: .perc, vel: 0.75),
      .init(step: 12, voice: .perc, vel: 0.8),
      .init(step: 16, voice: .perc, vel: 0.55),
      .init(step: 20, voice: .perc, vel: 0.5),
      .init(step: 24, voice: .perc, vel: 0.55),
      .init(step: 28, voice: .perc, vel: 0.5),
      .init(step: 0, voice: .hat, vel: 0.3),
      .init(step: 4, voice: .hat, vel: 0.28),
      .init(step: 8, voice: .hat, vel: 0.3),
      .init(step: 12, voice: .hat, vel: 0.28),
      .init(step: 16, voice: .hat, vel: 0.3),
      .init(step: 20, voice: .hat, vel: 0.28),
      .init(step: 24, voice: .hat, vel: 0.3),
      .init(step: 28, voice: .hat, vel: 0.28),
      .init(step: 8, voice: .tom, vel: 0.45),
      .init(step: 26, voice: .tom, vel: 0.5),
    ]),
    DrumPattern(id: "techno", name: "Techno Pulse", feel: "Hypnotic", bars: 1, swing: 0.0, hits: [
      .init(step: 0, voice: .kick, vel: 1),
      .init(step: 4, voice: .kick, vel: 1),
      .init(step: 8, voice: .kick, vel: 1),
      .init(step: 12, voice: .kick, vel: 1),
      .init(step: 0, voice: .hat, vel: 0.22),
      .init(step: 1, voice: .hat, vel: 0.16),
      .init(step: 2, voice: .hat, vel: 0.38),
      .init(step: 3, voice: .hat, vel: 0.16),
      .init(step: 4, voice: .hat, vel: 0.22),
      .init(step: 5, voice: .hat, vel: 0.16),
      .init(step: 6, voice: .hat, vel: 0.4),
      .init(step: 7, voice: .hat, vel: 0.16),
      .init(step: 8, voice: .hat, vel: 0.22),
      .init(step: 9, voice: .hat, vel: 0.16),
      .init(step: 10, voice: .hat, vel: 0.38),
      .init(step: 11, voice: .hat, vel: 0.16),
      .init(step: 12, voice: .hat, vel: 0.22),
      .init(step: 13, voice: .hat, vel: 0.16),
      .init(step: 14, voice: .hat, vel: 0.42),
      .init(step: 15, voice: .hat, vel: 0.18),
      .init(step: 14, voice: .ohat, vel: 0.28),
      .init(step: 4, voice: .clap, vel: 0.4),
      .init(step: 12, voice: .clap, vel: 0.55),
    ]),
    DrumPattern(id: "dilla", name: "Late Pocket", feel: "Drunk swing", bars: 1, swing: 0.28, hits: [
      .init(step: 0, voice: .kick, vel: 1),
      .init(step: 5, voice: .kick, vel: 0.55),
      .init(step: 11, voice: .kick, vel: 0.8),
      .init(step: 4, voice: .snare, vel: 0.78),
      .init(step: 12, voice: .snare, vel: 0.95),
      .init(step: 13, voice: .snare, vel: 0.22),
      .init(step: 0, voice: .hat, vel: 0.4),
      .init(step: 3, voice: .hat, vel: 0.22),
      .init(step: 4, voice: .hat, vel: 0.38),
      .init(step: 7, voice: .hat, vel: 0.18),
      .init(step: 8, voice: .hat, vel: 0.42),
      .init(step: 11, voice: .hat, vel: 0.2),
      .init(step: 12, voice: .hat, vel: 0.36),
      .init(step: 15, voice: .hat, vel: 0.16),
      .init(step: 6, voice: .rim, vel: 0.32),
    ]),
    DrumPattern(id: "garage", name: "UK Garage", feel: "Skip beat", bars: 2, swing: 0.22, hits: [
      .init(step: 0, voice: .kick, vel: 1),
      .init(step: 10, voice: .kick, vel: 0.85),
      .init(step: 16, voice: .kick, vel: 0.7),
      .init(step: 20, voice: .kick, vel: 0.9),
      .init(step: 4, voice: .snare, vel: 0.55),
      .init(step: 12, voice: .snare, vel: 0.95),
      .init(step: 28, voice: .snare, vel: 0.9),
      .init(step: 6, voice: .snare, vel: 0.25),
      .init(step: 22, voice: .rim, vel: 0.4),
      .init(step: 14, voice: .ohat, vel: 0.45),
      .init(step: 30, voice: .ohat, vel: 0.4),
      .init(step: 0, voice: .hat, vel: 0.16),
      .init(step: 2, voice: .hat, vel: 0.55),
      .init(step: 4, voice: .hat, vel: 0.18),
      .init(step: 6, voice: .hat, vel: 0.52),
      .init(step: 8, voice: .hat, vel: 0.15),
      .init(step: 10, voice: .hat, vel: 0.5),
      .init(step: 12, voice: .hat, vel: 0.17),
      .init(step: 14, voice: .hat, vel: 0.58),
      .init(step: 16, voice: .hat, vel: 0.16),
      .init(step: 18, voice: .hat, vel: 0.52),
      .init(step: 20, voice: .hat, vel: 0.18),
      .init(step: 22, voice: .hat, vel: 0.5),
      .init(step: 24, voice: .hat, vel: 0.14),
      .init(step: 26, voice: .hat, vel: 0.54),
      .init(step: 28, voice: .hat, vel: 0.16),
      .init(step: 30, voice: .hat, vel: 0.48),
    ]),
    DrumPattern(id: "brush", name: "Rim & Brush", feel: "Quiet room", bars: 1, swing: 0.14, hits: [
      .init(step: 0, voice: .kick, vel: 0.55),
      .init(step: 8, voice: .kick, vel: 0.4),
      .init(step: 4, voice: .rim, vel: 0.7),
      .init(step: 12, voice: .rim, vel: 0.8),
      .init(step: 10, voice: .rim, vel: 0.3),
      .init(step: 0, voice: .hat, vel: 0.28),
      .init(step: 2, voice: .hat, vel: 0.18),
      .init(step: 4, voice: .hat, vel: 0.26),
      .init(step: 6, voice: .hat, vel: 0.16),
      .init(step: 8, voice: .hat, vel: 0.28),
      .init(step: 10, voice: .hat, vel: 0.16),
      .init(step: 12, voice: .hat, vel: 0.26),
      .init(step: 14, voice: .hat, vel: 0.14),
      .init(step: 6, voice: .perc, vel: 0.25),
    ]),
    DrumPattern(id: "world", name: "World Perc", feel: "Hand drums", bars: 2, swing: 0.1, hits: [
      .init(step: 0, voice: .kick, vel: 0.85),
      .init(step: 7, voice: .kick, vel: 0.5),
      .init(step: 16, voice: .kick, vel: 0.8),
      .init(step: 23, voice: .kick, vel: 0.55),
      .init(step: 4, voice: .tom, vel: 0.7),
      .init(step: 12, voice: .tom, vel: 0.55),
      .init(step: 20, voice: .tom, vel: 0.75),
      .init(step: 28, voice: .tom, vel: 0.6),
      .init(step: 2, voice: .perc, vel: 0.55),
      .init(step: 3, voice: .perc, vel: 0.35),
      .init(step: 6, voice: .perc, vel: 0.6),
      .init(step: 10, voice: .perc, vel: 0.5),
      .init(step: 14, voice: .perc, vel: 0.45),
      .init(step: 18, voice: .perc, vel: 0.55),
      .init(step: 22, voice: .perc, vel: 0.4),
      .init(step: 26, voice: .perc, vel: 0.6),
      .init(step: 30, voice: .perc, vel: 0.35),
      .init(step: 8, voice: .rim, vel: 0.4),
      .init(step: 24, voice: .rim, vel: 0.45),
      .init(step: 0, voice: .hat, vel: 0.22),
      .init(step: 8, voice: .hat, vel: 0.22),
      .init(step: 16, voice: .hat, vel: 0.22),
      .init(step: 24, voice: .hat, vel: 0.22),
    ]),
    DrumPattern(id: "trap", name: "Trap Hat", feel: "Rolls", bars: 1, swing: 0.02, hits: [
      .init(step: 0, voice: .kick, vel: 1),
      .init(step: 7, voice: .kick, vel: 0.7),
      .init(step: 10, voice: .kick, vel: 0.55),
      .init(step: 4, voice: .snare, vel: 0.85),
      .init(step: 12, voice: .snare, vel: 1),
      .init(step: 0, voice: .hat, vel: 0.42),
      .init(step: 1, voice: .hat, vel: 0.22),
      .init(step: 2, voice: .hat, vel: 0.38),
      .init(step: 3, voice: .hat, vel: 0.18),
      .init(step: 4, voice: .hat, vel: 0.42),
      .init(step: 5, voice: .hat, vel: 0.2),
      .init(step: 6, voice: .hat, vel: 0.55),
      .init(step: 7, voice: .hat, vel: 0.18),
      .init(step: 8, voice: .hat, vel: 0.42),
      .init(step: 9, voice: .hat, vel: 0.22),
      .init(step: 10, voice: .hat, vel: 0.38),
      .init(step: 11, voice: .hat, vel: 0.55),
      .init(step: 12, voice: .hat, vel: 0.42),
      .init(step: 13, voice: .hat, vel: 0.2),
      .init(step: 14, voice: .hat, vel: 0.6),
      .init(step: 15, voice: .hat, vel: 0.28),
    ]),
    DrumPattern(id: "dnb", name: "DnB Break", feel: "Amen ghost", bars: 2, swing: 0.08, hits: [
      .init(step: 0, voice: .kick, vel: 1),
      .init(step: 5, voice: .kick, vel: 0.55),
      .init(step: 10, voice: .kick, vel: 0.8),
      .init(step: 16, voice: .kick, vel: 1),
      .init(step: 21, voice: .kick, vel: 0.5),
      .init(step: 4, voice: .snare, vel: 0.95),
      .init(step: 12, voice: .snare, vel: 1),
      .init(step: 20, voice: .snare, vel: 0.95),
      .init(step: 28, voice: .snare, vel: 1),
      .init(step: 6, voice: .snare, vel: 0.28),
      .init(step: 14, voice: .snare, vel: 0.32),
      .init(step: 22, voice: .snare, vel: 0.25),
      .init(step: 26, voice: .snare, vel: 0.4),
      .init(step: 2, voice: .hat, vel: 0.4),
      .init(step: 6, voice: .hat, vel: 0.35),
      .init(step: 10, voice: .hat, vel: 0.4),
      .init(step: 14, voice: .ohat, vel: 0.45),
      .init(step: 18, voice: .hat, vel: 0.35),
      .init(step: 22, voice: .hat, vel: 0.4),
      .init(step: 26, voice: .hat, vel: 0.32),
      .init(step: 30, voice: .ohat, vel: 0.4),
    ]),
    DrumPattern(id: "punk", name: "Punk 8ths", feel: "Ramones", bars: 1, swing: 0.0, hits: [
      .init(step: 0, voice: .kick, vel: 1),
      .init(step: 2, voice: .kick, vel: 0.85),
      .init(step: 4, voice: .kick, vel: 1),
      .init(step: 6, voice: .kick, vel: 0.85),
      .init(step: 8, voice: .kick, vel: 1),
      .init(step: 10, voice: .kick, vel: 0.85),
      .init(step: 12, voice: .kick, vel: 1),
      .init(step: 14, voice: .kick, vel: 0.85),
      .init(step: 4, voice: .snare, vel: 1),
      .init(step: 12, voice: .snare, vel: 1),
      .init(step: 0, voice: .ohat, vel: 0.4),
      .init(step: 2, voice: .hat, vel: 0.45),
      .init(step: 4, voice: .ohat, vel: 0.4),
      .init(step: 6, voice: .hat, vel: 0.45),
      .init(step: 8, voice: .ohat, vel: 0.4),
      .init(step: 10, voice: .hat, vel: 0.45),
      .init(step: 12, voice: .ohat, vel: 0.4),
      .init(step: 14, voice: .hat, vel: 0.45),
    ]),
    DrumPattern(id: "industrial", name: "Industrial", feel: "Cold plant", bars: 2, swing: 0.0, hits: [
      .init(step: 0, voice: .kick, vel: 1),
      .init(step: 8, voice: .kick, vel: 0.7),
      .init(step: 16, voice: .kick, vel: 1),
      .init(step: 24, voice: .kick, vel: 0.65),
      .init(step: 4, voice: .rim, vel: 0.85),
      .init(step: 12, voice: .snare, vel: 1),
      .init(step: 20, voice: .rim, vel: 0.7),
      .init(step: 28, voice: .snare, vel: 1),
      .init(step: 6, voice: .perc, vel: 0.55),
      .init(step: 14, voice: .perc, vel: 0.4),
      .init(step: 22, voice: .tom, vel: 0.6),
      .init(step: 30, voice: .perc, vel: 0.5),
      .init(step: 2, voice: .hat, vel: 0.2),
      .init(step: 10, voice: .hat, vel: 0.18),
      .init(step: 18, voice: .hat, vel: 0.2),
      .init(step: 26, voice: .hat, vel: 0.18),
    ]),
    DrumPattern(id: "dembow", name: "Dembow", feel: "3–3–2", bars: 1, swing: 0.04, hits: [
      .init(step: 0, voice: .kick, vel: 1),
      .init(step: 6, voice: .kick, vel: 0.85),
      .init(step: 10, voice: .kick, vel: 0.75),
      .init(step: 4, voice: .snare, vel: 0.7),
      .init(step: 12, voice: .snare, vel: 0.95),
      .init(step: 0, voice: .hat, vel: 0.4),
      .init(step: 2, voice: .hat, vel: 0.28),
      .init(step: 4, voice: .hat, vel: 0.45),
      .init(step: 6, voice: .hat, vel: 0.28),
      .init(step: 8, voice: .hat, vel: 0.4),
      .init(step: 10, voice: .hat, vel: 0.3),
      .init(step: 12, voice: .hat, vel: 0.5),
      .init(step: 14, voice: .hat, vel: 0.26),
      .init(step: 8, voice: .perc, vel: 0.45),
    ]),
    DrumPattern(id: "footwork", name: "Footwork", feel: "Juke skip", bars: 1, swing: 0.0, hits: [
      .init(step: 0, voice: .kick, vel: 1),
      .init(step: 3, voice: .kick, vel: 0.7),
      .init(step: 6, voice: .kick, vel: 0.85),
      .init(step: 9, voice: .kick, vel: 0.6),
      .init(step: 12, voice: .kick, vel: 0.9),
      .init(step: 4, voice: .snare, vel: 0.55),
      .init(step: 11, voice: .snare, vel: 0.8),
      .init(step: 0, voice: .hat, vel: 0.5),
      .init(step: 1, voice: .hat, vel: 0.28),
      .init(step: 2, voice: .hat, vel: 0.5),
      .init(step: 3, voice: .hat, vel: 0.28),
      .init(step: 4, voice: .hat, vel: 0.5),
      .init(step: 5, voice: .hat, vel: 0.28),
      .init(step: 6, voice: .hat, vel: 0.5),
      .init(step: 7, voice: .hat, vel: 0.28),
      .init(step: 8, voice: .hat, vel: 0.5),
      .init(step: 9, voice: .hat, vel: 0.28),
      .init(step: 10, voice: .hat, vel: 0.5),
      .init(step: 11, voice: .hat, vel: 0.28),
      .init(step: 12, voice: .hat, vel: 0.5),
      .init(step: 13, voice: .hat, vel: 0.28),
      .init(step: 14, voice: .ohat, vel: 0.45),
      .init(step: 15, voice: .hat, vel: 0.3),
    ]),
    DrumPattern(id: "acid", name: "Acid Night", feel: "Offbeat hat", bars: 1, swing: 0.0, hits: [
      .init(step: 0, voice: .kick, vel: 1),
      .init(step: 4, voice: .kick, vel: 1),
      .init(step: 8, voice: .kick, vel: 1),
      .init(step: 12, voice: .kick, vel: 1),
      .init(step: 2, voice: .ohat, vel: 0.55),
      .init(step: 6, voice: .ohat, vel: 0.5),
      .init(step: 10, voice: .ohat, vel: 0.55),
      .init(step: 14, voice: .ohat, vel: 0.6),
      .init(step: 4, voice: .clap, vel: 0.45),
      .init(step: 12, voice: .clap, vel: 0.7),
      .init(step: 7, voice: .perc, vel: 0.35),
      .init(step: 15, voice: .rim, vel: 0.3),
    ]),
    DrumPattern(id: "wrecked", name: "Wrecked", feel: "Broken kit", bars: 2, swing: 0.2, hits: [
      .init(step: 0, voice: .kick, vel: 1),
      .init(step: 5, voice: .kick, vel: 0.4),
      .init(step: 11, voice: .kick, vel: 0.75),
      .init(step: 17, voice: .kick, vel: 0.55),
      .init(step: 24, voice: .kick, vel: 0.95),
      .init(step: 4, voice: .snare, vel: 0.7),
      .init(step: 13, voice: .snare, vel: 0.45),
      .init(step: 20, voice: .snare, vel: 0.85),
      .init(step: 27, voice: .snare, vel: 0.5),
      .init(step: 7, voice: .rim, vel: 0.4),
      .init(step: 15, voice: .tom, vel: 0.5),
      .init(step: 22, voice: .perc, vel: 0.45),
      .init(step: 30, voice: .ohat, vel: 0.4),
      .init(step: 0, voice: .hat, vel: 0.3),
      .init(step: 3, voice: .hat, vel: 0.18),
      .init(step: 8, voice: .hat, vel: 0.32),
      .init(step: 16, voice: .hat, vel: 0.28),
      .init(step: 19, voice: .hat, vel: 0.16),
      .init(step: 25, voice: .hat, vel: 0.3),
    ]),
    // Slow, dusty downtempo.
    DrumPattern(id: "dusty", name: "Dusty Downtempo", feel: "Downtempo, 80-92 BPM", bars: 1, swing: 0.32, hits: [
      .init(step: 0, voice: .hat, vel: 0.45),
      .init(step: 0, voice: .kick, vel: 1.0),
      .init(step: 2, voice: .hat, vel: 0.22),
      .init(step: 4, voice: .hat, vel: 0.38),
      .init(step: 4, voice: .snare, vel: 0.78),
      .init(step: 6, voice: .hat, vel: 0.2),
      .init(step: 7, voice: .kick, vel: 0.5),
      .init(step: 8, voice: .hat, vel: 0.42),
      .init(step: 10, voice: .hat, vel: 0.24),
      .init(step: 10, voice: .kick, vel: 0.85),
      .init(step: 11, voice: .rim, vel: 0.25),
      .init(step: 12, voice: .hat, vel: 0.36),
      .init(step: 12, voice: .snare, vel: 0.86),
      .init(step: 14, voice: .hat, vel: 0.2),
      .init(step: 15, voice: .snare, vel: 0.18),
    ]),
    DrumPattern(id: "hazy", name: "Hazy Halftime", feel: "Downtempo halftime, 75-90 BPM", bars: 2, swing: 0.24, hits: [
      .init(step: 0, voice: .hat, vel: 0.3),
      .init(step: 0, voice: .kick, vel: 1.0),
      .init(step: 2, voice: .hat, vel: 0.18),
      .init(step: 4, voice: .hat, vel: 0.3),
      .init(step: 6, voice: .hat, vel: 0.18),
      .init(step: 8, voice: .hat, vel: 0.3),
      .init(step: 8, voice: .snare, vel: 0.85),
      .init(step: 10, voice: .hat, vel: 0.18),
      .init(step: 11, voice: .kick, vel: 0.6),
      .init(step: 12, voice: .hat, vel: 0.3),
      .init(step: 14, voice: .ohat, vel: 0.3),
      .init(step: 16, voice: .hat, vel: 0.3),
      .init(step: 18, voice: .hat, vel: 0.18),
      .init(step: 19, voice: .kick, vel: 0.7),
      .init(step: 20, voice: .hat, vel: 0.3),
      .init(step: 22, voice: .hat, vel: 0.18),
      .init(step: 22, voice: .perc, vel: 0.22),
      .init(step: 24, voice: .hat, vel: 0.3),
      .init(step: 24, voice: .snare, vel: 0.9),
      .init(step: 26, voice: .hat, vel: 0.18),
      .init(step: 26, voice: .kick, vel: 0.8),
      .init(step: 28, voice: .hat, vel: 0.3),
      .init(step: 29, voice: .snare, vel: 0.15),
      .init(step: 30, voice: .ohat, vel: 0.35),
    ]),
    DrumPattern(id: "faded", name: "Faded Break", feel: "Dusty break, 85-95 BPM", bars: 2, swing: 0.26, hits: [
      .init(step: 0, voice: .hat, vel: 0.38),
      .init(step: 0, voice: .kick, vel: 1.0),
      .init(step: 2, voice: .hat, vel: 0.24),
      .init(step: 4, voice: .hat, vel: 0.38),
      .init(step: 4, voice: .snare, vel: 0.85),
      .init(step: 6, voice: .hat, vel: 0.24),
      .init(step: 7, voice: .snare, vel: 0.2),
      .init(step: 8, voice: .hat, vel: 0.38),
      .init(step: 9, voice: .snare, vel: 0.16),
      .init(step: 10, voice: .hat, vel: 0.24),
      .init(step: 10, voice: .kick, vel: 0.85),
      .init(step: 12, voice: .hat, vel: 0.38),
      .init(step: 12, voice: .snare, vel: 0.9),
      .init(step: 14, voice: .ohat, vel: 0.3),
      .init(step: 16, voice: .hat, vel: 0.38),
      .init(step: 16, voice: .kick, vel: 1.0),
      .init(step: 18, voice: .hat, vel: 0.24),
      .init(step: 20, voice: .hat, vel: 0.38),
      .init(step: 20, voice: .snare, vel: 0.85),
      .init(step: 22, voice: .hat, vel: 0.24),
      .init(step: 23, voice: .snare, vel: 0.2),
      .init(step: 24, voice: .hat, vel: 0.38),
      .init(step: 26, voice: .hat, vel: 0.24),
      .init(step: 26, voice: .kick, vel: 0.8),
      .init(step: 28, voice: .hat, vel: 0.38),
      .init(step: 28, voice: .snare, vel: 0.95),
      .init(step: 30, voice: .hat, vel: 0.24),
      .init(step: 31, voice: .snare, vel: 0.18),
    ]),
    DrumPattern(id: "cassette", name: "Cassette Swing", feel: "Lazy swing, 78-88 BPM", bars: 1, swing: 0.4, hits: [
      .init(step: 0, voice: .hat, vel: 0.4),
      .init(step: 0, voice: .kick, vel: 1.0),
      .init(step: 2, voice: .hat, vel: 0.15),
      .init(step: 4, voice: .hat, vel: 0.35),
      .init(step: 4, voice: .rim, vel: 0.7),
      .init(step: 6, voice: .hat, vel: 0.15),
      .init(step: 6, voice: .kick, vel: 0.55),
      .init(step: 8, voice: .hat, vel: 0.4),
      .init(step: 9, voice: .kick, vel: 0.75),
      .init(step: 10, voice: .hat, vel: 0.15),
      .init(step: 12, voice: .hat, vel: 0.35),
      .init(step: 12, voice: .rim, vel: 0.75),
      .init(step: 12, voice: .snare, vel: 0.45),
      .init(step: 14, voice: .hat, vel: 0.2),
      .init(step: 14, voice: .perc, vel: 0.18),
    ]),
    DrumPattern(id: "drifter", name: "Slow Drift", feel: "Sparse downtempo, 70-85 BPM", bars: 2, swing: 0.3, hits: [
      .init(step: 0, voice: .kick, vel: 1.0),
      .init(step: 4, voice: .hat, vel: 0.25),
      .init(step: 6, voice: .rim, vel: 0.2),
      .init(step: 8, voice: .snare, vel: 0.8),
      .init(step: 12, voice: .hat, vel: 0.25),
      .init(step: 13, voice: .kick, vel: 0.55),
      .init(step: 16, voice: .kick, vel: 0.9),
      .init(step: 20, voice: .hat, vel: 0.25),
      .init(step: 22, voice: .rim, vel: 0.2),
      .init(step: 24, voice: .snare, vel: 0.85),
      .init(step: 27, voice: .kick, vel: 0.6),
      .init(step: 28, voice: .hat, vel: 0.25),
      .init(step: 30, voice: .ohat, vel: 0.3),
    ]),
    // Fast braindance / drill 'n' bass.
    DrumPattern(id: "drillbreak", name: "Drill Break", feel: "Drill 'n' bass, 160-180 BPM", bars: 2, swing: 0.04, hits: [
      .init(step: 0, voice: .hat, vel: 0.5),
      .init(step: 0, voice: .kick, vel: 1.0),
      .init(step: 1, voice: .hat, vel: 0.28),
      .init(step: 2, voice: .hat, vel: 0.5),
      .init(step: 3, voice: .hat, vel: 0.28),
      .init(step: 4, voice: .hat, vel: 0.5),
      .init(step: 4, voice: .snare, vel: 0.9),
      .init(step: 5, voice: .hat, vel: 0.28),
      .init(step: 6, voice: .hat, vel: 0.5),
      .init(step: 7, voice: .hat, vel: 0.28),
      .init(step: 7, voice: .snare, vel: 0.45),
      .init(step: 8, voice: .hat, vel: 0.5),
      .init(step: 9, voice: .hat, vel: 0.28),
      .init(step: 10, voice: .hat, vel: 0.5),
      .init(step: 10, voice: .kick, vel: 0.85),
      .init(step: 11, voice: .hat, vel: 0.28),
      .init(step: 12, voice: .hat, vel: 0.5),
      .init(step: 12, voice: .snare, vel: 0.95),
      .init(step: 13, voice: .hat, vel: 0.28),
      .init(step: 14, voice: .hat, vel: 0.5),
      .init(step: 14, voice: .snare, vel: 0.5),
      .init(step: 15, voice: .hat, vel: 0.28),
      .init(step: 15, voice: .snare, vel: 0.6),
      .init(step: 16, voice: .hat, vel: 0.5),
      .init(step: 16, voice: .kick, vel: 1.0),
      .init(step: 17, voice: .hat, vel: 0.28),
      .init(step: 17, voice: .kick, vel: 0.6),
      .init(step: 18, voice: .hat, vel: 0.5),
      .init(step: 19, voice: .hat, vel: 0.28),
      .init(step: 20, voice: .hat, vel: 0.5),
      .init(step: 20, voice: .snare, vel: 0.9),
      .init(step: 21, voice: .hat, vel: 0.28),
      .init(step: 22, voice: .hat, vel: 0.5),
      .init(step: 23, voice: .hat, vel: 0.28),
      .init(step: 23, voice: .snare, vel: 0.5),
      .init(step: 24, voice: .hat, vel: 0.5),
      .init(step: 25, voice: .hat, vel: 0.28),
      .init(step: 26, voice: .hat, vel: 0.5),
      .init(step: 26, voice: .kick, vel: 0.8),
      .init(step: 27, voice: .hat, vel: 0.28),
      .init(step: 27, voice: .snare, vel: 0.55),
      .init(step: 28, voice: .hat, vel: 0.5),
      .init(step: 28, voice: .snare, vel: 0.95),
      .init(step: 29, voice: .hat, vel: 0.28),
      .init(step: 29, voice: .snare, vel: 0.6),
      .init(step: 30, voice: .hat, vel: 0.5),
      .init(step: 30, voice: .snare, vel: 0.75),
      .init(step: 31, voice: .hat, vel: 0.28),
      .init(step: 31, voice: .snare, vel: 0.9),
    ]),
    DrumPattern(id: "braindance", name: "Braindance", feel: "Braindance, 150-175 BPM", bars: 1, swing: 0.0, hits: [
      .init(step: 0, voice: .hat, vel: 0.45),
      .init(step: 0, voice: .kick, vel: 1.0),
      .init(step: 1, voice: .hat, vel: 0.25),
      .init(step: 2, voice: .hat, vel: 0.45),
      .init(step: 3, voice: .hat, vel: 0.25),
      .init(step: 3, voice: .kick, vel: 0.7),
      .init(step: 4, voice: .hat, vel: 0.45),
      .init(step: 4, voice: .snare, vel: 0.9),
      .init(step: 5, voice: .hat, vel: 0.25),
      .init(step: 6, voice: .hat, vel: 0.45),
      .init(step: 6, voice: .snare, vel: 0.25),
      .init(step: 7, voice: .hat, vel: 0.25),
      .init(step: 7, voice: .perc, vel: 0.25),
      .init(step: 8, voice: .hat, vel: 0.45),
      .init(step: 8, voice: .kick, vel: 0.9),
      .init(step: 9, voice: .hat, vel: 0.25),
      .init(step: 9, voice: .snare, vel: 0.3),
      .init(step: 10, voice: .hat, vel: 0.45),
      .init(step: 10, voice: .perc, vel: 0.35),
      .init(step: 11, voice: .hat, vel: 0.25),
      .init(step: 11, voice: .kick, vel: 0.65),
      .init(step: 12, voice: .hat, vel: 0.45),
      .init(step: 12, voice: .snare, vel: 0.95),
      .init(step: 13, voice: .hat, vel: 0.25),
      .init(step: 13, voice: .kick, vel: 0.8),
      .init(step: 14, voice: .hat, vel: 0.45),
      .init(step: 15, voice: .hat, vel: 0.25),
      .init(step: 15, voice: .snare, vel: 0.35),
    ]),
    DrumPattern(id: "skitter", name: "Skitter", feel: "Skittering IDM, 150-170 BPM", bars: 2, swing: 0.02, hits: [
      .init(step: 0, voice: .hat, vel: 0.42),
      .init(step: 0, voice: .kick, vel: 1.0),
      .init(step: 1, voice: .hat, vel: 0.24),
      .init(step: 2, voice: .hat, vel: 0.42),
      .init(step: 4, voice: .hat, vel: 0.42),
      .init(step: 4, voice: .snare, vel: 0.85),
      .init(step: 5, voice: .hat, vel: 0.24),
      .init(step: 6, voice: .hat, vel: 0.42),
      .init(step: 6, voice: .kick, vel: 0.7),
      .init(step: 7, voice: .ohat, vel: 0.35),
      .init(step: 8, voice: .hat, vel: 0.42),
      .init(step: 9, voice: .hat, vel: 0.24),
      .init(step: 10, voice: .hat, vel: 0.42),
      .init(step: 10, voice: .rim, vel: 0.3),
      .init(step: 11, voice: .hat, vel: 0.24),
      .init(step: 12, voice: .hat, vel: 0.42),
      .init(step: 12, voice: .snare, vel: 0.9),
      .init(step: 13, voice: .hat, vel: 0.24),
      .init(step: 14, voice: .hat, vel: 0.42),
      .init(step: 14, voice: .rim, vel: 0.3),
      .init(step: 15, voice: .hat, vel: 0.24),
      .init(step: 16, voice: .hat, vel: 0.42),
      .init(step: 16, voice: .kick, vel: 1.0),
      .init(step: 17, voice: .hat, vel: 0.24),
      .init(step: 18, voice: .hat, vel: 0.42),
      .init(step: 19, voice: .kick, vel: 0.6),
      .init(step: 20, voice: .hat, vel: 0.42),
      .init(step: 20, voice: .snare, vel: 0.85),
      .init(step: 21, voice: .hat, vel: 0.24),
      .init(step: 22, voice: .hat, vel: 0.42),
      .init(step: 23, voice: .ohat, vel: 0.35),
      .init(step: 24, voice: .hat, vel: 0.42),
      .init(step: 25, voice: .hat, vel: 0.24),
      .init(step: 25, voice: .kick, vel: 0.75),
      .init(step: 26, voice: .hat, vel: 0.42),
      .init(step: 26, voice: .snare, vel: 0.5),
      .init(step: 27, voice: .hat, vel: 0.24),
      .init(step: 27, voice: .snare, vel: 0.6),
      .init(step: 28, voice: .hat, vel: 0.42),
      .init(step: 28, voice: .snare, vel: 0.9),
      .init(step: 29, voice: .hat, vel: 0.24),
      .init(step: 30, voice: .ohat, vel: 0.4),
      .init(step: 31, voice: .hat, vel: 0.24),
    ]),
    DrumPattern(id: "ratchet", name: "Ratchet Roll", feel: "Rolling snares, 165-180 BPM", bars: 1, swing: 0.0, hits: [
      .init(step: 0, voice: .hat, vel: 0.4),
      .init(step: 0, voice: .kick, vel: 1.0),
      .init(step: 2, voice: .hat, vel: 0.4),
      .init(step: 2, voice: .kick, vel: 0.55),
      .init(step: 4, voice: .hat, vel: 0.4),
      .init(step: 4, voice: .snare, vel: 0.9),
      .init(step: 6, voice: .hat, vel: 0.4),
      .init(step: 7, voice: .kick, vel: 0.8),
      .init(step: 8, voice: .hat, vel: 0.4),
      .init(step: 10, voice: .hat, vel: 0.4),
      .init(step: 10, voice: .kick, vel: 0.85),
      .init(step: 11, voice: .hat, vel: 0.3),
      .init(step: 12, voice: .snare, vel: 0.6),
      .init(step: 13, voice: .snare, vel: 0.7),
      .init(step: 14, voice: .snare, vel: 0.8),
      .init(step: 15, voice: .snare, vel: 0.95),
    ]),
    DrumPattern(id: "splinter", name: "Splintered Break", feel: "Chopped break, 165-180 BPM", bars: 2, swing: 0.06, hits: [
      .init(step: 0, voice: .hat, vel: 0.42),
      .init(step: 0, voice: .kick, vel: 1.0),
      .init(step: 2, voice: .hat, vel: 0.42),
      .init(step: 4, voice: .hat, vel: 0.42),
      .init(step: 4, voice: .snare, vel: 0.9),
      .init(step: 6, voice: .hat, vel: 0.42),
      .init(step: 7, voice: .snare, vel: 0.35),
      .init(step: 8, voice: .hat, vel: 0.42),
      .init(step: 9, voice: .snare, vel: 0.3),
      .init(step: 10, voice: .hat, vel: 0.42),
      .init(step: 10, voice: .kick, vel: 0.85),
      .init(step: 11, voice: .kick, vel: 0.5),
      .init(step: 12, voice: .hat, vel: 0.42),
      .init(step: 12, voice: .snare, vel: 0.95),
      .init(step: 13, voice: .hat, vel: 0.3),
      .init(step: 14, voice: .ohat, vel: 0.3),
      .init(step: 15, voice: .snare, vel: 0.4),
      .init(step: 16, voice: .hat, vel: 0.42),
      .init(step: 16, voice: .kick, vel: 0.95),
      .init(step: 18, voice: .hat, vel: 0.42),
      .init(step: 20, voice: .hat, vel: 0.42),
      .init(step: 20, voice: .snare, vel: 0.9),
      .init(step: 22, voice: .hat, vel: 0.42),
      .init(step: 22, voice: .snare, vel: 0.45),
      .init(step: 24, voice: .hat, vel: 0.42),
      .init(step: 25, voice: .snare, vel: 0.4),
      .init(step: 26, voice: .hat, vel: 0.42),
      .init(step: 26, voice: .kick, vel: 0.8),
      .init(step: 27, voice: .kick, vel: 0.6),
      .init(step: 28, voice: .hat, vel: 0.42),
      .init(step: 28, voice: .snare, vel: 1.0),
      .init(step: 29, voice: .hat, vel: 0.3),
      .init(step: 30, voice: .hat, vel: 0.42),
      .init(step: 30, voice: .snare, vel: 0.7),
    ]),
  ]
  static func find(_ id: String) -> DrumPattern { all.first { $0.id == id } ?? all[0] }

  static let fills: [DrumPattern] = [
    DrumPattern(id: "fill-roll", name: "Snare roll", feel: "Build", bars: 1, swing: 0.0, hits: [
      .init(step: 0, voice: .snare, vel: 0.18),
      .init(step: 1, voice: .snare, vel: 0.24),
      .init(step: 2, voice: .snare, vel: 0.3),
      .init(step: 3, voice: .snare, vel: 0.38),
      .init(step: 4, voice: .snare, vel: 0.46),
      .init(step: 5, voice: .snare, vel: 0.55),
      .init(step: 6, voice: .snare, vel: 0.64),
      .init(step: 7, voice: .snare, vel: 0.74),
      .init(step: 8, voice: .snare, vel: 0.62),
      .init(step: 9, voice: .snare, vel: 0.72),
      .init(step: 10, voice: .snare, vel: 0.84),
      .init(step: 11, voice: .snare, vel: 0.94),
      .init(step: 12, voice: .tom, vel: 0.85),
      .init(step: 14, voice: .kick, vel: 1),
      .init(step: 14, voice: .snare, vel: 1),
    ]),
    DrumPattern(id: "fill-toms", name: "Tom run", feel: "Down the kit", bars: 1, swing: 0.06, hits: [
      .init(step: 0, voice: .tom, vel: 0.7),
      .init(step: 2, voice: .tom, vel: 0.75),
      .init(step: 4, voice: .tom, vel: 0.8),
      .init(step: 6, voice: .snare, vel: 0.7),
      .init(step: 8, voice: .tom, vel: 0.85),
      .init(step: 10, voice: .snare, vel: 0.8),
      .init(step: 12, voice: .kick, vel: 0.9),
      .init(step: 13, voice: .snare, vel: 0.75),
      .init(step: 14, voice: .kick, vel: 1),
      .init(step: 15, voice: .snare, vel: 1),
    ]),
    DrumPattern(id: "fill-break", name: "Break fill", feel: "Stop-start", bars: 1, swing: 0.1, hits: [
      .init(step: 0, voice: .kick, vel: 1),
      .init(step: 3, voice: .snare, vel: 0.7),
      .init(step: 6, voice: .kick, vel: 0.8),
      .init(step: 8, voice: .snare, vel: 0.9),
      .init(step: 9, voice: .snare, vel: 0.4),
      .init(step: 11, voice: .tom, vel: 0.7),
      .init(step: 12, voice: .ohat, vel: 0.5),
      .init(step: 14, voice: .kick, vel: 1),
      .init(step: 15, voice: .snare, vel: 1),
    ]),
    DrumPattern(id: "fill-hats", name: "Hat choke", feel: "16ths into crash", bars: 1, swing: 0.0, hits: [
      .init(step: 0, voice: .hat, vel: 0.4),
      .init(step: 1, voice: .hat, vel: 0.45),
      .init(step: 2, voice: .hat, vel: 0.5),
      .init(step: 3, voice: .hat, vel: 0.55),
      .init(step: 4, voice: .hat, vel: 0.6),
      .init(step: 5, voice: .hat, vel: 0.65),
      .init(step: 6, voice: .hat, vel: 0.7),
      .init(step: 7, voice: .hat, vel: 0.75),
      .init(step: 8, voice: .ohat, vel: 0.7),
      .init(step: 10, voice: .snare, vel: 0.55),
      .init(step: 12, voice: .kick, vel: 0.9),
      .init(step: 14, voice: .snare, vel: 1),
      .init(step: 14, voice: .kick, vel: 1),
    ]),
  ]
}

/// Jam mode: plays the groove the way a drummer would, in 8-bar phrases.
/// - Every bar after the first: subtle variation of the same groove (hat density,
///   accents, open hat, ghost snares). The kick on 1 and the backbeat never move.
/// - Bar 4 ends with a pickup; bar 8's second half is a half-bar fill.
/// - Every 16 bars, right after a fill, a new groove from the same family.
enum Jam {
  static let phraseBars = 8
  static let phrasesPerGroove = 2  // 16 bars

  /// Grooves that can follow each other without the song lurching style.
  private static let families: [[String]] = [
    ["floor", "techno", "acid", "industrial"],
    ["pocket", "boombap", "dilla", "brush", "shuffle"],
    ["break", "dnb", "garage", "wrecked"],
    ["halftime", "trap", "footwork"],
    ["clave", "world", "dembow"],
    ["punk"],
    ["dusty", "hazy", "faded", "cassette", "drifter"],
    ["drillbreak", "braindance", "skitter", "ratchet", "splinter"],
  ]

  static func family(of id: String) -> [String] {
    families.first { $0.contains(id) } ?? [id]
  }

  /// A different groove from the same family, or the same one if it has no siblings.
  static func nextGroove(after id: String, rng: inout JamRng) -> String {
    let others = family(of: id).filter { $0 != id }
    guard !others.isEmpty else { return id }
    return others[Int(rng.unit() * Double(others.count)) % others.count]
  }

  /// One 8-bar phrase of `groove`, with `fill`'s second half in the last half bar.
  static func phrase(groove g: DrumPattern, fill: DrumPattern, seed: UInt64) -> DrumPattern {
    var rng = JamRng(seed: seed)
    let fourFloor = family(of: g.id).contains("floor")
    var hits: [DrumHit] = []
    for bar in 0..<phraseBars {
      let src = bar % max(1, g.bars)
      var h = g.hits
        .filter { $0.step / 16 == src }
        .map { DrumHit(step: $0.step % 16, voice: $0.voice, vel: $0.vel) }
      // Bar 1 of each phrase states the groove plainly.
      if bar > 0 { vary(&h, rng: &rng) }
      if bar == 3 { pickup(&h, fourFloor: fourFloor, rng: &rng) }
      if bar == phraseBars - 1 {
        h = h.filter { $0.step < 8 } + fill.hits.filter { $0.step >= 8 && $0.step < 16 }
      }
      hits += h.map { DrumHit(step: $0.step + bar * 16, voice: $0.voice, vel: $0.vel) }
    }
    return DrumPattern(id: "\(g.id)-jam-\(seed)", name: g.name, feel: g.feel, bars: phraseBars, swing: g.swing, hits: hits)
  }

  private static func has(_ h: [DrumHit], _ step: Int, _ voices: Set<DrumVoice>) -> Bool {
    h.contains { $0.step == step && voices.contains($0.voice) }
  }

  /// Subtle, groove-preserving changes. Only hats, open hats and ghost notes are
  /// added or moved; kick and backbeat hits are left where they are.
  private static func vary(_ h: inout [DrumHit], rng: inout JamRng) {
    // Accent drift: hats breathe a little, everything else barely moves.
    for i in h.indices {
      let amt: Double = h[i].voice == .hat ? 0.14 : 0.04
      h[i].vel = max(0.05, min(1, h[i].vel * Float(1 + (rng.unit() * 2 - 1) * amt)))
    }
    let hats = h.filter { $0.voice == .hat }
    if !hats.isEmpty, rng.unit() < 0.3 {
      let sixteenths = hats.contains { $0.step % 2 == 1 }
      if sixteenths {
        // Thin one off-16th.
        let odd = h.indices.filter { h[$0].voice == .hat && h[$0].step % 2 == 1 }
        if let i = odd.randomElement(using: &rng) { h.remove(at: i) }
      } else {
        // Add one or two soft 16ths.
        for _ in 0..<(rng.unit() < 0.5 ? 1 : 2) {
          if let s = [3, 7, 11, 15].filter({ !has(h, $0, [.hat, .ohat]) }).randomElement(using: &rng) {
            h.append(DrumHit(step: s, voice: .hat, vel: Float(0.28 + rng.unit() * 0.14)))
          }
        }
      }
    }
    if !hats.isEmpty, rng.unit() < 0.2 {
      // Open hat on the "and" of 4.
      if let i = h.firstIndex(where: { $0.step == 14 && $0.voice == .hat }) {
        h[i] = DrumHit(step: 14, voice: .ohat, vel: h[i].vel * 0.9)
      } else if !has(h, 14, [.ohat]) {
        h.append(DrumHit(step: 14, voice: .ohat, vel: 0.5))
      }
    }
    if rng.unit() < 0.25 {
      // Ghost snare in a gap.
      if let s = [7, 9, 15, 3].filter({ !has(h, $0, [.snare, .clap, .kick]) }).randomElement(using: &rng) {
        h.append(DrumHit(step: s, voice: .snare, vel: Float(0.14 + rng.unit() * 0.1)))
      }
    }
  }

  /// End-of-bar-4 pickup into the second half of the phrase.
  private static func pickup(_ h: inout [DrumHit], fourFloor: Bool, rng: inout JamRng) {
    guard rng.unit() < 0.75 else { return }
    if fourFloor {
      // A kick pickup breaks four-on-the-floor; an open hat lifts it instead.
      if let i = h.firstIndex(where: { $0.step == 14 && $0.voice == .hat }) {
        h[i] = DrumHit(step: 14, voice: .ohat, vel: 0.6)
      } else if !has(h, 14, [.ohat]) {
        h.append(DrumHit(step: 14, voice: .ohat, vel: 0.55))
      }
    } else if let s = [14, 15].filter({ !has(h, $0, [.kick]) }).randomElement(using: &rng) {
      h.append(DrumHit(step: s, voice: .kick, vel: Float(0.55 + rng.unit() * 0.2)))
    }
  }
}

/// Seeded random for jam phrases (reproducible per phrase, no system random).
struct JamRng: RandomNumberGenerator {
  private var s: UInt64
  init(seed: UInt64) { s = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
  mutating func next() -> UInt64 {
    s &+= 0x9E37_79B9_7F4A_7C15
    var z = s
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
  mutating func unit() -> Double { Double(next() >> 11) * 0x1.0p-53 }
}
