//
//  EngramHalPlugin.h
//  Engram Virtual Audio Device
//
//  Core Audio HAL Plugin for virtual microphone functionality
//  Copyright © 2024-2026 Bala Kumar. All rights reserved.
//  https://balakumar.dev
//

#ifndef EngramHalPlugin_h
#define EngramHalPlugin_h

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>

// Plugin UUID
#define kEngramPlugInUID "dev.balakumar.engram.hal.plugin"
#define kEngramDeviceUID "dev.balakumar.engram.hal.device"

// Device properties
#define kEngramDeviceName "Engram Virtual Microphone"
#define kEngramDeviceManufacturer "Bala Kumar"
#define kEngramSampleRate 48000.0
#define kEngramChannels 2
#define kEngramRingBufferSize 65536

// MARK: - Ring Buffer

typedef struct {
    Float32* buffer;
    UInt32 size;
    volatile UInt32 writeIndex;
    volatile UInt32 readIndex;
    pthread_mutex_t lock;
} EngramRingBuffer;

// Ring buffer operations
void EngramRingBuffer_Init(EngramRingBuffer* rb, UInt32 size);
void EngramRingBuffer_Destroy(EngramRingBuffer* rb);
UInt32 EngramRingBuffer_Write(EngramRingBuffer* rb, const Float32* data, UInt32 frames);
UInt32 EngramRingBuffer_Read(EngramRingBuffer* rb, Float32* data, UInt32 frames);
UInt32 EngramRingBuffer_GetAvailableRead(EngramRingBuffer* rb);
UInt32 EngramRingBuffer_GetAvailableWrite(EngramRingBuffer* rb);

// MARK: - Device State

typedef struct {
    AudioObjectID objectID;
    AudioObjectID inputStreamID;
    AudioObjectID outputStreamID;

    Float64 sampleRate;
    UInt32 channels;

    EngramRingBuffer ringBuffer;

    Boolean isRunning;
    UInt64 hostTicksPerFrame;
    UInt64 anchorHostTime;

    pthread_mutex_t stateLock;
} EngramDevice;

// MARK: - Plugin Interface

// Entry point
extern "C" void* EngramPlugIn_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);

// AudioServerPlugIn callbacks
static HRESULT EngramPlugIn_QueryInterface(void* driver, REFIID iid, LPVOID* ppv);
static ULONG EngramPlugIn_AddRef(void* driver);
static ULONG EngramPlugIn_Release(void* driver);

static OSStatus EngramPlugIn_Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host);
static OSStatus EngramPlugIn_CreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef description, const AudioServerPlugInClientInfo* clientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus EngramPlugIn_DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID);

// Device property management
static Boolean EngramDevice_HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address);
static OSStatus EngramDevice_IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address, Boolean* outIsSettable);
static OSStatus EngramDevice_GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32* outDataSize);
static OSStatus EngramDevice_GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus EngramDevice_SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32 inDataSize, const void* inData);

// IO operations
static OSStatus EngramDevice_StartIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID);
static OSStatus EngramDevice_StopIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID);
static OSStatus EngramDevice_GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus EngramDevice_WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus EngramDevice_BeginIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo);
static OSStatus EngramDevice_DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, AudioObjectID streamObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus EngramDevice_EndIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo);

#endif /* EngramHalPlugin_h */
