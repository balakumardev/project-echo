# Project Echo - Quick Start Guide

## Installation

### Step 1: Build the Application

```bash
cd /Users/balakumar/.gemini/antigravity/playground/drifting-pulsar
./build.sh
```

This will:
- ✅ Resolve Swift package dependencies (WhisperKit, SQLite)
- ✅ Build the main macOS application
- ✅ Compile the HAL plugin (virtual audio device)

### Step 2: Grant Permissions

When you first launch Project Echo, macOS will prompt for:

1. **Screen Recording** - Required to capture system audio
   - Go to: System Settings → Privacy & Security → Screen Recording
   - Enable for "ProjectEcho"

2. **Microphone** - Required to record your voice
   - Go to: System Settings → Privacy & Security → Microphone
   - Enable for "ProjectEcho"

### Step 3: Run the App

```bash
swift run ProjectEcho
```

You should see:
- 🎙️ A waveform icon in your menu bar
- No dock icon (it's a menu bar-only app)

## Basic Usage

### Recording a Meeting

1. **Start Recording**
   - Click the menu bar icon
   - Select "⏺ Start Recording"
   - The icon will change to filled (⏺️)

2. **During Meeting**
   - Everything is recorded automatically
   - To mark important moments: Select "🔖 Mark Moment"

3. **Stop Recording**
   - Click menu bar icon
   - Select "⏹ Stop Recording"
   - Recording is saved automatically

### Viewing Recordings

1. **Open Library**
   - Menu bar → "📚 Open Library"
   - See all your recordings

2. **Play/Review**
   - Click any recording
   - Built-in audio player appears
   - Transcript shows below (auto-generated)

3. **Search**
   - Use search bar at top
   - Full-text search across all transcripts
   - Find keywords instantly

## Advanced Features

### Pro Extension (Virtual Microphone)

Install the HAL plugin for audio injection:

```bash
cd HALPlugin
sudo make install
# Enter your password
```

Then in Zoom/Teams:
1. Go to audio settings
2. Select "Echo Virtual Microphone" as input
3. Now you can inject audio files or TTS

### Settings

**General**
- Auto-transcribe: On/Off (default: On)
- Whisper Model: tiny/base/small/medium
  - `tiny` - Fastest, less accurate
  - `base` - **Recommended** - Good balance
  - `small` - Better quality, slower
  - `medium` - Best quality, very slow

**Storage**
- Default: `~/Documents/ProjectEcho/Recordings/`
- Change to any folder you prefer

**Advanced**
- Sample Rate: 44.1kHz or 48kHz (default: 48kHz)
- Audio Quality: Standard/High/Maximum

## Troubleshooting

### "Permission Denied" Error

**Problem:** App can't record audio

**Solution:**
```bash
# 1. Check current permissions
System Settings → Privacy & Security → Screen Recording
System Settings → Privacy & Security → Microphone

# 2. Remove and re-add if needed
```

### "No Audio Captured"

**Problem:** Recording created but silent

**Solution:**
- Ensure the conferencing app is actively playing audio
- Try "Global Capture" mode (captures everything)
- Check macOS sound settings

### "Transcription Failed"

**Problem:** Transcript not generating

**Solution:**
```bash
# Whisper model download may have failed
# Check console logs:
log stream --predicate 'subsystem == "com.projectecho.app"' --level debug
```

### "HAL Plugin Not Visible"

**Problem:** Virtual mic doesn't show up in Zoom

**Solution:**
```bash
# 1. Verify installation
ls -la /Library/Audio/Plug-Ins/HAL/

# Should show: EchoHAL.driver/

# 2. Restart CoreAudio
sudo launchctl kickstart -k system/com.apple.audio.coreaudiod

# 3. Restart Zoom/Teams
```

## File Locations

**Recordings:**
```
~/Documents/ProjectEcho/Recordings/
  └── Echo_2024-12-31T14-30-00Z.mov
```

**Database:**
```
~/Library/Application Support/ProjectEcho/
  ├── echo.db
  ├── echo.db-shm
  └── echo.db-wal
```

**Whisper Models:**
```
~/Library/Caches/huggingface/
  └── models--argmaxinc--WhisperKit/
```

## Keyboard Shortcuts

| Action | Shortcut |
|--------|----------|
| Start/Stop Recording | `⌘R` (when menu open) |
| Mark Moment | `⌘M` (when menu open) |
| Open Library | `⌘L` (when menu open) |
| Settings | `⌘,` |
| Quit | `⌘Q` |

## Performance Tips

### For Best Transcription Speed

1. **Use `base` model** - Good accuracy, reasonable speed
2. **Close other heavy apps** - Free up Neural Engine
3. **Transcribe shorter segments** - Split long meetings

### For Best Audio Quality

1. **Use 48kHz sample rate** - Industry standard
2. **Select "Maximum" quality** - Lossless AAC
3. **Ensure good microphone** - USB mics recommended

### For Low CPU Usage

1. **Disable auto-transcribe** - Transcribe manually when needed
2. **Use `tiny` model** - Fastest inference
3. **Lower sample rate to 44.1kHz**

## Privacy Notes

✅ **What stays on your device:**
- All audio recordings
- All transcripts
- All metadata

❌ **What never leaves your device:**
- Everything
- Zero cloud uploads
- Zero analytics
- No phone-home

Only exception: If you manually configure a cloud API key for summarization (optional).

## Next Steps

1. **Try a test recording** - Record a 30-second voice memo
2. **Check the transcript** - Verify Whisper is working
3. **Export a recording** - Right-click → Export Audio
4. **Customize settings** - Adjust to your preferences

## Support

For issues:
1. Check logs: `~/Library/Logs/ProjectEcho/`
2. File an issue with error details
3. Include macOS version and settings

---

**Ready to transform your meetings into searchable knowledge! 🚀**
