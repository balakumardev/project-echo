//
//  EchoHalPlugin.h
//  Echo Virtual Audio Device
//
//  Core Audio HAL Plugin for virtual microphone functionality
//

#ifndef EchoHalPlugin_h
#define EchoHalPlugin_h

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>

// Plugin UUID
#define kEchoPlugInUID "com.projectecho.hal.plugin"
#define kEchoDeviceUID "com.projectecho.hal.device"

// Device properties
#define kEchoDeviceName "Echo Virtual Microphone"
#define kEchoDeviceManufacturer "Project Echo"
#define kEchoSampleRate 48000.0
#define kEchoChannels 2
#define kEchoRingBufferSize 65536

// MARK: - Ring Buffer

typedef struct {
    Float32* buffer;
    UInt32 size;
    volatile UInt32 writeIndex;
    volatile UInt32 readIndex;
    pthread_mutex_t lock;
} EchoRingBuffer;

// Ring buffer operations
void EchoRingBuffer_Init(EchoRingBuffer* rb, UInt32 size);
void EchoRingBuffer_Destroy(EchoRingBuffer* rb);
UInt32 EchoRingBuffer_Write(EchoRingBuffer* rb, const Float32* data, UInt32 frames);
UInt32 EchoRingBuffer_Read(EchoRingBuffer* rb, Float32* data, UInt32 frames);
UInt32 EchoRingBuffer_GetAvailableRead(EchoRingBuffer* rb);
UInt32 EchoRingBuffer_GetAvailableWrite(EchoRingBuffer* rb);

// MARK: - Device State

typedef struct {
    AudioObjectID objectID;
    AudioObjectID inputStreamID;
    AudioObjectID outputStreamID;
    
    Float64 sampleRate;
    UInt32 channels;
    
    EchoRingBuffer ringBuffer;
    
    Boolean isRunning;
    UInt64 hostTicksPerFrame;
    UInt64 anchorHostTime;
    
    pthread_mutex_t stateLock;
} EchoDevice;

// MARK: - Plugin Interface

// Entry point
extern "C" void* EchoPlugIn_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);

// AudioServerPlugIn callbacks
static HRESULT EchoPlugIn_QueryInterface(void* driver, REFIID iid, LPVOID* ppv);
static ULONG EchoPlugIn_AddRef(void* driver);
static ULONG EchoPlugIn_Release(void* driver);

static OSStatus EchoPlugIn_Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host);
static OSStatus EchoPlugIn_CreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef description, const AudioServerPlugInClientInfo* clientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus EchoPlugIn_DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID);

// Device property management
static Boolean EchoDevice_HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address);
static OSStatus EchoDevice_IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address, Boolean* outIsSettable);
static OSStatus EchoDevice_GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32* outDataSize);
static OSStatus EchoDevice_GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus EchoDevice_SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientPID, const AudioObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32 inDataSize, const void* inData);

// IO operations
static OSStatus EchoDevice_StartIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID);
static OSStatus EchoDevice_StopIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID);
static OSStatus EchoDevice_GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus EchoDevice_WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus EchoDevice_BeginIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo);
static OSStatus EchoDevice_DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, AudioObjectID streamObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus EchoDevice_EndIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo* ioCycleInfo);

#endif /* EchoHalPlugin_h */
