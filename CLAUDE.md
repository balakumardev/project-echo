# Engram - Development Guidelines

Engram is a macOS meeting recorder and AI assistant by Bala Kumar.
https://balakumar.dev

## Project Setup

### Architecture

The project uses **XcodeGen** to generate the Xcode project from `project.yml`. This approach:
- Keeps the `.xcodeproj` out of version control (it's generated)
- Makes project configuration readable and diffable
- Avoids Xcode project merge conflicts

### Key Configuration Files

| File | Purpose | Edit? |
|------|---------|-------|
| `project.yml` | XcodeGen project spec (targets, dependencies, build settings) | ✅ Yes |
| `Engram.xcodeproj/` | Generated Xcode project | ❌ No - regenerate instead |
| `Package.swift` | Swift Package Manager config (for CLI builds) | Optional |
| `Info.plist` | App metadata, privacy descriptions, URL schemes | ✅ Yes |
| `Engram.entitlements` | App entitlements (microphone, screen recording, etc.) | ✅ Yes |
| `Debug.xcconfig` | Xcode build settings for debug builds | ✅ Yes |

### Module Structure

The app is split into framework targets for clean architecture:

| Target | Path | Purpose |
|--------|------|---------|
| **Engram** (App) | `Sources/App/` | Main app, entry point, FileLogger, CrashLogger |
| **AudioEngine** | `Sources/AudioEngine/` | Audio capture, screen recording, media muxing |
| **Intelligence** | `Sources/Intelligence/` | AI/RAG, transcription, summarization, LLM |
| **Database** | `Sources/Database/` | SQLite persistence via SQLite.swift |
| **UI** | `Sources/UI/` | SwiftUI views, menu bar, chat interface |

## Building the App

**Never run the app yourself.** Always let the user run it manually.

### Option 1: Xcode (Recommended)

```bash
open Engram.xcodeproj
# Press ⌘R to build and run
```

- Full debugging support (breakpoints, variables, etc.)
- Automatic code signing with `Engram Development` certificate
- MLX Metal shaders copied automatically

### Option 2: Command Line

```bash
./scripts/build_app.sh
# User runs: open Engram.app
```

### Regenerating Xcode Project

After modifying `project.yml`:
```bash
xcodegen generate
```

**Common reasons to regenerate:**
- Added/removed source files (though Xcode usually picks these up)
- Changed dependencies
- Modified build settings
- Changed target configuration

## Code Signing

The app uses a self-signed `Engram Development` certificate. This is critical for:
- Preserving TCC permissions (microphone, screen recording) across rebuilds
- Consistent app identity for macOS security

### First-Time Setup

```bash
./scripts/create_signing_cert.sh
```

Then in Keychain Access:
1. Find `Engram Development` in My Certificates
2. Double-click → Trust → Code Signing: Always Trust

### Entitlements

Key entitlements in `Engram.entitlements`:
- `com.apple.security.device.audio-input` - Microphone access
- `com.apple.security.get-task-allow` - Debugger attachment (debug builds)
- `com.apple.security.cs.disable-library-validation` - Load unsigned frameworks
- `com.apple.security.network.client` - Network access

## Logging System

The app uses a **hybrid logging approach**:

1. **OSLog** - Apple's unified logging (visible in Console.app)
2. **FileLogger** - Persistent file logs for debugging
3. **CrashLogger** - Crash reports and fatal errors

### Log File Locations

| Log | Path | Purpose |
|-----|------|---------|
| Debug | `~/Library/Logs/Engram/debug.log` | Meeting detection, audio capture, app lifecycle |
| RAG | `~/Library/Logs/Engram/rag.log` | AI operations, transcription, summarization |
| Errors | `~/Library/Application Support/Engram/Logs/engram_errors.log` | Crashes, fatal errors |

### Viewing Logs

```bash
# Real-time debug log
tail -f ~/Library/Logs/Engram/debug.log

# Real-time RAG/AI log
tail -f ~/Library/Logs/Engram/rag.log

# Error log
tail -f ~/Library/Application\ Support/Engram/Logs/engram_errors.log

# Both logs side by side
tail -f ~/Library/Logs/Engram/*.log
```

### Console.app (OSLog)

1. Open Console.app
2. Select your Mac in the sidebar
3. Filter by: `subsystem:dev.balakumar.engram`

OSLog categories:
- `Debug` - General debugging
- `RAG` - AI/RAG operations
- `App`, `MeetingDetector`, `AudioEngine`, etc.

### Log Patterns to Search For

| Pattern | Meaning |
|---------|---------|
| `[AIService]` | Model loading, auto-unload, memory management |
| `[Agent]` | TranscriptAgent query processing |
| `[AgentChat]` | RAG pipeline chat responses |
| `[Init]` | RAG pipeline initialization |
| `checkForActiveMeetingApps` | Meeting detection cycle |
| `[ERROR]` | Error conditions |
| `[WARN]` | Warnings |

### FileLogger API

In the App module:
```swift
FileLogger.shared.debug("Message")           // Debug log
FileLogger.shared.rag("Message")             // RAG log
FileLogger.shared.agent("Message")           // RAG log with [Agent] prefix
FileLogger.shared.aiService("Message")       // RAG log with [AIService] prefix
FileLogger.shared.debugError("Msg", error: e) // Error with details
```

In AudioEngine/Intelligence modules:
```swift
fileDebugLog("Message")    // Writes to debug.log
fileRagLog("Message")      // Writes to rag.log
fileAgentLog("Message")    // Writes to rag.log with [Agent] prefix
```

### Log Rotation

FileLogger automatically:
- Trims logs when they exceed 5MB
- Keeps the most recent 2000 lines
- Reopens file handles after trimming

## Debugging Tips

### App Won't Start

1. Check for existing instances: `pkill Engram`
2. Check entitlements: `codesign -d --entitlements - Engram.app`
3. Check signing: `codesign -dv Engram.app`

### Permission Issues

If microphone/screen recording permissions reset:
1. Verify signing certificate: `security find-identity -v -p codesigning | grep Engram`
2. Check bundle ID matches: `defaults read Engram.app/Contents/Info.plist CFBundleIdentifier`
3. Reset TCC database (nuclear option): `tccutil reset All dev.balakumar.engram`

### Build Failures

```bash
# Clean DerivedData
rm -rf ~/Library/Developer/Xcode/DerivedData/Engram-*

# Regenerate project
xcodegen generate

# Rebuild
xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build
```

### Debugging in Xcode

1. Open `Engram.xcodeproj`
2. Set breakpoints as needed
3. Press ⌘R to build and run
4. Use Debug navigator (⌘7) to inspect threads/variables

### Attach to Running Process

If the app is already running:
1. In Xcode: Debug → Attach to Process → Engram

## Project Structure

```
project-echo/
├── project.yml              # XcodeGen spec - EDIT THIS
├── Package.swift            # SPM config (alternative build)
├── Info.plist               # App metadata, privacy strings
├── Engram.entitlements      # App entitlements
├── Debug.xcconfig           # Debug build settings
│
├── Sources/
│   ├── App/                 # Main app target
│   │   ├── EngramApp.swift      # @main entry point
│   │   ├── FileLogger.swift     # Hybrid file/OSLog logger
│   │   ├── CrashLogger.swift    # Crash handling
│   │   ├── MeetingDetector.swift
│   │   ├── ProcessingQueue.swift
│   │   └── SystemEventHandler.swift
│   │
│   ├── AudioEngine/         # Audio/video capture
│   │   ├── AudioCaptureEngine.swift
│   │   ├── ScreenRecorder.swift
│   │   ├── MediaMuxer.swift
│   │   └── MediaDeviceMonitor.swift
│   │
│   ├── Intelligence/        # AI/ML layer
│   │   ├── TranscriptionEngine.swift
│   │   ├── SpeakerDiarizationEngine.swift
│   │   └── RAG/
│   │       ├── RAGPipeline.swift
│   │       ├── TranscriptAgent.swift
│   │       ├── AIService.swift
│   │       ├── LLMEngine.swift
│   │       └── EmbeddingEngine.swift
│   │
│   ├── Database/            # Persistence
│   │   └── DatabaseManager.swift
│   │
│   └── UI/                  # SwiftUI views
│       ├── MenuBarController.swift
│       ├── LibraryView.swift
│       └── Chat/
│
├── Resources/
│   └── AppIcon.icns
│
├── scripts/
│   ├── build_app.sh             # CLI build script
│   └── create_signing_cert.sh   # Certificate setup
│
└── Tests/
    └── EngramTests/
```

## Dependencies

Managed via Swift Package Manager (defined in both `Package.swift` and `project.yml`):

| Package | Purpose |
|---------|---------|
| WhisperKit | Local speech transcription |
| SQLite.swift | Database wrapper |
| FluidAudio | Speaker diarization |
| VecturaKit | Vector database for RAG |
| mlx-swift-lm | Apple MLX local LLM inference |
