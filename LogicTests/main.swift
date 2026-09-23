import Foundation

@main
struct LogicTests {
  static func main() {
    var failed = 0
    func expect(_ cond: Bool, _ msg: String) {
      if !cond {
        fputs("FAIL \(msg)\n", stderr)
        failed += 1
      }
    }

    expect(MusicKey.contains(60, root: 0, mode: .major), "C major contains C4")
    expect(MusicKey.contains(64, root: 0, mode: .major), "C major contains E4")
    expect(!MusicKey.contains(61, root: 0, mode: .major), "C major rejects C#")
    expect(MusicKey.contains(70, root: 5, mode: .major), "F major contains Bb")
    expect(MusicKey.contains(60, root: 9, mode: .minor), "A minor contains C")
    expect(!MusicKey.contains(61, root: 9, mode: .minor), "A minor rejects C#")
    expect(MusicKey.contains(61, root: 0, mode: .chromatic), "chromatic contains C#")

    let cMaj = MusicKey.padNotes(root: 0, mode: .major, octave: 0)
    expect(cMaj.count == 16, "C major has 16 pads, got \(cMaj.count)")
    expect(cMaj.first?.midi == 48, "C major starts at C3, got \(cMaj.first?.midi ?? -1)")
    expect(cMaj.allSatisfy { MusicKey.contains($0.midi, root: 0, mode: .major) }, "every C major pad in key")
    expect(cMaj.filter(\.isRoot).count >= 2, "multiple tonics marked")
    expect(cMaj[0].label == "C", "first pad labeled C")

    let fMaj = MusicKey.padNotes(root: 5, mode: .major, octave: 0)
    expect(fMaj.first?.label == "F", "F major starts on F, got \(fMaj.first?.label ?? "?")")
    expect(fMaj.contains(where: { $0.label == "Bb" }), "F major spells Bb")

    let aMin = MusicKey.padNotes(root: 9, mode: .minor, octave: 0)
    expect(aMin.first?.label == "A", "A minor starts on A")
    expect(aMin.contains(where: { $0.label == "C" }), "A minor includes C")
    expect(!aMin.contains(where: { $0.label == "C#" || $0.label == "G#" }), "A minor uses flats relative")

    let chrom = MusicKey.padNotes(root: 0, mode: .chromatic, octave: 0)
    expect(chrom.count == 12, "chromatic is one octave, got \(chrom.count)")

    expect(abs(PitchMath.step(midi: 72, root: 60, srcRate: 44100, dstRate: 44100) - 2) < 1e-9, "octave doubles")
    expect(abs(PitchMath.step(midi: 60, root: 60, srcRate: 44100, dstRate: 44100) - 1) < 1e-9, "unison is 1")
    let fifth = PitchMath.step(midi: 67, root: 60, srcRate: 48000, dstRate: 48000)
    expect(abs(fifth - pow(2.0, 7.0 / 12.0)) < 1e-9, "fifth ratio")

    let src = (0..<441).map { Float(sin(Double($0) * 0.1)) }
    let up = PitchMath.resample(src, from: 44100, to: 48000)
    expect(up.count > src.count, "upsample grows")
    let same = PitchMath.resample(src, from: 44100, to: 44100)
    expect(same.count == src.count, "same rate preserves length")

    if let midi = MusicKey.midiForTypeKey("a", pads: cMaj) {
      expect(midi == cMaj[0].midi, "home row A is first pad")
    } else {
      expect(false, "typing map missed A")
    }
    expect(MusicKey.midiForTypeKey("q", pads: cMaj) == nil, "unmapped key is nil")

    expect(abs(MetroTiming.beatSec(bpm: 60) - 1) < 1e-9, "60 BPM beat is 1s")
    expect(abs(MetroTiming.beatSec(bpm: 120) - 0.5) < 1e-9, "120 BPM beat is 0.5s")
    expect(abs(MetroTiming.countInDuration(bpm: 96) - (60 / 96 * 4)) < 1e-9, "count-in is 4 beats")
    let beats = MetroTiming.beatTimes(bpm: 60, beats: 4)
    expect(beats == [0, 1, 2, 3], "four clicks at 60 BPM, got \(beats)")
    expect(beats.count == 4, "count-in has 4 click times")

    if failed == 0 {
      print("OK 21 checks")
      exit(0)
    } else {
      fputs("\(failed) failed\n", stderr)
      exit(1)
    }
  }
}
