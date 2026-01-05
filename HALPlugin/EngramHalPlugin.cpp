//
//  EngramHalPlugin.cpp
//  Engram Virtual Audio Device Implementation
//
//  Copyright © 2024-2026 Bala Kumar. All rights reserved.
//  https://balakumar.dev
//

#include "EngramHalPlugin.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

// MARK: - Ring Buffer Implementation

void EngramRingBuffer_Init(EngramRingBuffer* rb, UInt32 size) {
    rb->size = size;
    rb->buffer = (Float32*)calloc(size, sizeof(Float32));
    rb->writeIndex = 0;
    rb->readIndex = 0;
    pthread_mutex_init(&rb->lock, NULL);
}

void EngramRingBuffer_Destroy(EngramRingBuffer* rb) {
    if (rb->buffer) {
        free(rb->buffer);
        rb->buffer = NULL;
    }
    pthread_mutex_destroy(&rb->lock);
}

UInt32 EngramRingBuffer_Write(EngramRingBuffer* rb, const Float32* data, UInt32 frames) {
    pthread_mutex_lock(&rb->lock);

    UInt32 available = EngramRingBuffer_GetAvailableWrite(rb);
    UInt32 toWrite = (frames < available) ? frames : available;

    for (UInt32 i = 0; i < toWrite; i++) {
        rb->buffer[rb->writeIndex] = data[i];
        rb->writeIndex = (rb->writeIndex + 1) % rb->size;
    }

    pthread_mutex_unlock(&rb->lock);
    return toWrite;
}

UInt32 EngramRingBuffer_Read(EngramRingBuffer* rb, Float32* data, UInt32 frames) {
    pthread_mutex_lock(&rb->lock);

    UInt32 available = EngramRingBuffer_GetAvailableRead(rb);
    UInt32 toRead = (frames < available) ? frames : available;

    for (UInt32 i = 0; i < toRead; i++) {
        data[i] = rb->buffer[rb->readIndex];
        rb->readIndex = (rb->readIndex + 1) % rb->size;
    }

    // Zero-fill if not enough data
    for (UInt32 i = toRead; i < frames; i++) {
        data[i] = 0.0f;
    }

    pthread_mutex_unlock(&rb->lock);
    return toRead;
}

UInt32 EngramRingBuffer_GetAvailableRead(EngramRingBuffer* rb) {
    UInt32 w = rb->writeIndex;
    UInt32 r = rb->readIndex;
    return (w >= r) ? (w - r) : (rb->size - r + w);
}

UInt32 EngramRingBuffer_GetAvailableWrite(EngramRingBuffer* rb) {
    return rb->size - EngramRingBuffer_GetAvailableRead(rb) - 1;
}

// MARK: - Global State

static EngramDevice gDevice;
static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gRefCount = 0;

// MARK: - Plugin Factory

extern "C" void* EngramPlugIn_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    // Initialize device
    memset(&gDevice, 0, sizeof(EngramDevice));
    gDevice.objectID = kAudioObjectUnknown;
    gDevice.sampleRate = kEngramSampleRate;
    gDevice.channels = kEngramChannels;

    EngramRingBuffer_Init(&gDevice.ringBuffer, kEngramRingBufferSize);
    pthread_mutex_init(&gDevice.stateLock, NULL);
    
    // Calculate host ticks per frame
    struct mach_timebase_info timebaseInfo;
    mach_timebase_info(&timebaseInfo);
    gDevice.hostTicksPerFrame = (UInt64)(1000000000.0 / gDevice.sampleRate * (Float64)timebaseInfo.denom / (Float64)timebaseInfo.numer);
    
    gRefCount = 1;
    
    // Return interface
    static AudioServerPlugInDriverInterface interface = {
        NULL, // _reserved
        EngramPlugIn_QueryInterface,
        EngramPlugIn_AddRef,
        EngramPlugIn_Release,
        EngramPlugIn_Initialize,
        EngramPlugIn_CreateDevice,
        EngramPlugIn_DestroyDevice,
        NULL, // AddDeviceClient
        NULL, // RemoveDeviceClient
        NULL, // PerformDeviceConfigurationChange
        NULL, // AbortDeviceConfigurationChange

        // Property operations
        EngramDevice_HasProperty,
        EngramDevice_IsPropertySettable,
        EngramDevice_GetPropertyDataSize,
        EngramDevice_GetPropertyData,
        EngramDevice_SetPropertyData,

        // IO operations
        EngramDevice_StartIO,
        EngramDevice_StopIO,
        EngramDevice_GetZeroTimeStamp,
        EngramDevice_WillDoIOOperation,
        EngramDevice_BeginIOOperation,
        EngramDevice_DoIOOperation,
        EngramDevice_EndIOOperation
    };

    return &interface;
}

// MARK: - COM Interface

static HRESULT EngramPlugIn_QueryInterface(void* driver, REFIID iid, LPVOID* ppv) {
    CFUUIDRef interfaceID = CFUUIDCreateFromUUIDBytes(NULL, iid);

    if (CFEqual(interfaceID, IUnknownUUID) || CFEqual(interfaceID, kAudioServerPlugInDriverInterfaceUUID)) {
        *ppv = driver;
        EngramPlugIn_AddRef(driver);
        CFRelease(interfaceID);
        return S_OK;
    }

    CFRelease(interfaceID);
    *ppv = NULL;
    return E_NOINTERFACE;
}

static ULONG EngramPlugIn_AddRef(void* driver) {
    return ++gRefCount;
}

static ULONG EngramPlugIn_Release(void* driver) {
    UInt32 refCount = --gRefCount;

    if (refCount == 0) {
        EngramRingBuffer_Destroy(&gDevice.ringBuffer);
        pthread_mutex_destroy(&gDevice.stateLock);
    }

    return refCount;
}

// MARK: - Plugin Lifecycle

static OSStatus EngramPlugIn_Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    gHost = host;

    // Register device
    gDevice.objectID = 1000; // Arbitrary but unique

    printf("Engram HAL Plugin initialized\n");
    return kAudioHardwareNoError;
}

static OSStatus EngramPlugIn_CreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef description, const AudioServerPlugInClientInfo* clientInfo, AudioObjectID* outDeviceObjectID) {
    *outDeviceObjectID = gDevice.objectID;
    return kAudioHardwareNoError;
}

static OSStatus EngramPlugIn_DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID) {
    return kAudioHardwareNoError;
}

// MARK: - Property Management (Simplified - Full implementation would be extensive)

static Boolean EngramDevice_HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address) {
    // Basic properties only
    switch (address->mSelector) {
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyStreams:
            return true;
        default:
            return false;
    }
}

static OSStatus EngramDevice_IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address, Boolean* outIsSettable) {
    *outIsSettable = false;
    return kAudioHardwareNoError;
}

static OSStatus EngramDevice_GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32* outDataSize) {
    switch (address->mSelector) {
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
            *outDataSize = sizeof(CFStringRef);
            break;
        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64);
            break;
        default:
            *outDataSize = 0;
    }

    return kAudioHardwareNoError;
}

static OSStatus EngramDevice_GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    switch (address->mSelector) {
        case kAudioObjectPropertyName:
            *((CFStringRef*)outData) = CFSTR(kEngramDeviceName);
            *outDataSize = sizeof(CFStringRef);
            break;
        case kAudioObjectPropertyManufacturer:
            *((CFStringRef*)outData) = CFSTR(kEngramDeviceManufacturer);
            *outDataSize = sizeof(CFStringRef);
            break;
        case kAudioDevicePropertyNominalSampleRate:
            *((Float64*)outData) = gDevice.sampleRate;
            *outDataSize = sizeof(Float64);
            break;
        default:
            return kAudioHardwareUnknownPropertyError;
    }

    return kAudioHardwareNoError;
}

static OSStatus EngramDevice_SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32 inDataSize, const void* inData) {
    return kAudioHardwareUnsupportedOperationError;
}

// MARK: - IO Operations

static OSStatus EngramDevice_StartIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID) {
    pthread_mutex_lock(&gDevice.stateLock);
    gDevice.isRunning = true;
    gDevice.anchorHostTime = mach_absolute_time();
    pthread_mutex_unlock(&gDevice.stateLock);

    printf("Engram device started\n");
    return kAudioHardwareNoError;
}

static OSStatus EngramDevice_StopIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID) {
    pthread_mutex_lock(&gDevice.stateLock);
    gDevice.isRunning = false;
    pthread_mutex_unlock(&gDevice.stateLock);

    printf("Engram device stopped\n");
    return kAudioHardwareNoError;
}

static OSStatus EngramDevice_GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    *outSampleTime = 0;
    *outHostTime = gDevice.anchorHostTime;
    *outSeed = 1;

    return kAudioHardwareNoError;
}

static OSStatus EngramDevice_WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    *outWillDo = (operationID == kAudioServerPlugInIOOperationReadInput);
    *outWillDoInPlace = true;

    return kAudioHardwareNoError;
}

static OSStatus EngramDevice_BeginIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo) {
    return kAudioHardwareNoError;
}

static OSStatus EngramDevice_DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, AudioObjectID streamObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer) {
    if (operationID == kAudioServerPlugInIOOperationReadInput) {
        // Read from ring buffer (data injected by main app)
        Float32* buffer = (Float32*)ioMainBuffer;
        EngramRingBuffer_Read(&gDevice.ringBuffer, buffer, ioBufferFrameSize * gDevice.channels);
    }

    return kAudioHardwareNoError;
}

static OSStatus EngramDevice_EndIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo) {
    return kAudioHardwareNoError;
}
