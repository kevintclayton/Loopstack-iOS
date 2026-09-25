import CoreMIDI
import Foundation

/// MIDI input from every source (USB, Bluetooth, anything plugged in later), all channels.
/// Messages arrive on CoreMIDI's own thread and go straight to `onEvent`, so a note never
/// waits for the UI.
final class MIDIInput: @unchecked Sendable {
  enum Event {
    case noteOn(note: Int, velocity: Int)
    case noteOff(note: Int)
    case control(number: Int, value: Int)
    /// 14-bit pitch bend, 0...16383, centre 8192.
    case pitchBend(Int)
  }

  /// CoreMIDI thread.
  var onEvent: ((Event) -> Void)?
  /// Main thread: the connected sources' names.
  var onSourcesChanged: (([String]) -> Void)?

  private var client = MIDIClientRef()
  private var port = MIDIPortRef()
  private var connected: Set<MIDIEndpointRef> = []
  private var started = false

  /// Main thread. Safe to call more than once.
  func start() {
    guard !started else { return }
    started = true
    let status = MIDIClientCreateWithBlock("Loopstack" as CFString, &client) { [weak self] note in
      // Devices come and go: reconnect whenever the setup changes.
      if note.pointee.messageID == .msgSetupChanged {
        DispatchQueue.main.async { self?.connectSources() }
      }
    }
    guard status == noErr else { return }
    MIDIInputPortCreateWithProtocol(client, "Loopstack In" as CFString, ._1_0, &port) { [weak self] list, _ in
      self?.receive(list)
    }
    connectSources()
  }

  /// Main thread. Connects any new sources and reports what's there.
  func connectSources() {
    guard started else { return }
    var current: Set<MIDIEndpointRef> = []
    var names: [String] = []
    for i in 0..<MIDIGetNumberOfSources() {
      let source = MIDIGetSource(i)
      guard source != 0 else { continue }
      var offline: Int32 = 0
      MIDIObjectGetIntegerProperty(source, kMIDIPropertyOffline, &offline)
      if offline != 0 { continue }
      current.insert(source)
      if !connected.contains(source) { MIDIPortConnectSource(port, source, nil) }
      var name: Unmanaged<CFString>?
      if MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &name) == noErr, let n = name?.takeRetainedValue() {
        names.append(n as String)
      }
    }
    connected = current
    onSourcesChanged?(names)
  }

  /// CoreMIDI thread. Universal MIDI Packets; with the 1.0 protocol, channel voice
  /// messages are one 32-bit word each (type 2).
  private func receive(_ list: UnsafePointer<MIDIEventList>) {
    for packet in list.unsafeSequence() {
      let count = Int(packet.pointee.wordCount)
      let words = UnsafeRawPointer(packet)
        .advanced(by: MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!)
        .assumingMemoryBound(to: UInt32.self)
      var i = 0
      while i < count {
        let w = words[i]
        let type = Int(w >> 28)
        if type == 2 {
          let status = Int((w >> 16) & 0xF0)
          let d1 = Int((w >> 8) & 0x7F)
          let d2 = Int(w & 0x7F)
          switch status {
          case 0x90 where d2 > 0: onEvent?(.noteOn(note: d1, velocity: d2))
          case 0x90, 0x80: onEvent?(.noteOff(note: d1))
          case 0xB0: onEvent?(.control(number: d1, value: d2))
          case 0xE0: onEvent?(.pitchBend((d2 << 7) | d1))
          default: break
          }
        }
        i += Self.umpWords[type]
      }
    }
  }

  /// Size in words of each Universal MIDI Packet message type.
  private static let umpWords = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4]
}

/// Turns raw MIDI into what the instrument plays: velocity, sustain pedal, pitch bend,
/// mod wheel and all-notes-off. Runs on the CoreMIDI thread only, so its state needs no
/// lock. Each note is released the same way it was started (fast path or through the
/// engine), so a mode change while keys are down can't leave a note hanging.
final class MIDIRouter: @unchecked Sendable {
  /// Whether notes go straight to the synth (plain keys: no arp, chords or sampler).
  let isDirect: () -> Bool
  let directOn: (_ note: Int, _ velocity: Float) -> Void
  let directOff: (_ note: Int) -> Void
  let engineOn: (_ note: Int, _ velocity: Float) -> Void
  let engineOff: (_ note: Int) -> Void
  let bend: (_ amount: Float) -> Void      // -1...1
  let modWheel: (_ amount: Float) -> Void  // 0...1
  let panic: () -> Void

  private var held: Set<Int> = []
  private var sustained: Set<Int> = []
  private var sustainDown = false
  private var viaDirect: Set<Int> = []
  private var sounding: Set<Int> = []

  init(isDirect: @escaping () -> Bool,
       directOn: @escaping (Int, Float) -> Void, directOff: @escaping (Int) -> Void,
       engineOn: @escaping (Int, Float) -> Void, engineOff: @escaping (Int) -> Void,
       bend: @escaping (Float) -> Void, modWheel: @escaping (Float) -> Void, panic: @escaping () -> Void) {
    self.isDirect = isDirect
    self.directOn = directOn
    self.directOff = directOff
    self.engineOn = engineOn
    self.engineOff = engineOff
    self.bend = bend
    self.modWheel = modWheel
    self.panic = panic
  }

  /// Keyboard velocity 1...127 to the instrument's 0...1, with a gentle curve so a medium
  /// touch (~100) lands near the pads' fixed 0.85.
  static func velocity(_ v: Int) -> Float {
    Float(max(0.08, pow(Double(max(1, min(127, v))) / 127, 0.7)))
  }

  func handle(_ event: MIDIInput.Event) {
    switch event {
    case let .noteOn(note, velocity):
      held.insert(note)
      sustained.remove(note)
      // Re-striking a note that's still ringing (on the pedal) restarts it cleanly.
      if sounding.contains(note) { stop(note) }
      start(note, Self.velocity(velocity))
    case let .noteOff(note):
      held.remove(note)
      if sustainDown {
        sustained.insert(note)
      } else {
        stop(note)
      }
    case let .control(number, value):
      switch number {
      case 1:  // mod wheel
        modWheel(Float(value) / 127)
      case 64:  // sustain pedal
        sustainDown = value >= 64
        if !sustainDown {
          for note in sustained where !held.contains(note) { stop(note) }
          sustained.removeAll()
        }
      case 120, 123:  // all sound off, all notes off
        for note in sounding { stop(note) }
        held.removeAll()
        sustained.removeAll()
        sustainDown = false
        panic()
      case 121:  // reset all controllers
        bend(0)
        modWheel(0)
        sustainDown = false
      default:
        break
      }
    case let .pitchBend(value):
      bend(Float(value - 8192) / 8192)
    }
  }

  private func start(_ note: Int, _ velocity: Float) {
    sounding.insert(note)
    if isDirect() {
      viaDirect.insert(note)
      directOn(note, velocity)
    } else {
      engineOn(note, velocity)
    }
  }

  private func stop(_ note: Int) {
    guard sounding.remove(note) != nil else { return }
    if viaDirect.remove(note) != nil {
      directOff(note)
    } else {
      engineOff(note)
    }
  }
}
