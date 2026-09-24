import AVFoundation
import Combine
import Foundation
import UIKit

enum TransportStatus: String {
  case idle, playing, countin, armed, recording
}

enum MicState: String {
  case idle, pending, ready, denied, error
}

final class LayerSlot {
  let index: Int
  /// Renders this loop; fanned out to the loops mixer and the loop delay/reverb buses.
  var node: AVAudioSourceNode?
  var delayBus: AVAudioNodeBus = 0
  var reverbBus: AVAudioNodeBus = 0
  var busy = false

  init(index: Int) { self.index = index }
}

struct InstrumentPatch: Codable, Equatable {
  var gain: Float = 0.85
  var pan: Float = 0
  var delay: Float = 0.92
  var reverb: Float = 0.95
  var drift: Float = 0.66
  var ring: Float = 0
  var glitch: Float = 0
  var tune: Double = 437
  var octave: Int = 0
  var wave: OscWave = .warm
  var wave2: OscWave = .square
  var oscMix: Float = 0.28
  var oscDetune: Float = 0.3
  var osc2Octave: Int = 0
  var cutoff: Float = 0.72
  var resonance: Float = 0.12
  /// Release slider 0...1; nil (older saved sounds) means the preset's default.
  var release: Float?

  /// Slider -> envelope time constant, log curve centred on 0.09 s: the fixed release
  /// this replaced sits exactly at the middle (0.5). Range ~7 ms ... 1.16 s.
  static func releaseTau(_ v: Float) -> Double {
    0.09 * pow(12.87, 2 * Double(min(1, max(0, v))) - 1)
  }

  /// What the slider shows: time for a released note to fade out (-60 dB),
  /// about 0.05 s ... 8 s; 0.62 s at the middle.
  static func releaseSeconds(_ v: Float) -> Double {
    releaseTau(v) * 6.9078
  }

  /// Pluck ignored key-up and rang out its own decay; at the maximum it still does.
  static func defaultRelease(for preset: InstrumentPreset) -> Float {
    preset == .pluck ? 1 : 0.5
  }

  static func `default`(for preset: InstrumentPreset) -> InstrumentPatch {
    var patch = InstrumentPatch(wave: preset.defaultWave)
    patch.gain = 0.86
    switch preset {
    case .keys:
      patch.wave = .warm
      patch.wave2 = .square
      patch.oscMix = 0.2
      patch.oscDetune = 0.22
      patch.osc2Octave = 0
      patch.cutoff = 0.78
      patch.resonance = 0.08
      patch.gain = 0.84
      patch.delay = 0.22
      patch.reverb = 0.32
      patch.drift = 0.18
    case .bass:
      // Saw filtered close to the note (cut 0.10 is ~135 Hz): round like a triangle
      // bass, but with a little upper content so it doesn't vanish on phone speakers
      // the way a pure sine did. A higher cutoff (0.5) read as a lead.
      patch.wave = .saw
      patch.wave2 = .sine
      patch.oscMix = 0.32
      patch.oscDetune = 0.06
      patch.osc2Octave = -1
      patch.cutoff = 0.10
      patch.resonance = 0.24
      patch.gain = 0.86
      patch.delay = 0.04
      patch.reverb = 0.06
      patch.drift = 0.1
    case .pluck:
      patch.wave = .triangle
      patch.wave2 = .pulse
      patch.oscMix = 0.16
      patch.oscDetune = 0.1
      patch.osc2Octave = 0
      patch.cutoff = 0.68
      patch.resonance = 0.1
      patch.gain = 0.86
      patch.delay = 0.28
      patch.reverb = 0.2
      patch.drift = 0.08
    case .pad:
      patch.wave = .sine
      patch.wave2 = .sine
      patch.oscMix = 0.5
      patch.oscDetune = 0.58
      patch.osc2Octave = 0
      patch.cutoff = 0.5
      patch.resonance = 0.14
      patch.gain = 0.86
      patch.delay = 0.38
      patch.reverb = 0.86
      patch.drift = 0.42
    case .noise:
      patch.wave = .noise
      patch.wave2 = .pulse
      patch.oscMix = 0.12
      patch.oscDetune = 0.2
      patch.osc2Octave = 0
      patch.cutoff = 0.52
      patch.resonance = 0.38
      patch.gain = 0.82
      patch.delay = 0.18
      patch.reverb = 0.4
      patch.drift = 0.2
      patch.ring = 0.08
      patch.glitch = 0.12
    }
    return patch
  }
}

struct Layer: Identifiable {
  var id: String
  var name: String
  var buffer: AVAudioPCMBuffer
  var reverseBuffer: AVAudioPCMBuffer
  var peaks: [Float]
  var gain: Float
  var pan: Float
  var delay: Float
  var reverb: Float
  var muted: Bool
  var reversed: Bool
  var slot: LayerSlot
}

@MainActor
final class LoopEngine: ObservableObject {
  @Published var unlocked = false
  @Published var status: TransportStatus = .idle
  @Published var bpm: Int = 96
  @Published var bars: Int = 4
  @Published var metronomeOn = true
  @Published var countInOn = true
  @Published var monitorOn = false
  @Published var drumsOn = false
  @Published var jamMode = false
  @Published var acousticKit = false
  @Published var fillArmed = false
  @Published var drumId = "floor"
  @Published var masterGain: Float = 0.85
  @Published var metroGain: Float = 0.83
  @Published var drumsGain: Float = 0.83
  @Published var instrumentGain: Float = 0.84
  @Published var instrumentPan: Float = 0
  @Published var instrumentDelay: Float = 0.22
  @Published var instrumentReverb: Float = 0.32
  @Published var instrumentDrift: Float = 0.18
  @Published var instrumentRing: Float = 0
  @Published var instrumentRelease: Float = InstrumentPatch.defaultRelease(for: .keys)
  @Published var instrumentWave: OscWave = .warm
  @Published var instrumentWave2: OscWave = .square
  @Published var oscMix: Float = 0.2
  @Published var oscDetune: Float = 0.22
  @Published var osc2Octave: Int = 0
  @Published var cutoff: Float = 0.78
  @Published var resonance: Float = 0.08
  @Published var drumDrive: Float = 0.15
  @Published var drumDirt: Float = 0.12
  @Published var drumVinyl: Float = 0
  @Published var instrumentGlitch: Float = 0
  @Published var micGain: Float = 0.85
  @Published var layers: [Layer] = []
  @Published var micState: MicState = .idle
  @Published var micError: String?
  @Published var inputMode: String = "keys"
  @Published var preset: InstrumentPreset = .keys
  @Published var audioRunning = false
  @Published var sessionRecording = false
  @Published var sessionReady = false
  @Published var sessionURL: URL?
  @Published var sessionDuration: Double = 0
  @Published var sessionElapsed: Double = 0
  @Published var position: Double = 0
  @Published var countInBeat = 0
  @Published var loopLocked = false
  @Published var instrumentTune: Double = 437
  @Published var instrumentOctave: Int = 0
  @Published var heldNotes: Set<Int> = []
  @Published var arpOn = false
  @Published var arpDivision = 4
  @Published var arpMode = 0 // 0 up, 1 down, 2 ping
  @Published var privacyOpen = false
  @Published var scaleRoot: Int = UserDefaults.standard.object(forKey: "scaleRoot") as? Int ?? 0
  @Published var scaleMode: ScaleMode = ScaleMode(rawValue: UserDefaults.standard.string(forKey: "scaleMode") ?? "") ?? .major
  @Published var savedSounds: [SavedSound] = []
  @Published var activeSoundId: String?
  @Published var sampleRecording = false
  @Published var hasSample = false
  @Published var sampleRootMidi = 60
  @Published var saveError: String?
  private var arpOrigin: TimeInterval = 0
  private var lastArpStep = -1

  /// Same layout as the web desk: bottom row white keys, row above black keys.
  static let typingKeys: [String: Int] = [
    "a": 48, "w": 49, "s": 50, "e": 51, "d": 52, "f": 53, "t": 54,
    "g": 55, "y": 56, "h": 57, "u": 58, "j": 59, "k": 60, "o": 61,
    "l": 62, "p": 63, ";": 64, "'": 65,
  ]
  static let typingLabels: [Int: String] = {
    var out: [Int: String] = [:]
    for (k, v) in typingKeys { out[v] = k.uppercased() }
    return out
  }()
  private var patches: [InstrumentPreset: InstrumentPatch] = {
    var all: [InstrumentPreset: InstrumentPatch] = [:]
    for p in InstrumentPreset.allCases { all[p] = InstrumentPatch.default(for: p) }
    return all
  }()

  let drums = DrumLibrary.all
  let barPresets = [1, 2, 4, 8, 16, 32, 64, 128]

  var drumName: String { DrumLibrary.find(drumId).name }
  var running: Bool { status != .idle }
  var recording: Bool { status == .recording }

  private let engine = AVAudioEngine()
  private var format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
  private let loopsMixer = AVAudioMixerNode()
  private let drumsMixer = AVAudioMixerNode()
  private let metroMixer = AVAudioMixerNode()
  private let instMixer = AVAudioMixerNode()
  private let instDelay = AVAudioUnitDelay()
  private let instReverb = AVAudioUnitReverb()
  private let instPost = AVAudioMixerNode()
  private let micMixer = AVAudioMixerNode()
  private let loopDelay = AVAudioUnitDelay()
  private let loopReverb = AVAudioUnitReverb()
  private let loopDelayBus = AVAudioMixerNode()
  private let loopReverbBus = AVAudioMixerNode()
  /// Master bus: main mix -> 35 Hz high-pass -> peak limiter -> -1 dB ceiling trim -> output.
  private let masterHighPass = AVAudioUnitEQ(numberOfBands: 2)
  private let masterLimiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
    componentType: kAudioUnitType_Effect,
    componentSubType: kAudioUnitSubType_PeakLimiter,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags: 0,
    componentFlagsMask: 0
  ))
  private let masterOut = AVAudioMixerNode()
  private let limiterMeter = PeakMeter()
  /// dB the master limiter is currently pulling down (peak-held, falls back gently).
  @Published var limiterReduction: Float = 0
  private let drumsPlayer = AVAudioPlayerNode()
  private let metroPlayer = AVAudioPlayerNode()
  private var voicePool: [AVAudioPlayerNode] = []
  private var busyVoices: [Int: AVAudioPlayerNode] = [:]
  private var layerSlots: [LayerSlot] = []
  private var cycleStart: TimeInterval = 0
  /// Transport position (seconds into the cycle) to resume from after pause.
  private var resumePosition: TimeInterval = 0
  private var lastCycleIndex = -1
  private var lastBarIndex = -1

  private var clock: Timer?
  private var captureTarget = 0
  private var capturing = false
  private let sessionSink = SessionSink()
  private var sessionStarted: TimeInterval = 0
  private var layerSerial = 1
  private var tapInstalled = false
  private var sessionTapInstalled = false
  private var micArmed = false
  private var graphReady = false
  private let silentPlayer = AVAudioPlayerNode()
  private let captureState = CaptureState()
  private let liveSynth = LiveSynth()
  private var synthNode: AVAudioSourceNode?
  /// One timeline for drums and loops.
  private let transportClock = TransportClock()
  private lazy var liveDrums = LiveDrums(clock: transportClock)
  private var drumNode: AVAudioSourceNode?
  private lazy var liveLayers = LiveLayers(clock: transportClock)
  private let liveMetro = LiveMetro()
  private var metroNode: AVAudioSourceNode?
  private let liveSampler = LiveSampler()
  private let sampleCapture = SampleCapture()
  private var sampleTapInstalled = false
  private var playSampler = false
  private var captureSlot: LayerSlot?
  private var captureBegan: TimeInterval = 0
  private var lastSampleMono: [Float] = []
  private var lastSampleRate: Double = 44100

  var loopDuration: Double { Double(bars * 4) * 60 / Double(bpm) }

  func unlock() {
    unlocked = true
    savedSounds = SoundLibrary.loadIndex()
    startClock()
    ensureRunning()
  }

  @discardableResult
  private func ensureRunning() -> Bool {
    if engine.isRunning {
      audioRunning = true
      return true
    }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
      try session.setPreferredIOBufferDuration(0.01)
      try session.setActive(true)
      let sr = session.sampleRate >= 8000 ? session.sampleRate : 44100
      format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
      attachGraph()
      engine.prepare()
      try engine.start()
      audioRunning = true
      return true
    } catch {
      micError = error.localizedDescription
      audioRunning = false
      return false
    }
  }

  private func attachGraph() {
    guard !graphReady else { return }
    graphReady = true
    let main = engine.mainMixerNode
    [loopsMixer, drumsMixer, metroMixer, instMixer, instDelay, instReverb, instPost, micMixer, loopDelay, loopReverb, loopDelayBus, loopReverbBus].forEach { engine.attach($0) }
    liveDrums.sampleRate = format.sampleRate
    let dnode = AudioGraph.drumsNode(format: format, drums: liveDrums)
    engine.attach(dnode)
    engine.connect(dnode, to: drumsMixer, format: format)
    drumNode = dnode
    engine.connect(drumsMixer, to: main, format: format)
    liveMetro.sampleRate = format.sampleRate
    let mnode = AudioGraph.metroNode(format: format, metro: liveMetro)
    engine.attach(mnode)
    engine.connect(mnode, to: metroMixer, format: format)
    metroNode = mnode
    engine.connect(metroMixer, to: main, format: format)
    engine.connect(loopsMixer, to: main, format: format)
    engine.connect(instMixer, to: instDelay, format: format)
    engine.connect(instDelay, to: instReverb, format: format)
    engine.connect(instReverb, to: instPost, format: format)
    engine.connect(instPost, to: main, format: format)
    engine.connect(micMixer, to: main, format: format)
    engine.connect(loopDelayBus, to: loopDelay, format: format)
    engine.connect(loopDelay, to: main, format: format)
    engine.connect(loopReverbBus, to: loopReverb, format: format)
    engine.connect(loopReverb, to: main, format: format)
    attachMasterBus(main)
    // The buses carry only per-loop sends, so the effects run fully wet.
    loopDelay.wetDryMix = 100
    loopDelay.feedback = 28
    loopDelay.delayTime = 0.3
    loopReverb.wetDryMix = 100
    loopReverb.loadFactoryPreset(.mediumHall)
    instDelay.wetDryMix = 0
    instDelay.feedback = 20
    instReverb.wetDryMix = 0
    instReverb.loadFactoryPreset(.mediumHall)

    let input = engine.inputNode
    let inFormat = input.outputFormat(forBus: 0)
    if inFormat.sampleRate > 0, inFormat.channelCount > 0 {
      engine.connect(input, to: micMixer, format: inFormat)
    }
    micMixer.outputVolume = 0
    // Keep micArmed false so monitor stays off until the user enables it.

    liveSynth.sampleRate = format.sampleRate
    liveLayers.setClock(start: 0, dur: loopDuration, sampleRate: format.sampleRate)
    let node = AudioGraph.synthNode(format: format, synth: liveSynth, sampler: liveSampler, outRate: format.sampleRate)
    engine.attach(node)
    engine.connect(node, to: instMixer, format: format)
    synthNode = node
    AudioGraph.installPostTap(on: instPost, format: format, layers: liveLayers)
    tapInstalled = true
    for i in 0..<8 {
      let slot = LayerSlot(index: i)
      let node = AudioGraph.layerNode(format: format, layers: liveLayers, slot: i)
      engine.attach(node)
      let dry = AVAudioConnectionPoint(node: loopsMixer, bus: loopsMixer.nextAvailableInputBus)
      let delay = AVAudioConnectionPoint(node: loopDelayBus, bus: loopDelayBus.nextAvailableInputBus)
      let reverb = AVAudioConnectionPoint(node: loopReverbBus, bus: loopReverbBus.nextAvailableInputBus)
      engine.connect(node, to: [dry, delay, reverb], fromBus: 0, format: format)
      slot.node = node
      slot.delayBus = delay.bus
      slot.reverbBus = reverb.bus
      setSends(slot, delay: 0, reverb: 0)
      layerSlots.append(slot)
    }

    applyGains()
    applyInstrumentSpace()
  }

  /// Instant on a new peak, then falls ~12 dB/s so short hits stay visible.
  private func updateLimiterLight() {
    let peak = limiterMeter.take()
    let reduction = peak > 1 ? 20 * log10f(peak) : 0
    var shown = max(reduction, limiterReduction - 0.6)
    if shown < 0.05 { shown = 0 }
    if abs(shown - limiterReduction) > 0.05 || (shown == 0 && limiterReduction != 0) {
      limiterReduction = shown
    }
  }

  /// Apple's lookahead peak limiter keeps the mix from clipping. Measured offline:
  /// transparent below 0 dBFS, no overs with +7 dB transients, <0.2% THD on
  /// limited bass at 3 ms attack (which is also the added latency).
  private func attachMasterBus(_ main: AVAudioMixerNode) {
    engine.attach(masterHighPass)
    engine.attach(masterLimiter)
    engine.attach(masterOut)
    engine.disconnectNodeOutput(main)
    // Sub-bass below ~35 Hz is felt more than heard, small speakers can't play it, and
    // it made the limiter clamp the whole mix. 4th-order Butterworth (two 2nd-order
    // stages, Q 0.541 and 1.307): measured -3 dB at 35 Hz, -1.1 dB at 41 Hz (E1),
    // flat from 60 Hz, -19.5 dB at 20 Hz. Placed before the limiter so it never reacts to it.
    for (band, q) in zip(masterHighPass.bands, [0.5412, 1.3066]) {
      band.filterType = .resonantHighPass
      band.frequency = 35
      band.bandwidth = Float(2 / log(2) * asinh(1 / (2 * q)))  // Q expressed in octaves
      band.bypass = false
    }
    engine.connect(main, to: masterHighPass, format: format)
    engine.connect(masterHighPass, to: masterLimiter, format: format)
    engine.connect(masterLimiter, to: masterOut, format: format)
    let hw = engine.outputNode.inputFormat(forBus: 0)
    engine.connect(masterOut, to: engine.outputNode, format: hw.sampleRate > 0 ? hw : format)
    let au = masterLimiter.audioUnit
    AudioUnitSetParameter(au, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.003, 0)
    AudioUnitSetParameter(au, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.06, 0)
    AudioUnitSetParameter(au, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0, 0)
    // The limiter holds 0 dBFS; trim 1 dB for DAC and inter-sample headroom.
    masterOut.outputVolume = 0.891
    AudioGraph.installMeterTap(on: masterHighPass, format: format, meter: limiterMeter)
  }

  private func startSilentPull() {
    // Source nodes already pull the graph. Do not play extra player nodes.
  }

  private func applyGains() {
    engine.mainMixerNode.outputVolume = masterGain
    loopsMixer.outputVolume = 1
    metroMixer.outputVolume = (metronomeOn || status == .countin) ? metroGain : 0
    drumsMixer.outputVolume = drumsOn ? drumsGain * Self.drumTrim : 0
    instMixer.outputVolume = instrumentGain
    instMixer.pan = instrumentPan
    micMixer.outputVolume = ((monitorOn || sampleRecording) && micArmed) ? micGain * 0.7 : 0
  }

  private func applyInstrumentSpace() {
    instDelay.delayTime = min(1.85, max(0.08, 60 / Double(bpm) * 0.75))
    instDelay.wetDryMix = min(40, instrumentDelay * 28)
    instReverb.wetDryMix = min(45, instrumentReverb * 30)
    loopDelay.delayTime = min(1.85, max(0.08, 60 / Double(bpm) * 0.75))
  }

  func setInstrumentPan(_ v: Float) { instrumentPan = v; rememberPatch(); applyGains() }
  func setInstrumentDelay(_ v: Float) { instrumentDelay = v; rememberPatch(); applyInstrumentSpace() }
  func setInstrumentReverb(_ v: Float) { instrumentReverb = v; rememberPatch(); applyInstrumentSpace() }
  func setInstrumentDrift(_ v: Float) { instrumentDrift = v; rememberPatch() }
  func setInstrumentRing(_ v: Float) { instrumentRing = v; rememberPatch() }
  func setInstrumentRelease(_ v: Float) {
    instrumentRelease = v
    rememberPatch()
    liveSynth.release = InstrumentPatch.releaseTau(v)
  }
  func setInstrumentGlitch(_ v: Float) { instrumentGlitch = v; rememberPatch() }
  func setInstrumentTune(_ hz: Double) { instrumentTune = min(452, max(428, hz)); rememberPatch() }
  func setInstrumentOctave(_ n: Int) { instrumentOctave = min(3, max(-3, n)); rememberPatch() }

  func setMasterGain(_ v: Float) { masterGain = v; applyGains() }
  func setMetroGain(_ v: Float) { metroGain = v; applyGains() }
  func setDrumsGain(_ v: Float) { drumsGain = v; applyGains() }
  func setInstrumentGain(_ v: Float) { instrumentGain = v; rememberPatch(); applyGains() }
  func setMicGain(_ v: Float) { micGain = v; applyGains() }
  func setMetronomeOn(_ on: Bool) {
    metronomeOn = on
    applyGains()
    rescheduleMetro()
  }
  func setDrumsOn(_ on: Bool) {
    drumsOn = on
    applyGains()
    if running { rescheduleDrums() }
  }
  func setJam(_ on: Bool) {
    jamMode = on
  }
  func setAcousticKit(_ on: Bool) {
    acousticKit = on
    if on {
      if AcousticKit.isLoaded {
        if drumsOn, running { rescheduleDrums() }
      } else {
        Task.detached(priority: .userInitiated) {
          AcousticKit.load()
          await MainActor.run {
            guard self.acousticKit else { return }
            if self.drumsOn, self.running { self.rescheduleDrums() }
          }
        }
      }
    } else if drumsOn, running {
      rescheduleDrums()
    }
  }
  func requestFill() {
    ensureRunning()
    fillArmed = true
    if running {
      let beats = position * Double(bars * 4)
      if beats.truncatingRemainder(dividingBy: 4) < 0.2 {
        beginFill()
      }
    } else if drumsOn {
      beginFill()
    }
  }
  func setDrumId(_ id: String) {
    drumId = id
    if running { rescheduleDrums() }
  }
  func nextDrum(_ dir: Int) {
    guard let i = drums.firstIndex(where: { $0.id == drumId }) else { return }
    let next = drums[(i + dir + drums.count) % drums.count]
    setDrumId(next.id)
  }
  func setDrumDrive(_ v: Float) { drumDrive = v; liveDrums.drive = v }
  func setDrumDirt(_ v: Float) { drumDirt = v; liveDrums.dirt = v }
  func setDrumVinyl(_ v: Float) { drumVinyl = v; liveDrums.vinyl = v }
  func setPreset(_ p: InstrumentPreset) {
    rememberPatch()
    preset = p
    activeSoundId = nil
    if playSampler {
      playSampler = false
      liveSampler.allOff()
      inputMode = "keys"
    }
    let patch = patches[p] ?? InstrumentPatch.default(for: p)
    instrumentRelease = patch.release ?? InstrumentPatch.defaultRelease(for: p)
    instrumentGain = patch.gain
    instrumentPan = patch.pan
    instrumentDelay = patch.delay
    instrumentReverb = patch.reverb
    instrumentDrift = patch.drift
    instrumentRing = patch.ring
    instrumentGlitch = patch.glitch
    instrumentTune = patch.tune
    instrumentOctave = patch.octave
    instrumentWave = patch.wave
    instrumentWave2 = patch.wave2
    oscMix = patch.oscMix
    oscDetune = patch.oscDetune
    osc2Octave = patch.osc2Octave
    cutoff = patch.cutoff
    resonance = patch.resonance
    applyGains()
    syncSynth()
  }

  func setInstrumentWave(_ wave: OscWave) {
    instrumentWave = wave
    rememberPatch()
    syncSynth()
  }

  func setInstrumentWave2(_ wave: OscWave) {
    instrumentWave2 = wave
    rememberPatch()
    syncSynth()
  }

  func setOscMix(_ v: Float) { oscMix = v; rememberPatch(); syncSynth() }
  func setOscDetune(_ v: Float) { oscDetune = v; rememberPatch(); syncSynth() }
  func setOsc2Octave(_ n: Int) { osc2Octave = min(1, max(-1, n)); rememberPatch(); syncSynth() }
  func setCutoff(_ v: Float) { cutoff = v; rememberPatch(); syncSynth() }
  func setResonance(_ v: Float) { resonance = v; rememberPatch(); syncSynth() }

  private func rememberPatch() {
    patches[preset] = InstrumentPatch(
      gain: instrumentGain,
      pan: instrumentPan,
      delay: instrumentDelay,
      reverb: instrumentReverb,
      drift: instrumentDrift,
      ring: instrumentRing,
      glitch: instrumentGlitch,
      tune: instrumentTune,
      octave: instrumentOctave,
      wave: instrumentWave,
      wave2: instrumentWave2,
      oscMix: oscMix,
      oscDetune: oscDetune,
      osc2Octave: osc2Octave,
      cutoff: cutoff,
      resonance: resonance,
      release: instrumentRelease
    )
  }

  private func syncSynth() {
    liveSynth.preset = preset
    liveSynth.wave = instrumentWave
    liveSynth.wave2 = instrumentWave2
    liveSynth.mix = oscMix
    liveSynth.detune = oscDetune
    liveSynth.osc2Octave = osc2Octave
    liveSynth.cutoff = cutoff
    liveSynth.resonance = resonance
    liveSynth.a4 = instrumentTune
    liveSynth.drift = instrumentDrift
    liveSynth.ring = instrumentRing
    liveSynth.release = InstrumentPatch.releaseTau(instrumentRelease)
    liveSynth.glitch = instrumentGlitch
  }
  func setInputMode(_ mode: String) {
    inputMode = mode
    if mode == "sampler" {
      playSampler = true
      liveSynth.allOff()
      if micState != .ready { enableMic() }
    } else {
      playSampler = false
      liveSampler.allOff()
    }
  }

  func setScaleRoot(_ pc: Int) {
    scaleRoot = ((pc % 12) + 12) % 12
    UserDefaults.standard.set(scaleRoot, forKey: "scaleRoot")
    sampleRootMidi = 48 + scaleRoot
    liveSampler.setRoot(sampleRootMidi)
  }

  func setScaleMode(_ mode: ScaleMode) {
    scaleMode = mode
    UserDefaults.standard.set(mode.rawValue, forKey: "scaleMode")
  }

  var padNotes: [PadNote] {
    MusicKey.padNotes(root: scaleRoot, mode: scaleMode, octave: instrumentOctave)
  }

  func saveCurrentSound(_ name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    rememberPatch()
    let id = activeSoundId ?? UUID().uuidString
    let sampler = playSampler && !lastSampleMono.isEmpty
    let sound = SavedSound(
      id: id,
      name: trimmed,
      preset: sampler ? "sampler" : preset.rawValue,
      isSampler: sampler,
      sampleFile: nil,
      sampleRoot: sampler ? sampleRootMidi : nil,
      patch: patches[preset] ?? InstrumentPatch.default(for: preset)
    )
    let wav = sampler ? SoundLibrary.bufferFromMono(lastSampleMono, rate: lastSampleRate) : nil
    let stored = SoundLibrary.save(sound, sample: wav)
    if let i = savedSounds.firstIndex(where: { $0.id == stored.id }) {
      savedSounds[i] = stored
    } else {
      savedSounds.insert(stored, at: 0)
    }
    activeSoundId = stored.id
  }

  func loadSound(_ id: String) {
    guard let sound = savedSounds.first(where: { $0.id == id }) ?? SoundLibrary.loadIndex().first(where: { $0.id == id }) else { return }
    activeSoundId = sound.id
    let patch = sound.patch
    if let p = InstrumentPreset(rawValue: sound.preset), !sound.isSampler {
      preset = p
    }
    instrumentRelease = patch.release ?? InstrumentPatch.defaultRelease(for: preset)
    instrumentGain = patch.gain
    instrumentPan = patch.pan
    instrumentDelay = patch.delay
    instrumentReverb = patch.reverb
    instrumentDrift = patch.drift
    instrumentRing = patch.ring
    instrumentGlitch = patch.glitch
    instrumentTune = patch.tune
    instrumentOctave = patch.octave
    instrumentWave = patch.wave
    instrumentWave2 = patch.wave2
    oscMix = patch.oscMix
    oscDetune = patch.oscDetune
    osc2Octave = patch.osc2Octave
    cutoff = patch.cutoff
    resonance = patch.resonance
    rememberPatch()
    applyGains()
    syncSynth()
    if sound.isSampler {
      setInputMode("sampler")
      if let loaded = SoundLibrary.loadSample(sound) {
        lastSampleMono = loaded.samples
        lastSampleRate = loaded.rate
        if let root = sound.sampleRoot { sampleRootMidi = root }
        liveSampler.setSample(loaded.samples, sampleRate: loaded.rate, root: sampleRootMidi)
        hasSample = liveSampler.hasSample
      }
    } else {
      setInputMode("keys")
    }
  }

  func deleteSound(_ id: String) {
    SoundLibrary.delete(id)
    savedSounds.removeAll { $0.id == id }
    if activeSoundId == id { activeSoundId = nil }
  }

  func toggleSampleRecord() {
    if sampleRecording {
      finishSampleCapture()
    } else {
      beginSampleCapture()
    }
  }

  private func beginSampleCapture() {
    ensureRunning()
    if micState != .ready {
      enableMic()
    }
    let input = engine.inputNode
    let inFormat = input.outputFormat(forBus: 0)
    guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
      saveError = "No input device. Plug in a mic or allow the iPhone microphone."
      return
    }
    if !micArmed {
      engine.connect(input, to: micMixer, format: inFormat)
      micArmed = true
    }
    let maxFrames = Int(inFormat.sampleRate * 6)
    sampleCapture.start(maxFrames: maxFrames)
    if !sampleTapInstalled {
      let sink = sampleCapture
      input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { buffer, _ in
        sink.append(buffer)
      }
      sampleTapInstalled = true
    }
    sampleRecording = true
    saveError = nil
    applyGains()
  }

  private func finishSampleCapture() {
    sampleRecording = false
    if sampleTapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      sampleTapInstalled = false
    }
    let raw = sampleCapture.take()
    guard raw.count > Int(format.sampleRate * 0.04) else {
      saveError = "Sample was too short. Hold a sound and capture again."
      return
    }
    let inputRate = engine.inputNode.outputFormat(forBus: 0).sampleRate
    let srcRate = inputRate > 0 ? inputRate : format.sampleRate
    let mono = PitchMath.resample(raw, from: srcRate, to: format.sampleRate)
    lastSampleMono = mono
    lastSampleRate = format.sampleRate
    sampleRootMidi = 48 + scaleRoot
    liveSampler.setSample(mono, sampleRate: format.sampleRate, root: sampleRootMidi)
    hasSample = liveSampler.hasSample
    playSampler = true
    activeSoundId = nil
    saveError = nil
  }
  func setCountInOn(_ on: Bool) { countInOn = on }
  func setMonitorOn(_ on: Bool) { monitorOn = on; applyGains() }
  func setBars(_ n: Int) {
    guard !loopLocked else { return }
    bars = n
  }
  func setBpm(_ n: Int) {
    guard !loopLocked else { return }
    bpm = min(220, max(40, n))
    applyGains()
  }
  func tapTempo(_ taps: [TimeInterval]) {
    guard !loopLocked, taps.count >= 2 else { return }
    var intervals: [TimeInterval] = []
    for i in 1..<taps.count { intervals.append(taps[i] - taps[i - 1]) }
    let avg = intervals.reduce(0, +) / Double(intervals.count)
    guard avg > 0 else { return }
    setBpm(Int((60 / avg).rounded()))
  }

  /// Play resumes from where pause left off (the top after stop), with drums,
  /// metronome and every loop placed on the same timeline.
  func play() {
    ensureRunning()
    if status == .idle {
      // Status first: rescheduleDrums (via beginCycle) only enables drums while running.
      status = .playing
      beginCycle(at: CACurrentMediaTime() + Self.clickLead - resumePosition)
      resumePosition = 0
      liveLayers.restartAll()
    } else {
      pause()
    }
  }

  private func pause() {
    let pos = max(0, CACurrentMediaTime() - cycleStart).truncatingRemainder(dividingBy: max(loopDuration, 0.05))
    stop()
    resumePosition = pos
  }

  func stop() {
    // Discard an unfinished take. Left alone, the engine kept filling it and later
    // started it as a loop with no row in the UI.
    if let slot = captureSlot {
      liveLayers.clear(index: slot.index)
      slot.busy = false
      captureSlot = nil
    }
    capturing = false
    status = .idle
    position = 0
    resumePosition = 0
    liveDrums.enabled = false
    liveMetro.stop()
    liveLayers.setTransportPlaying(false)
    applyGains()
  }

  func record() {
    ensureRunning()
    if status == .recording {
      finishCapture(force: true)
      return
    }
    if status == .idle {
      if countInOn {
        status = .countin
        countInBeat = 0
        cycleStart = CACurrentMediaTime() + Self.clickLead
        applyGains()
        rescheduleMetro()
        return
      }
      status = .recording
      beginCycle(at: CACurrentMediaTime() + Self.clickLead)
      liveLayers.restartAll()
      startCapture()
      applyGains()
      return
    }
    if status == .playing {
      status = .armed
      applyGains()
      rescheduleMetro()
      let pos = (CACurrentMediaTime() - cycleStart).truncatingRemainder(dividingBy: max(loopDuration, 0.05))
      let frac = pos / max(loopDuration, 0.05)
      if frac < 0.08 || frac > 0.96 {
        startCapture()
        status = .recording
        applyGains()
        rescheduleMetro()
      }
      return
    }
  }

  func clear() {
    stop()
    liveLayers.clearAll()
    captureSlot = nil
    capturing = false
    for layer in layers {
      setSends(layer.slot, delay: 0, reverb: 0)
      layer.slot.busy = false
    }
    layers = []
    loopLocked = false
    layerSerial = 1
  }

  func pressNote(_ midi: Int, velocity: Float = 0.85) {
    guard !heldNotes.contains(midi) else { return }
    heldNotes.insert(midi)
    if arpOn {
      if heldNotes.count == 1 {
        arpOrigin = CACurrentMediaTime()
        lastArpStep = -1
      }
      tickArp(force: true)
    } else {
      noteOn(midi, velocity: velocity, steal: true)
    }
  }

  func releaseNote(_ midi: Int) {
    guard heldNotes.contains(midi) else { return }
    heldNotes.remove(midi)
    noteOff(midi)
    if heldNotes.isEmpty { lastArpStep = -1 }
  }

  func setArpOn(_ on: Bool) {
    arpOn = on
    lastArpStep = -1
    arpOrigin = CACurrentMediaTime()
    if on, !heldNotes.isEmpty { tickArp(force: true) }
  }

  func setArpDivision(_ n: Int) {
    arpDivision = n
    lastArpStep = -1
  }

  func setArpMode(_ mode: Int) { arpMode = mode }

  func typingDown(_ raw: String) {
    guard inputMode != "mic" else { return }
    if scaleMode != .chromatic, let midi = MusicKey.midiForTypeKey(raw, pads: padNotes) {
      pressNote(midi)
      return
    }
    let key = raw.lowercased()
    guard let base = Self.typingKeys[key] else { return }
    pressNote(base + instrumentOctave * 12)
  }

  func typingUp(_ raw: String) {
    if scaleMode != .chromatic, let midi = MusicKey.midiForTypeKey(raw, pads: padNotes) {
      releaseNote(midi)
      return
    }
    let key = raw.lowercased()
    guard let base = Self.typingKeys[key] else { return }
    releaseNote(base + instrumentOctave * 12)
  }

  func noteOn(_ midi: Int, velocity: Float = 0.85, steal: Bool = true) {
    ensureRunning()
    guard engine.isRunning else { return }
    if playSampler {
      liveSampler.noteOn(midi: midi, velocity: velocity)
      return
    }
    syncSynth()
    liveSynth.noteOn(midi: midi, velocity: velocity, steal: steal)
  }

  func noteOff(_ midi: Int) {
    liveSampler.noteOff(midi: midi)
    liveSynth.noteOff(midi: midi)
  }

  func enableMic() {
    micState = .pending
    Task {
      let session = AVAudioSession.sharedInstance()
      do {
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let granted: Bool
        if #available(iOS 17.0, *) {
          granted = await AVAudioApplication.requestRecordPermission()
        } else {
          granted = await withCheckedContinuation { cont in
            session.requestRecordPermission { cont.resume(returning: $0) }
          }
        }
        if !granted {
          micState = .denied
          return
        }
        if !micArmed {
          let input = engine.inputNode
          let inFormat = input.outputFormat(forBus: 0)
          if inFormat.sampleRate > 0, inFormat.channelCount > 0 {
            engine.connect(input, to: micMixer, format: inFormat)
          }
          micArmed = true
        }
        micState = .ready
        applyGains()
      } catch {
        micState = .error
        micError = error.localizedDescription
      }
    }
  }

  func setLayerGain(_ id: String, _ gain: Float) {
    if let i = layers.firstIndex(where: { $0.id == id }) {
      layers[i].gain = gain
      applyLayerMix(layers[i])
    }
  }

  func setLayerPan(_ id: String, _ pan: Float) {
    if let i = layers.firstIndex(where: { $0.id == id }) {
      layers[i].pan = pan
      applyLayerMix(layers[i])
    }
  }

  func setLayerDelay(_ id: String, _ delay: Float) {
    if let i = layers.firstIndex(where: { $0.id == id }) {
      layers[i].delay = delay
      applyLayerMix(layers[i])
    }
  }

  func setLayerReverb(_ id: String, _ reverb: Float) {
    if let i = layers.firstIndex(where: { $0.id == id }) {
      layers[i].reverb = reverb
      applyLayerMix(layers[i])
    }
  }

  func toggleMute(_ id: String) {
    if let i = layers.firstIndex(where: { $0.id == id }) {
      layers[i].muted.toggle()
      applyLayerMix(layers[i])
    }
  }

  func toggleReverse(_ id: String) {
    guard let i = layers.firstIndex(where: { $0.id == id }) else { return }
    layers[i].reversed.toggle()
    liveLayers.setReversed(index: layers[i].slot.index, layers[i].reversed)
  }

  func deleteLayer(_ id: String) {
    guard let i = layers.firstIndex(where: { $0.id == id }) else { return }
    let idx = layers[i].slot.index
    liveLayers.clear(index: idx)
    setSends(layers[i].slot, delay: 0, reverb: 0)
    layers[i].slot.busy = false
    layers.remove(at: i)
    if layers.isEmpty {
      loopLocked = false
      liveLayers.clearAll()
    }
  }

  private func applyLayerMix(_ layer: Layer) {
    liveLayers.setMix(index: layer.slot.index, gain: layer.gain, pan: layer.pan, muted: layer.muted)
    setSends(layer.slot, delay: layer.delay, reverb: layer.reverb)
  }

  /// Post-fader sends: the node output already has the loop's gain, pan and mute.
  private func setSends(_ slot: LayerSlot, delay: Float, reverb: Float) {
    guard let node = slot.node else { return }
    node.destination(forMixer: loopDelayBus, bus: slot.delayBus)?.volume = min(1, max(0, delay))
    node.destination(forMixer: loopReverbBus, bus: slot.reverbBus)?.volume = min(1, max(0, reverb))
  }

  func startSessionRecord() {
    guard !sessionRecording else { return }
    sessionSink.start()
    sessionRecording = true
    sessionReady = false
    sessionURL = nil
    sessionStarted = CACurrentMediaTime()
    sessionElapsed = 0
    // Tapping a node that isn't attached yet throws; the limiter joins in attachGraph.
    if !sessionTapInstalled, masterLimiter.engine != nil {
      attachSessionTap(masterLimiter, format: format, sink: sessionSink)
      sessionTapInstalled = true
    }
  }

  func stopSessionRecord() {
    guard sessionRecording else { return }
    sessionRecording = false
    if sessionTapInstalled {
      masterLimiter.removeTap(onBus: 0)
      sessionTapInstalled = false
    }
    let pair = sessionSink.stop()
    let n = min(pair.l.count, pair.r.count)
    guard n > 0 else { return }
    let buf = AudioDSP.makeBuffer(frames: n, sampleRate: format.sampleRate)
    let L = buf.floatChannelData![0]
    let R = buf.floatChannelData![1]
    for i in 0..<n {
      L[i] = pair.l[i]
      R[i] = pair.r[i]
    }
    let data = AudioDSP.encodeWav(buf)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("loopstack-session.wav")
    try? data.write(to: url)
    sessionURL = url
    sessionDuration = Double(n) / format.sampleRate
    sessionReady = true
  }

  func clearSession() {
    sessionReady = false
    sessionURL = nil
    sessionDuration = 0
  }

  func exportStems() -> URL? {
    guard !layers.isEmpty || drumsOn else { return nil }
    var files: [(String, Data)] = []
    if drumsOn {
      let pattern = DrumLibrary.find(drumId)
      let buf = AudioDSP.renderPattern(pattern, bpm: Double(bpm), loopBars: bars, format: format, acoustic: acousticKit)
      AudioDSP.colorDrums(buf, drive: drumDrive, dirt: drumDirt, vinyl: drumVinyl)
      files.append(("Drums - \(pattern.name).wav", AudioDSP.encodeWav(buf)))
    }
    for layer in layers {
      let src = layer.reversed ? layer.reverseBuffer : layer.buffer
      files.append(("\(layer.name).wav", AudioDSP.encodeWav(src)))
    }
    let readme = """
    Loopstack export

    Tempo: \(bpm) BPM
    Loop length: \(bars) bars (\(String(format: "%.2f", loopDuration))s)

    Every WAV is one loop cycle starting on the downbeat.
    """
    files.append(("README.txt", Data(readme.utf8)))
    let zip = AudioDSP.zipStore(files: files.map { (name: $0.0, data: $0.1) })
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("loopstack-\(bpm)bpm.zip")
    try? zip.write(to: url)
    return url
  }

  /// Drum patterns are mastered near full scale and sat ~4 dB over the keys; trimming
  /// them (rather than pushing the instruments up) keeps headroom before the limiter.
  private static let drumTrim: Float = 0.63  // -4 dB

  /// Put beat 0 slightly in the future so the audio thread renders the first click
  /// from its start; an origin of "now" is already past by the first render.
  private static let clickLead: TimeInterval = 0.05

  private func beginCycle(at start: TimeInterval? = nil) {
    cycleStart = start ?? CACurrentMediaTime()
    lastCycleIndex = 0
    transportClock.set(cycleStart: cycleStart, sampleRate: format.sampleRate)
    liveDrums.loopDur = loopDuration
    liveLayers.setClock(start: cycleStart, dur: loopDuration, sampleRate: format.sampleRate)
    rescheduleDrums()
    rescheduleMetro()
  }

  private func startClock() {
    clock?.invalidate()
    let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    clock = timer
  }

  private func tickArp(force: Bool) {
    guard arpOn, inputMode == "keys", !heldNotes.isEmpty else { return }
    let notes = arpSequence()
    guard !notes.isEmpty else { return }
    let div = max(1, arpDivision)
    let step: Int
    if status == .countin {
      let beats = (CACurrentMediaTime() - cycleStart) / (60 / Double(bpm))
      step = max(0, Int(floor(beats * Double(div) + 1e-9)))
    } else if running {
      let beats = position * Double(bars * 4)
      step = max(0, Int(floor(beats * Double(div) + 1e-9)))
    } else {
      let stepDur = (60 / Double(bpm)) / Double(div)
      step = max(0, Int(floor((CACurrentMediaTime() - arpOrigin) / max(stepDur, 0.02))))
    }
    if !force, step == lastArpStep { return }
    lastArpStep = step
    let pulse = notes.count == 1
    noteOn(notes[step % notes.count], velocity: pulse ? 0.95 : 0.85, steal: pulse)
  }

  private func arpSequence() -> [Int] {
    let sorted = heldNotes.sorted()
    if sorted.count < 2 { return sorted }
    switch arpMode {
    case 1: return sorted.reversed()
    case 2:
      return sorted + Array(sorted.dropFirst().dropLast().reversed())
    default: return sorted
    }
  }

  private func tick() {
    let runningNow = engine.isRunning
    if audioRunning != runningNow { audioRunning = runningNow }
    updateLimiterLight()
    liveDrums.collect()
    liveLayers.collect()
    liveSampler.collect()
    if sessionRecording {
      sessionElapsed = CACurrentMediaTime() - sessionStarted
    }
    guard running || status == .countin else {
      if position != 0 { position = 0 }
      tickArp(force: false)
      return
    }
    let now = CACurrentMediaTime()
    let dur = loopDuration
    if status == .countin {
      let elapsed = now - cycleStart
      countInBeat = min(3, Int(elapsed / MetroTiming.countInDuration(bpm: Double(bpm), beats: 1)))
      if elapsed >= MetroTiming.countInDuration(bpm: Double(bpm)) {
        status = .recording
        // Start on the count-in grid, not whenever this 50ms tick noticed.
        beginCycle(at: cycleStart + MetroTiming.countInDuration(bpm: Double(bpm)))
        liveLayers.restartAll()
        startCapture()
        applyGains()
      }
      tickArp(force: false)
      return
    }
    let elapsed = now - cycleStart
    let pos = elapsed.truncatingRemainder(dividingBy: dur)
    position = pos / dur
    var closedTake = false
    if capturing, liveLayers.consumeComplete() {
      finishCapture(force: true)
      closedTake = true
    }
    if sampleRecording {
      let cap = Int(max(format.sampleRate, 8000) * 6)
      if sampleCapture.count >= cap { finishSampleCapture() }
    }
    let cycleIndex = Int(floor(elapsed / dur))
    if cycleIndex != lastCycleIndex {
      lastCycleIndex = cycleIndex
      if cycleIndex > 0, !closedTake { onLoopBoundary() }
    }
    let barIndex = Int(floor(position * Double(bars)))
    if barIndex != lastBarIndex {
      lastBarIndex = barIndex
      if fillArmed, !closedTake { beginFill() }
    }
    // Queue an armed fill just before the next bar line so it plays from its first hit
    // (the tick only notices a bar after crossing it, up to 50ms late).
    let barDur = dur / Double(max(1, bars))
    let toNextBar = barDur - pos.truncatingRemainder(dividingBy: barDur)
    if fillArmed, !closedTake, toNextBar < 0.12 {
      beginFill(at: now + toNextBar)
    }
    tickArp(force: false)
    if status == .armed && (pos < 0.08 || pos > 0.96) && elapsed > 0.1 {
      startCapture()
      status = .recording
      applyGains()
      rescheduleMetro()
    }
  }

  private func startCapture() {
    if captureSlot != nil, !capturing { captureSlot = nil }
    guard captureSlot == nil else { return }
    guard let slot = layerSlots.first(where: { !$0.busy }) else { return }
    slot.busy = true
    captureSlot = slot
    let n = max(1, Int((loopDuration * format.sampleRate).rounded()))
    liveLayers.setClock(start: cycleStart, dur: loopDuration, sampleRate: format.sampleRate)
    liveLayers.beginRecord(index: slot.index, frames: n, gain: 0.9)
    capturing = true
    captureBegan = CACurrentMediaTime()
    loopLocked = true
  }

  private func finishCapture(force: Bool) {
    guard capturing else { return }
    capturing = false
    liveLayers.endRecord(activate: true)
    liveMetro.stop()
    status = .playing
    let slot = captureSlot
    captureSlot = nil
    guard let slot else { return }
    let name = "Loop \(layerSerial)"
    layerSerial += 1
    let idx = slot.index
    let live = liveLayers
    let sr = format.sampleRate
    DispatchQueue.main.async {
      self.commitLayer(slot: slot, name: name, index: idx, live: live, sampleRate: sr)
    }
  }

  private func commitLayer(slot: LayerSlot, name: String, index: Int, live: LiveLayers, sampleRate: Double) {
    let placeholder = AudioDSP.makeBuffer(frames: 64, format: format)
    let layer = Layer(
      id: UUID().uuidString,
      name: name,
      buffer: placeholder,
      reverseBuffer: placeholder,
      peaks: Array(repeating: 0, count: 180),
      gain: 0.9,
      pan: 0,
      delay: 0,
      reverb: 0,
      muted: false,
      reversed: false,
      slot: slot
    )
    applyLayerMix(layer)
    layers.append(layer)
    let id = layer.id
    DispatchQueue.global(qos: .utility).async {
      guard let snap = live.snapshot(index: index), snap.l.count > 16 else { return }
      let buf = AudioDSP.makeBuffer(frames: snap.l.count, sampleRate: sampleRate)
      guard let dstL = buf.floatChannelData?[0] else { return }
      let dstR = buf.format.channelCount > 1 ? buf.floatChannelData![1] : dstL
      let n = snap.l.count
      for i in 0..<n {
        dstL[i] = snap.l[i]
        dstR[i] = i < snap.r.count ? snap.r[i] : snap.l[i]
      }
      let reversed = AudioDSP.reverse(buf)
      let peaks = AudioDSP.peaks(from: buf)
      DispatchQueue.main.async {
        guard let i = self.layers.firstIndex(where: { $0.id == id }) else { return }
        self.layers[i].buffer = buf
        self.layers[i].reverseBuffer = reversed
        self.layers[i].peaks = peaks
        live.setReverse(index: index, buffer: reversed)
      }
    }
  }

  private func onLoopBoundary() {
    if drumsOn, jamMode {
      pickRandomDrum()
      rescheduleDrums()
    }
  }

  private func pickRandomDrum() {
    let others = drums.filter { $0.id != drumId }
    guard let next = others.randomElement() else { return }
    drumId = next.id
  }

  private func beginFill(at barLine: TimeInterval? = nil) {
    fillArmed = false
    guard drumsOn, let fill = DrumLibrary.fills.randomElement() else { return }
    let buf = AudioDSP.renderPattern(
      fill,
      bpm: Double(bpm),
      loopBars: fill.bars,
      format: format,
      acoustic: acousticKit
    )
    let dur = Double(fill.bars * 4) * 60 / Double(bpm)
    // Start on a bar line: the upcoming one when queued early, else the one just crossed.
    let barDur = loopDuration / Double(max(1, bars))
    let elapsed = max(0, CACurrentMediaTime() - cycleStart)
    liveDrums.startFill(buf, duration: dur, at: barLine ?? cycleStart + floor(elapsed / barDur) * barDur)
  }

  private func rescheduleDrums() {
    liveDrums.drive = drumDrive
    liveDrums.dirt = drumDirt
    liveDrums.vinyl = drumVinyl
    liveDrums.loopDur = loopDuration
    liveDrums.sampleRate = format.sampleRate
    guard drumsOn, running else {
      liveDrums.enabled = false
      return
    }
    let buf = AudioDSP.renderPattern(
      DrumLibrary.find(drumId),
      bpm: Double(bpm),
      loopBars: bars,
      format: format,
      acoustic: acousticKit
    )
    liveDrums.setDry(buf)
    liveDrums.enabled = true
  }

  private func rescheduleMetro() {
    liveMetro.sampleRate = format.sampleRate
    if status == .countin {
      // Count-in clicks even with the metronome off; then it stops after 4 beats.
      // With the metronome on it keeps looping so recording continues the same click stream.
      liveMetro.start(bpm: Double(bpm), beats: 4, looping: metronomeOn, origin: cycleStart)
      return
    }
    guard metronomeOn else {
      liveMetro.stop()
      return
    }
    if status == .armed || status == .recording || capturing {
      liveMetro.start(bpm: Double(bpm), beats: bars * 4, looping: true, origin: cycleStart)
      return
    }
    liveMetro.stop()
  }

  private func schedule(_ player: AVAudioPlayerNode, _ buffer: AVAudioPCMBuffer, loops: Bool) {
    guard player.engine != nil, engine.isRunning, buffer.frameLength > 0, format.sampleRate >= 8000 else { return }
    player.scheduleBuffer(buffer, at: nil, options: loops ? .loops : [])
    player.play()
  }

  private func installRecordTap() {
    guard !tapInstalled else { return }
    tapInstalled = true
    attachCaptureTap(instMixer, format: format, sink: captureState)
  }

  private func installSessionTap() {
    guard !sessionTapInstalled, masterLimiter.engine != nil else { return }
    sessionTapInstalled = true
    attachSessionTap(masterLimiter, format: format, sink: sessionSink)
  }
}

/// Taps must not hop to MainActor. The audio thread would wait on the UI and freeze the engine.
private func attachCaptureTap(_ node: AVAudioNode, format: AVAudioFormat, sink: CaptureState) {
  node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
    guard let ch = buffer.floatChannelData?[0] else { return }
    sink.append(ch, count: Int(buffer.frameLength))
  }
}

private func attachSessionTap(_ node: AVAudioNode, format: AVAudioFormat, sink: SessionSink) {
  node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
    sink.append(buffer)
  }
}

final class CaptureState: @unchecked Sendable {
  private let lock = NSLock()
  private var active = false
  private var samples: [Float] = []
  private var target = 0

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return samples.count
  }

  func reset(target: Int) {
    lock.lock()
    samples.removeAll(keepingCapacity: true)
    self.target = max(target, 1)
    if samples.capacity < self.target {
      samples.reserveCapacity(self.target)
    }
    active = true
    lock.unlock()
  }

  func append(list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
    lock.lock()
    defer { lock.unlock() }
    guard active else { return }
    let buffers = UnsafeMutableAudioBufferListPointer(list)
    guard frames > 0, let data = buffers.first?.mData else { return }
    let ptr = data.assumingMemoryBound(to: Float.self)
    let room = max(0, target - samples.count)
    let n = min(frames, room)
    if n > 0 {
      samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: n))
    }
    if samples.count >= target { active = false }
  }

  func append(_ ptr: UnsafePointer<Float>, count: Int) {
    lock.lock()
    defer { lock.unlock() }
    guard active else { return }
    let room = max(0, target - samples.count)
    let n = min(count, room)
    if n > 0 {
      samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: n))
    }
  }

  func append(_ extra: [Float]) {
    lock.lock()
    samples.append(contentsOf: extra)
    lock.unlock()
  }

  func take() -> [Float] {
    lock.lock()
    active = false
    let out = samples
    samples = []
    lock.unlock()
    return out
  }
}

final class SessionSink: @unchecked Sendable {
  private let lock = NSLock()
  private var active = false
  private var l: [Float] = []
  private var r: [Float] = []

  func start() {
    lock.lock()
    l.removeAll(keepingCapacity: true)
    r.removeAll(keepingCapacity: true)
    active = true
    lock.unlock()
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    defer { lock.unlock() }
    guard active, let data = buffer.floatChannelData else { return }
    let n = Int(buffer.frameLength)
    l.append(contentsOf: UnsafeBufferPointer(start: data[0], count: n))
    if buffer.format.channelCount > 1 {
      r.append(contentsOf: UnsafeBufferPointer(start: data[1], count: n))
    } else {
      r.append(contentsOf: UnsafeBufferPointer(start: data[0], count: n))
    }
  }

  func stop() -> (l: [Float], r: [Float]) {
    lock.lock()
    active = false
    let out = (l, r)
    l = []
    r = []
    lock.unlock()
    return out
  }
}

/// Real-time oscillator voices so pads don’t wait on a 4-second buffer render.
final class LiveSynth: @unchecked Sendable {
  struct Voice {
    var midi: Int
    var vel: Float
    var phase: Double = 0
    var phase2: Double = 0
    var env: Double = 0
    var releasing = false
  }

  struct Params {
    var sampleRate: Double = 44100
    var preset: InstrumentPreset = .keys
    var wave: OscWave = .warm
    var wave2: OscWave = .square
    var mix: Float = 0.28
    var detune: Float = 0.3
    var osc2Octave: Int = 0
    var cutoff: Float = 0.72
    var resonance: Float = 0.12
    var a4: Double = 437
    var drift: Float = 0.66
    var ring: Float = 0
    var glitch: Float = 0
    var release: Double = 0.09
  }

  /// Note changes are queued for the render thread instead of editing its voices
  /// under a lock it would have to wait on.
  private enum Event {
    case on(midi: Int, vel: Float, steal: Bool, env: Double)
    case off(midi: Int)
    case allOff
  }

  private let lock = NSLock()
  private var shared = Params()
  private var paramsGen: UInt64 = 0
  private var pending: [Event] = []

  // Render thread only.
  private var rp = Params()
  private var renderParamsGen: UInt64 = 0
  private var inbox: [Event] = []
  private var voices: [Voice] = []
  private var cutHz: Double = 8000
  private var lpZ: Double = 0
  private var lpZR: Double = 0
  private var dcBlockL: Double = 0
  private var dcBlockR: Double = 0
  private var rng = RTRandom()

  init() {
    pending.reserveCapacity(256)
    inbox.reserveCapacity(256)
    voices.reserveCapacity(16)
  }

  var sampleRate: Double {
    get { lock.lock(); defer { lock.unlock() }; return shared.sampleRate }
    set { lock.lock(); shared.sampleRate = newValue; paramsGen &+= 1; lock.unlock() }
  }
  var preset: InstrumentPreset {
    get { lock.lock(); defer { lock.unlock() }; return shared.preset }
    set { lock.lock(); shared.preset = newValue; paramsGen &+= 1; lock.unlock() }
  }
  var wave: OscWave {
    get { lock.lock(); defer { lock.unlock() }; return shared.wave }
    set { lock.lock(); shared.wave = newValue; paramsGen &+= 1; lock.unlock() }
  }
  var wave2: OscWave {
    get { lock.lock(); defer { lock.unlock() }; return shared.wave2 }
    set { lock.lock(); shared.wave2 = newValue; paramsGen &+= 1; lock.unlock() }
  }
  var mix: Float {
    get { lock.lock(); defer { lock.unlock() }; return shared.mix }
    set { lock.lock(); shared.mix = newValue; paramsGen &+= 1; lock.unlock() }
  }
  var detune: Float {
    get { lock.lock(); defer { lock.unlock() }; return shared.detune }
    set { lock.lock(); shared.detune = newValue; paramsGen &+= 1; lock.unlock() }
  }
  var osc2Octave: Int {
    get { lock.lock(); defer { lock.unlock() }; return shared.osc2Octave }
    set { lock.lock(); shared.osc2Octave = newValue; paramsGen &+= 1; lock.unlock() }
  }
  var cutoff: Float {
    get { lock.lock(); defer { lock.unlock() }; return shared.cutoff }
    set { lock.lock(); shared.cutoff = newValue; paramsGen &+= 1; lock.unlock() }
  }
  var resonance: Float {
    get { lock.lock(); defer { lock.unlock() }; return shared.resonance }
    set { lock.lock(); shared.resonance = newValue; paramsGen &+= 1; lock.unlock() }
  }
  var a4: Double {
    get { lock.lock(); defer { lock.unlock() }; return shared.a4 }
    set { lock.lock(); shared.a4 = newValue; paramsGen &+= 1; lock.unlock() }
  }
  var drift: Float {
    get { lock.lock(); defer { lock.unlock() }; return shared.drift }
    set { lock.lock(); shared.drift = newValue; paramsGen &+= 1; lock.unlock() }
  }
  var ring: Float {
    get { lock.lock(); defer { lock.unlock() }; return shared.ring }
    set { lock.lock(); shared.ring = newValue; paramsGen &+= 1; lock.unlock() }
  }
  var glitch: Float {
    get { lock.lock(); defer { lock.unlock() }; return shared.glitch }
    set { lock.lock(); shared.glitch = newValue; paramsGen &+= 1; lock.unlock() }
  }
  /// Release envelope time constant in seconds (fade to -60 dB takes ~6.9x this).
  var release: Double {
    get { lock.lock(); defer { lock.unlock() }; return shared.release }
    set { lock.lock(); shared.release = newValue; paramsGen &+= 1; lock.unlock() }
  }

  func noteOn(midi: Int, velocity: Float, steal: Bool = true) {
    lock.lock()
    // Starting envelope uses the preset at press time, as before.
    let startEnv: Double = (shared.preset == .pluck) ? 1 : 0.001
    pending.append(.on(midi: midi, vel: velocity, steal: steal, env: startEnv))
    lock.unlock()
  }

  func noteOff(midi: Int) {
    lock.lock()
    pending.append(.off(midi: midi))
    lock.unlock()
  }

  func allOff() {
    lock.lock()
    pending.append(.allOff)
    lock.unlock()
  }

  /// Render thread. Voices has reserved capacity, so none of this allocates.
  private func apply(_ e: Event) {
    switch e {
    case let .on(midi, vel, steal, env):
      if steal {
        voices.removeAll { $0.midi == midi }
      }
      if voices.count >= 8 { voices.removeFirst(voices.count - 7) }
      voices.append(Voice(midi: midi, vel: vel, env: env))
    case let .off(midi):
      for i in voices.indices where voices[i].midi == midi {
        voices[i].releasing = true
      }
    case .allOff:
      for i in voices.indices { voices[i].releasing = true }
    }
  }

  func render(frames: Int, list: UnsafeMutablePointer<AudioBufferList>) {
    let buffers = UnsafeMutableAudioBufferListPointer(list)
    guard frames > 0, let data = buffers.first?.mData else { return }
    let left = data.assumingMemoryBound(to: Float.self)
    let right: UnsafeMutablePointer<Float>
    if buffers.count > 1, let r = buffers[1].mData {
      right = r.assumingMemoryBound(to: Float.self)
    } else {
      right = left
    }
    for i in 0..<frames {
      left[i] = 0
      if right != left { right[i] = 0 }
    }

    // Never wait: if the UI holds the lock, play on and pick up notes next cycle.
    if lock.try() {
      swap(&pending, &inbox)
      if paramsGen != renderParamsGen {
        rp = shared
        renderParamsGen = paramsGen
      }
      lock.unlock()
      for e in inbox { apply(e) }
      inbox.removeAll(keepingCapacity: true)
    }
    let sr = max(rp.sampleRate, 8000)
    let dt = 1 / sr
    let preset = rp.preset
    let wave = rp.wave
    let wave2 = rp.wave2
    let mix2 = Double(max(0, min(1, rp.mix)))
    let cents = Double(rp.detune) * 24
    let oct = rp.osc2Octave
    let a4 = rp.a4
    let driftAmt = Double(rp.drift)
    let ringAmt = Double(rp.ring)
    let glitchAmt = Double(rp.glitch)
    let cutTarget = 80 * pow(14000 / 80, Double(max(0.02, min(1, rp.cutoff))))
    cutHz += 0.04 * (cutTarget - cutHz)
    let res = Double(max(0, min(1, rp.resonance)))
    let voiceScale = 0.22 / sqrt(Double(max(1, voices.count)))
    var i = 0
    while i < voices.count {
      var v = voices[i]
      let freq = min(sr * 0.45, a4 * pow(2.0, (Double(v.midi) - 69) / 12))
      let freq2 = min(sr * 0.45, freq * pow(2.0, Double(oct)) * pow(2.0, cents / 1200))
      let attack = preset == .pad ? 0.14 : 0.005
      let release = max(0.005, rp.release)
      let releaseCoef = exp(-1 / (release * sr))
      // Pluck decays on its own; a release below the slider's maximum also shortens it on key-up.
      let pluckChoke = release < 1.15
      for f in 0..<frames {
        if preset == .pluck {
          v.env *= exp(-4.8 / sr)
          if v.releasing && pluckChoke { v.env *= releaseCoef }
        } else if v.releasing {
          v.env *= releaseCoef
        } else if v.env < 1 {
          v.env = min(1, v.env + dt / attack)
        }
        let wander = 1 + driftAmt * 0.004 * sin(v.phase * 0.012)
        let inc1 = freq * wander / sr
        let inc2 = freq2 * wander / sr
        var osc1 = Self.osc(wave, phase: v.phase, inc: inc1, rng: &rng)
        var osc2 = Self.osc(wave2, phase: v.phase2, inc: inc2, rng: &rng)
        v.phase += inc1
        v.phase2 += inc2
        if v.phase >= 1 { v.phase -= floor(v.phase) }
        if v.phase2 >= 1 { v.phase2 -= floor(v.phase2) }
        var osc = osc1 * (1 - mix2) + osc2 * mix2
        if ringAmt > 0.02 {
          osc *= 1 - ringAmt * 0.35 + sin(2 * Double.pi * v.phase * (2 + ringAmt * 3)) * ringAmt * 0.35
        }
        if glitchAmt > 0.04 {
          let crush = pow(2.0, 6 + (1 - glitchAmt) * 6)
          osc = (osc * crush).rounded() / crush
        }
        let s = Float(osc * v.env * Double(v.vel) * voiceScale * Self.trim(preset))
        left[f] += s
        if right != left { right[f] += s }
      }
      if v.env < 0.0006 {
        voices.remove(at: i)
      } else {
        voices[i] = v
        i += 1
      }
    }

    // Stable one-pole LP with gentle tanh in the feedback (no brickwall clip).
    let g = 1 - exp(-2 * Double.pi * min(cutHz, sr * 0.42) / sr)
    let fb = res * 0.72
    var zL = lpZ
    var zR = lpZR
    var dcl = dcBlockL
    var dcr = dcBlockR
    let out = 0.92 * Self.makeup(preset)
    for f in 0..<frames {
      var x = Double(left[f])
      x -= dcl
      dcl += 0.0004 * x
      let y = zL + g * (tanh(x - fb * zL) - zL)
      zL = y
      left[f] = Float(tanh(y * 1.15) * out)
      if right != left {
        var xr = Double(right[f])
        xr -= dcr
        dcr += 0.0004 * xr
        let yr = zR + g * (tanh(xr - fb * zR) - zR)
        zR = yr
        right[f] = Float(tanh(yr * 1.15) * out)
      }
    }
    lpZ = zL
    lpZR = zR
    dcBlockL = dcl
    dcBlockR = dcr
  }

  /// Bring presets to a similar seated level. Pluck is the reference.
  private static func trim(_ preset: InstrumentPreset) -> Double {
    switch preset {
    case .keys: return 0.78
    case .bass: return 1.58
    case .pluck: return 1.0
    case .pad: return 1.46
    case .noise: return 1.18
    }
  }

  /// Clean gain after the saturator, so level changes don't change the tone.
  /// Keys and pluck sat ~9 dB under bass/pad/drums; this seats them at a similar level.
  private static func makeup(_ preset: InstrumentPreset) -> Double {
    switch preset {
    case .keys: return 2.0    // +6 dB
    case .pluck: return 2.8   // +9 dB
    case .noise: return 2.0   // +6 dB
    case .bass: return 1.6    // +4 dB: the filtered saw sits ~4 dB under the old sine bass
    case .pad: return 1.0
    }
  }

  /// Band-limited analog-style osc. Phase is 0..<1.
  private static func osc(_ wave: OscWave, phase: Double, inc: Double, rng: inout RTRandom) -> Double {
    let t = phase - floor(phase)
    switch wave {
    case .sine:
      return sin(2 * Double.pi * t) * 1.25 + sin(4 * Double.pi * t) * 0.08
    case .triangle:
      return 1 - abs(4 * t - 2) * 0.95 + 0.05
    case .saw:
      return (2 * t - 1) - polyblep(t, inc)
    case .square:
      let s = t < 0.5 ? 1.0 : -1.0
      return 0.72 * (s - polyblep(t, inc) + polyblep(fmod(t + 0.5, 1), inc))
    case .pulse:
      let pw = 0.18
      let s = t < pw ? 1.0 : -1.0
      return 0.7 * (s - polyblep(t, inc) + polyblep(fmod(t + (1 - pw), 1), inc))
    case .noise:
      return rng.unit() * 1.4 - 0.7
    case .warm:
      let tri = 1 - abs(4 * t - 2)
      let sq = t < 0.5 ? 0.28 : -0.28
      return tri * 0.72 + sq
    }
  }

  private static func polyblep(_ t: Double, _ dt: Double) -> Double {
    if dt <= 0 { return 0 }
    if t < dt {
      let x = t / dt
      return x + x - x * x - 1
    }
    if t > 1 - dt {
      let x = (t - 1) / dt
      return x + x + x * x + 1
    }
    return 0
  }
}

/// Dry drum buffer played in lock-step with the transport; drive/dirt/vinyl are live.
final class LiveDrums: @unchecked Sendable {
  /// State written by the main thread under `lock`. The render thread copies it
  /// with `lock.try()` and never waits: if the lock is busy it plays on with its
  /// last copy and picks up the change next cycle.
  private struct Shared {
    var enabled = false
    var sampleRate: Double = 44100
    var loopDur: Double = 1
    var drive: Float = 0.15
    var dirt: Float = 0.12
    var vinyl: Float = 0
    var left: [Float] = []
    var right: [Float] = []
    var fillL: [Float] = []
    var fillR: [Float] = []
    var fillDur: Double = 0
    /// Wall time the fill starts (the bar line), so a late UI tick doesn't delay it.
    var fillAt: TimeInterval = 0
    var gen: UInt64 = 0
  }

  private let lock = NSLock()
  private var shared = Shared()
  private var retired = RetireBin()
  private var seenGen: UInt64 = 0

  /// Shared with the loops so drums and loops read one timeline. Reading the wall
  /// clock every callback jittered the drums by a millisecond or two.
  private let clock: TransportClock

  // Render-thread state.
  private var r = Shared()
  private var crackle = 0
  private var prev: Float = 0
  private var lp: Float = 0
  private var rng = RTRandom()

  var enabled: Bool {
    get { read { $0.enabled } }
    set { write { $0.enabled = newValue } }
  }
  var sampleRate: Double {
    get { read { $0.sampleRate } }
    set { write { $0.sampleRate = newValue } }
  }
  var loopDur: Double {
    get { read { $0.loopDur } }
    set { write { $0.loopDur = newValue } }
  }
  var drive: Float {
    get { read { $0.drive } }
    set { write { $0.drive = newValue } }
  }
  var dirt: Float {
    get { read { $0.dirt } }
    set { write { $0.dirt = newValue } }
  }
  var vinyl: Float {
    get { read { $0.vinyl } }
    set { write { $0.vinyl = newValue } }
  }

  init(clock: TransportClock) {
    self.clock = clock
  }

  private func read<T>(_ f: (Shared) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return f(shared)
  }

  private func write(_ f: (inout Shared) -> Void) {
    lock.lock()
    f(&shared)
    shared.gen &+= 1
    let dead = retired.collect(seen: seenGen)
    lock.unlock()
    _ = dead  // released here, off the render thread
  }

  /// Frees buffers the renderer has let go of. Call from the UI tick.
  func collect() {
    write { _ in }
  }

  func setDry(_ buf: AVAudioPCMBuffer) {
    let frames = Int(buf.frameLength)
    guard frames > 0, let ch = buf.floatChannelData else { return }
    let L = Array(UnsafeBufferPointer(start: ch[0], count: frames))
    let R = buf.format.channelCount > 1 ? Array(UnsafeBufferPointer(start: ch[1], count: frames)) : L
    write { s in
      retired.retire([s.left, s.right], gen: s.gen &+ 1)
      s.left = L
      s.right = R
    }
  }

  func startFill(_ buf: AVAudioPCMBuffer, duration: Double, at: TimeInterval? = nil) {
    let frames = Int(buf.frameLength)
    guard frames > 1, let ch = buf.floatChannelData else { return }
    let L = Array(UnsafeBufferPointer(start: ch[0], count: frames))
    let R = buf.format.channelCount > 1 ? Array(UnsafeBufferPointer(start: ch[1], count: frames)) : L
    let when = at ?? CACurrentMediaTime()
    write { s in
      retired.retire([s.fillL, s.fillR], gen: s.gen &+ 1)
      s.fillL = L
      s.fillR = R
      s.fillDur = max(duration, 0.05)
      s.fillAt = when
    }
  }

  func render(frames: Int, list: UnsafeMutablePointer<AudioBufferList>, timestamp: UnsafePointer<AudioTimeStamp>?) {
    let buffers = UnsafeMutableAudioBufferListPointer(list)
    guard frames > 0, let data = buffers.first?.mData else { return }
    let outL = data.assumingMemoryBound(to: Float.self)
    let outR: UnsafeMutablePointer<Float> = {
      if buffers.count > 1, let r = buffers[1].mData {
        return r.assumingMemoryBound(to: Float.self)
      }
      return outL
    }()
    let now = clock.time(timestamp, frames: frames)
    if lock.try() {
      if shared.gen != r.gen {
        r = shared  // arrays it replaces are held in `retired`, so no free here
      }
      seenGen = shared.gen
      lock.unlock()
    }
    let n = r.left.count
    guard r.enabled, n > 1, r.right.count == n else {
      for i in 0..<frames {
        outL[i] = 0
        if outR != outL { outR[i] = 0 }
      }
      return
    }
    let sr = max(r.sampleRate, 8000)
    let dur = max(r.loopDur, 0.05)
    let drive = r.drive
    let dirt = r.dirt
    let vinyl = Double(r.vinyl)
    let fillN = r.fillL.count
    let fillOK = fillN > 1 && r.fillR.count == fillN
    let t0 = now.t
    let fillFrom = r.fillAt - now.cycleStart
    let driveAmt = 1 + drive * 4.5
    for i in 0..<frames {
      let t = t0 + Double(i) / sr
      // Before the transport start (the short lead-in) stay silent rather than
      // playing the end of the pattern.
      if t < 0 {
        outL[i] = 0
        if outR != outL { outR[i] = 0 }
        continue
      }
      var x: Float = 0
      var y: Float = 0
      let ft = t - fillFrom
      if fillOK, ft >= 0, ft < r.fillDur {
        var fidx = ft / r.fillDur * Double(fillN)
        if fidx >= Double(fillN) { fidx = Double(fillN - 1) }
        let i0 = min(fillN - 1, Int(fidx))
        let i1 = min(fillN - 1, i0 + 1)
        let frac = Float(fidx - floor(fidx))
        x = r.fillL[i0] * (1 - frac) + r.fillL[i1] * frac
        y = r.fillR[i0] * (1 - frac) + r.fillR[i1] * frac
      } else {
        var pos = t.truncatingRemainder(dividingBy: dur)
        if pos < 0 { pos += dur }
        var idx = pos / dur * Double(n)
        if vinyl > 0.001 {
          idx += sin(2 * Double.pi * 0.32 * t) * vinyl * 0.0022 * Double(n)
          idx += sin(2 * Double.pi * 13 * t) * vinyl * 0.00028 * Double(n)
        }
        while idx < 0 { idx += Double(n) }
        idx = idx.truncatingRemainder(dividingBy: Double(n))
        let i0 = Int(idx)
        let i1 = (i0 + 1) % n
        let frac = Float(idx - floor(idx))
        x = r.left[i0] * (1 - frac) + r.left[i1] * frac
        y = r.right[i0] * (1 - frac) + r.right[i1] * frac
      }
      if drive > 0.01 {
        let g = driveAmt
        x = tanhf(x * g) / tanhf(g)
        y = tanhf(y * g) / tanhf(g)
      }
      if dirt > 0.01 {
        let hp = x - prev
        prev = x
        x += hp * dirt * 0.22
        y += hp * dirt * 0.18
        x += tanhf(x * x * x * (2 + dirt * 4)) * dirt * 0.18
      }
      if vinyl > 0.01 {
        let rumble = Float(sin(2 * Double.pi * 31 * t) * vinyl * 0.035)
        x += rumble
        y += rumble * 0.9
        if crackle > 0 {
          let c = Float(crackle) * 0.01 * Float(rng.unit() * 2 - 1)
          x += c; y += c
          crackle -= 1
        } else if rng.unit() < vinyl * 0.0024 {
          crackle = 2 + Int(rng.unit() * 17)
          let pop = Float(0.12 + rng.unit() * 0.23) * (rng.unit() < 0.5 ? 1 : -1)
          x += pop; y += pop
        }
        lp += 0.12 * (x - lp)
        let dull = Float(vinyl)
        x = x * (1 - dull * 0.45) + lp * dull * 0.45
        y = y * (1 - dull * 0.45) + lp * dull * 0.45
      }
      outL[i] = max(-1, min(1, x))
      if outR != outL { outR[i] = max(-1, min(1, y)) }
    }
  }
}
