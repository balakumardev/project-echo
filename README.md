# Project Echo

**The "Black Box" Flight Recorder for Digital Meetings**

A privacy-first macOS utility that automatically captures audio from teleconferencing apps (Zoom, Teams, Meet) and generates searchable transcripts using local AI. Everything runs on-device with zero cloud uploads.

**No virtual audio device needed!** Uses ScreenCaptureKit to record both your microphone and meeting audio.

## ✨ Features

### Phase 1: Core Recording ✅
- **ScreenCaptureKit Integration** - High-fidelity system audio capture
- **Multi-track Recording** - Separate tracks for system audio and microphone
- **App-specific Capture** - Target Zoom, Teams, Meet, etc.
- **Menu Bar Controls** - Quick access to start/stop recording
- **Marker Insertion** - Tag important moments during calls

### Phase 2: Intelligence Layer ✅
- **Local AI Transcription** - WhisperKit (CoreML) for on-device processing
- **Speaker Diarization** - Identify who said what
- **Smart Summarization** - Extract action items and key topics
- **Full-text Search** - SQLite FTS5 for instant transcript search
- **Zero Cloud Uploads** - Everything stays on your device

### Phase 3: Pro Extension (HAL Plugin) ⚠️ OPTIONAL
- **Virtual Audio Device** - "Echo Mic" for audio injection
- **Soundboard Support** - Route files or TTS into meetings
- **NOT REQUIRED** - Main app works perfectly without it
- See `HAL_PLUGIN_ADVANCED.md` for details

### Phase 4: Polish & Persistence ✅
- **Beautiful Library UI** - SwiftUI interface with audio player
- **Export Options** - Audio and transcript export
- **Comprehensive Settings** - Customize quality, storage, models
- **Privacy Dashboard** - Clear data usage transparency

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    PROJECT ECHO                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌─────────────────┐  │
│  │ AudioEngine  │  │ Intelligence │  │   Database      │  │
│  │              │  │              │  │                 │  │
│  │ ScreenKit    │  │ WhisperKit   │  │  SQLite + FTS5  │  │
│  │ AVCapture    │──▶ CoreML       │──▶  Recordings    │  │
│  │              │  │ Diarization  │  │  Transcripts    │  │
│  └──────────────┘  └──────────────┘  └─────────────────┘  │
│         │                                      │            │
│         └──────────────┬───────────────────────┘            │
│                        │                                    │
│                  ┌──────────┐                               │
│                  │    UI    │                               │
│                  │          │                               │
│                  │ Menu Bar │                               │
│                  │ Library  │                               │
│                  │ Settings │                               │
│                  └──────────┘                               │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│                   HAL PLUGIN (Optional)                     │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  Core Audio HAL Driver (C++)                        │  │
│  │  - Virtual Input Device ("Echo Mic")                │  │
│  │  - Shared Memory Ring Buffer                        │  │
│  │  - 48kHz Stereo @ < 20ms latency                    │  │
│  └─────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## 🚀 Quick Start

### Prerequisites
- macOS Sonoma (14.0) or later
- Xcode Command Line Tools
- ~2GB disk space for Whisper models

### Building & Running

```bash
# Build the app
./build.sh

# Launch it
./run_app.sh
```

### First Launch

1. **Grant Permissions** (one-time setup)
   - Open System Settings → Privacy & Security
   - **Microphone**: Click "+", add ProjectEcho.app, enable checkbox
   - **Screen Recording**: Click "+", add ProjectEcho.app, enable checkbox

2. **Start Recording**
   - Click menu bar icon (🎙️)
   - Select "Start Recording"
   - Join your Zoom/Teams/Meet meeting
   - **Both your mic AND meeting audio are recorded automatically!**
   - Click "Stop Recording" when done

3. **View Transcript**
   - Open Library from menu bar
   - Click on your recording
   - AI transcript generates automatically (100% local, private)

### What You Get Out of the Box

✅ **Records your microphone**
✅ **Records meeting audio** (other participants)
✅ **Auto-detects Zoom/Teams/Meet**
✅ **AI transcription** (WhisperKit, runs locally)
✅ **Searchable library**
✅ **No cloud uploads** - everything stays on your Mac

**No HAL plugin needed!** The app uses ScreenCaptureKit to capture all audio.

### Advanced: HAL Plugin (Optional)

⚠️ **Most users don't need this!** Only install if you want to inject audio INTO meetings (soundboards, etc.).

See `HAL_PLUGIN_ADVANCED.md` for details and installation instructions.

## 📁 Project Structure

```
drifting-pulsar/
├── Sources/
│   ├── AudioEngine/          # ScreenCaptureKit + AVCapture
│   │   └── AudioCaptureEngine.swift
│   ├── Intelligence/         # WhisperKit transcription
│   │   └── TranscriptionEngine.swift
│   ├── Database/            # SQLite management
│   │   └── DatabaseManager.swift
│   ├── UI/                  # SwiftUI views
│   │   ├── MenuBarController.swift
│   │   ├── LibraryView.swift
│   │   └── ViewModels.swift
│   └── App/                 # Main entry point
│       └── main.swift
├── HALPlugin/               # Core Audio driver (C++)
│   ├── EchoHalPlugin.h
│   ├── EchoHalPlugin.cpp
│   ├── Info.plist
│   └── Makefile
├── Package.swift            # Swift Package Manager
├── Info.plist              # App metadata
├── ProjectEcho.entitlements # Permissions
└── build.sh                # Build script
```

## 🔒 Privacy & Security

**Local-First AI**
- Whisper models run entirely on Apple Neural Engine
- No audio or transcripts leave your device
- No analytics or tracking

**Data Storage**
- Recordings: `~/Documents/ProjectEcho/Recordings/`
- Database: `~/Library/Application Support/ProjectEcho/echo.db`
- Models: Cached by WhisperKit

**Permissions**
- Screen Recording: Required for system audio capture
- Microphone: Required for your audio track
- File System: Read/write to save recordings

## ⚙️ Configuration

### Settings > General
- **Auto-transcribe** - Generate transcripts automatically
- **Whisper Model** - tiny/base/small/medium (trade speed vs accuracy)
- **Storage Location** - Where recordings are saved

### Settings > Advanced
- **Sample Rate** - 44.1kHz or 48kHz
- **Audio Quality** - Standard/High/Maximum
- **CPU Usage** - Optimize for performance

## 🛠️ Development

### Running Tests
```bash
swift test
```

### Building for Release
```bash
swift build -c release --arch arm64 --arch x86_64
```

### Debugging Audio Issues
```bash
# List audio devices
system_profiler SPAudioDataType

# Check HAL plugin status
ls -la /Library/Audio/Plug-Ins/HAL/

# Restart CoreAudio
sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
```

## 🗺️ Roadmap

- [x] Phase 1: Core Recording Engine
- [x] Phase 2: AI Transcription
- [x] Phase 3: Virtual Audio Device
- [x] Phase 4: UI Polish & Database
- [ ] Phase 5: Cloud Sync (Optional, user-controlled)
- [ ] Phase 6: Advanced Diarization (pyannote-style)
- [ ] Phase 7: Real-time Transcription
- [ ] Phase 8: Mac App Store Release

## 📄 License

Proprietary - All Rights Reserved

## 🤝 Contributing

This is a prototype. For production deployment, additional work needed:
- Code signing for App Store
- Notarization for HAL plugin
- Comprehensive error handling
- Unit test coverage
- Performance profiling

## 💡 Technical Notes

### Why ScreenCaptureKit?
- **Sandbox-safe** - Works in App Store builds
- **High fidelity** - 48kHz lossless audio
- **Low latency** - ~10ms capture delay
- **App filtering** - Target specific processes

### Why WhisperKit?
- **Local inference** - No API costs or privacy concerns
- **Neural Engine** - Offloads CPU, uses ANE efficiently
- **Production-ready** - Optimized CoreML models
- **Multilingual** - 99+ languages supported

### Why HAL Plugin?
- **System-level** - Only way to create virtual device
- **Low latency** - < 20ms roundtrip
- **Universal** - Works across all audio apps
- **Standard** - Uses official CoreAudio APIs

## 📞 Support

For issues or questions about this implementation, create a GitHub issue or contact the development team.

---

**Built with ❤️ using Swift, CoreML, and Core Audio**
