//
//  EchoHalPlugin.cpp
//  Echo Virtual Audio Device Implementation
//

#include "EchoHalPlugin.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

// MARK: - Ring Buffer Implementation

void EchoRingBuffer_Init(EchoRingBuffer* rb, UInt32 size) {
    rb->size = size;
    rb->buffer = (Float32*)calloc(size, sizeof(Float32));
    rb->writeIndex = 0;
    rb->readIndex = 0;
    pthread_mutex_init(&rb->lock, NULL);
}

void EchoRingBuffer_Destroy(EchoRingBuffer* rb) {
    if (rb->buffer) {
        free(rb->buffer);
        rb->buffer = NULL;
    }
    pthread_mutex_destroy(&rb->lock);
}

UInt32 EchoRingBuffer_Write(EchoRingBuffer* rb, const Float32* data, UInt32 frames) {
    pthread_mutex_lock(&rb->lock);
    
    UInt32 available = EchoRingBuffer_GetAvailableWrite(rb);
    UInt32 toWrite = (frames < available) ? frames : available;
    
    for (UInt32 i = 0; i < toWrite; i++) {
        rb->buffer[rb->writeIndex] = data[i];
        rb->writeIndex = (rb->writeIndex + 1) % rb->size;
    }
    
    pthread_mutex_unlock(&rb->lock);
    return toWrite;
}

UInt32 EchoRingBuffer_Read(EchoRingBuffer* rb, Float32* data, UInt32 frames) {
    pthread_mutex_lock(&rb->lock);
    
    UInt32 available = EchoRingBuffer_GetAvailableRead(rb);
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

UInt32 EchoRingBuffer_GetAvailableRead(EchoRingBuffer* rb) {
    UInt32 w = rb->writeIndex;
    UInt32 r = rb->readIndex;
    return (w >= r) ? (w - r) : (rb->size - r + w);
}

UInt32 EchoRingBuffer_GetAvailableWrite(EchoRingBuffer* rb) {
    return rb->size - EchoRingBuffer_GetAvailableRead(rb) - 1;
}

// MARK: - Global State

static EchoDevice gDevice;
static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gRefCount = 0;

// MARK: - Plugin Factory

extern "C" void* EchoPlugIn_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    // Initialize device
    memset(&gDevice, 0, sizeof(EchoDevice));
    gDevice.objectID = kAudioObjectUnknown;
    gDevice.sampleRate = kEchoSampleRate;
    gDevice.channels = kEchoChannels;
    
    EchoRingBuffer_Init(&gDevice.ringBuffer, kEchoRingBufferSize);
    pthread_mutex_init(&gDevice.stateLock, NULL);
    
    // Calculate host ticks per frame
    struct mach_timebase_info timebaseInfo;
    mach_timebase_info(&timebaseInfo);
    gDevice.hostTicksPerFrame = (UInt64)(1000000000.0 / gDevice.sampleRate * (Float64)timebaseInfo.denom / (Float64)timebaseInfo.numer);
    
    gRefCount = 1;
    
    // Return interface
    static AudioServerPlugInDriverInterface interface = {
        NULL, // _reserved
        EchoPlugIn_QueryInterface,
        EchoPlugIn_AddRef,
        EchoPlugIn_Release,
        EchoPlugIn_Initialize,
        EchoPlugIn_CreateDevice,
        EchoPlugIn_DestroyDevice,
        NULL, // AddDeviceClient
        NULL, // RemoveDeviceClient
        NULL, // PerformDeviceConfigurationChange
        NULL, // AbortDeviceConfigurationChange
        
        // Property operations
        EchoDevice_HasProperty,
        EchoDevice_IsPropertySettable,
        EchoDevice_GetPropertyDataSize,
        EchoDevice_GetPropertyData,
        EchoDevice_SetPropertyData,
        
        // IO operations
        EchoDevice_StartIO,
        EchoDevice_StopIO,
        EchoDevice_GetZeroTimeStamp,
        EchoDevice_WillDoIOOperation,
        EchoDevice_BeginIOOperation,
        EchoDevice_DoIOOperation,
        EchoDevice_EndIOOperation
    };
    
    return &interface;
}

// MARK: - COM Interface

static HRESULT EchoPlugIn_QueryInterface(void* driver, REFIID iid, LPVOID* ppv) {
    if (CFEqual(iid, IUnknownUUID) || CFEqual(iid, kAudioServerPlugInDriverInterfaceUUID)) {
        *ppv = driver;
        EchoPlugIn_AddRef(driver);
        return S_OK;
    }
    
    *ppv = NULL;
    return E_NOINTERFACE;
}

static ULONG EchoPlugIn_AddRef(void* driver) {
    return ++gRefCount;
}

static ULONG EchoPlugIn_Release(void* driver) {
    UInt32 refCount = --gRefCount;
    
    if (refCount == 0) {
        EchoRingBuffer_Destroy(&gDevice.ringBuffer);
        pthread_mutex_destroy(&gDevice.stateLock);
    }
    
    return refCount;
}

// MARK: - Plugin Lifecycle

static OSStatus EchoPlugIn_Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    gHost = host;
    
    // Register device
    gDevice.objectID = 1000; // Arbitrary but unique
    
    printf("Echo HAL Plugin initialized\n");
    return kAudioHardwareNoError;
}

static OSStatus EchoPlugIn_CreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef description, const AudioServerPlugInClientInfo* clientInfo, AudioObjectID* outDeviceObjectID) {
    *outDeviceObjectID = gDevice.objectID;
    return kAudioHardwareNoError;
}

static OSStatus EchoPlugIn_DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID) {
    return kAudioHardwareNoError;
}

// MARK: - Property Management (Simplified - Full implementation would be extensive)

static Boolean EchoDevice_HasProperty(AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address) {
    // Basic properties only
    switch (address->mSelector) {
        case kAudioDevicePropertyDeviceName:
        case kAudioDevicePropertyDeviceManufacturer:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyStreams:
            return true;
        default:
            return false;
    }
}

static OSStatus EchoDevice_IsPropertySettable(AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address, Boolean* outIsSettable) {
    *outIsSettable = false;
    return kAudioHardwareNoError;
}

static OSStatus EchoDevice_GetPropertyDataSize(AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32* outDataSize) {
    switch (address->mSelector) {
        case kAudioDevicePropertyDeviceName:
        case kAudioDevicePropertyDeviceManufacturer:
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

static OSStatus EchoDevice_GetPropertyData(AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    switch (address->mSelector) {
        case kAudioDevicePropertyDeviceName:
            *((CFStringRef*)outData) = CFSTR(kEchoDeviceName);
            *outDataSize = sizeof(CFStringRef);
            break;
        case kAudioDevicePropertyDeviceManufacturer:
            *((CFStringRef*)outData) = CFSTR(kEchoDeviceManufacturer);
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

static OSStatus EchoDevice_SetPropertyData(AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32 inDataSize, const void* inData) {
    return kAudioHardwareUnsupportedOperationError;
}

// MARK: - IO Operations

static OSStatus EchoDevice_StartIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID) {
    pthread_mutex_lock(&gDevice.stateLock);
    gDevice.isRunning = true;
    gDevice.anchorHostTime = mach_absolute_time();
    pthread_mutex_unlock(&gDevice.stateLock);
    
    printf("Echo device started\n");
    return kAudioHardwareNoError;
}

static OSStatus EchoDevice_StopIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID) {
    pthread_mutex_lock(&gDevice.stateLock);
    gDevice.isRunning = false;
    pthread_mutex_unlock(&gDevice.stateLock);
    
    printf("Echo device stopped\n");
    return kAudioHardwareNoError;
}

static OSStatus EchoDevice_GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    *outSampleTime = 0;
    *outHostTime = gDevice.anchorHostTime;
    *outSeed = 1;
    
    return kAudioHardwareNoError;
}

static OSStatus EchoDevice_WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    *outWillDo = (operationID == kAudioServerPlugInIOOperationReadInput);
    *outWillDoInPlace = true;
    
    return kAudioHardwareNoError;
}

static OSStatus EchoDevice_BeginIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo) {
    return kAudioHardwareNoError;
}

static OSStatus EchoDevice_DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, AudioObjectID streamObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer) {
    if (operationID == kAudioServerPlugInIOOperationReadInput) {
        // Read from ring buffer (data injected by main app)
        Float32* buffer = (Float32*)ioMainBuffer;
        EchoRingBuffer_Read(&gDevice.ringBuffer, buffer, ioBufferFrameSize * gDevice.channels);
    }
    
    return kAudioHardwareNoError;
}

static OSStatus EchoDevice_EndIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo) {
    return kAudioHardwareNoError;
}
