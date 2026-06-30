// echook-mic-busy: exit 0 ("busy") if the default input device (microphone) is
// in use by any app (dictation / call), exit 1 ("idle") otherwise.
//
// Used by the echook duck patch to stay silent while you dictate (e.g. VoiceInk)
// without breaking the mic session. Reads CoreAudio
// kAudioDevicePropertyDeviceIsRunningSomewhere on the default input device.
//
// Build: swiftc -O -o ~/.claude/bin/echook-mic-busy echook-mic-busy.swift \
//          -framework CoreAudio -framework Foundation
import CoreAudio
import Foundation

func defaultInputDevice() -> AudioDeviceID? {
    var id = AudioDeviceID(0)
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    var a = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &id) == noErr ? id : nil
}

guard let dev = defaultInputDevice() else { print("idle"); exit(1) }
var running = UInt32(0)
var sz = UInt32(MemoryLayout<UInt32>.size)
var a = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
let st = AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &running)
if st == noErr && running != 0 { print("busy"); exit(0) } else { print("idle"); exit(1) }
