//
//  AudioDeviceService.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 19/01/26.
//

import Foundation
import CoreAudio
import Combine

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDeviceError: LocalizedError {
    case failedToGetDevices(OSStatus)
    case failedToGetDefaultDevice(OSStatus)
    case failedToSetDefaultDevice(OSStatus)
    case deviceNotFound
    
    var errorDescription: String? {
        switch self {
        case .failedToGetDevices(let status):
            return "Failed to get audio devices (error: \(status))"
        case .failedToGetDefaultDevice(let status):
            return "Failed to get default input device (error: \(status))"
        case .failedToSetDefaultDevice(let status):
            return "Failed to set default input device (error: \(status))"
        case .deviceNotFound:
            return "Audio device not found"
        }
    }
}

class AudioDeviceService: ObservableObject {
    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var defaultInputDeviceID: AudioDeviceID?
    
    init() {
        refreshDevices()
    }
    
    func refreshDevices() {
        inputDevices = getInputDevices()
        defaultInputDeviceID = getDefaultInputDeviceID()
    }
    
    private func getInputDevices() -> [AudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        
        guard status == noErr else { return [] }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        
        guard status == noErr else { return [] }
        
        return deviceIDs.compactMap { deviceID -> AudioDevice? in
            guard hasInputChannels(deviceID: deviceID) else { return nil }
            guard let name = getDeviceName(deviceID: deviceID),
                  let uid = getDeviceUID(deviceID: deviceID) else { return nil }
            return AudioDevice(id: deviceID, uid: uid, name: name)
        }
    }
    
    private func hasInputChannels(deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return false }
        
        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferListPointer.deallocate() }
        
        let result = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufferListPointer)
        guard result == noErr else { return false }
        
        let bufferList = bufferListPointer.pointee
        return bufferList.mNumberBuffers > 0 && bufferList.mBuffers.mNumberChannels > 0
    }
    
    private func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var name: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &name)
        guard status == noErr, let deviceName = name else { return nil }
        return deviceName as String
    }
    
    private func getDeviceUID(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var uid: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &uid)
        guard status == noErr, let deviceUID = uid else { return nil }
        return deviceUID as String
    }
    
    private func getDefaultInputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
    
    func setDefaultInputDevice(_ deviceID: AudioDeviceID) throws {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var mutableDeviceID = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableDeviceID
        )
        
        guard status == noErr else {
            throw AudioDeviceError.failedToSetDefaultDevice(status)
        }
        
        defaultInputDeviceID = deviceID
    }
    
    func setDefaultInputDevice(byUID uid: String) throws {
        guard let device = inputDevices.first(where: { $0.uid == uid }) else {
            throw AudioDeviceError.deviceNotFound
        }
        try setDefaultInputDevice(device.id)
    }
    
    func getDefaultInputDevice() -> AudioDevice? {
        guard let deviceID = defaultInputDeviceID else { return nil }
        return inputDevices.first { $0.id == deviceID }
    }
}
