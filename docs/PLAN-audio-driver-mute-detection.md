# Implementation Plan: Full-Volume Audio Capture & Mic Mute Detection

## Research Summary

### Key Finding: Driver-Level IO Monitoring Works

**Initial concern:** Apps might keep reading mic when muted (for "you're talking while muted" features).

**Research confirmed:** We can detect mute at the driver level by monitoring IOProc activity:
- When app mutes → stops calling IOProc (stops reading samples)
- No IO activity for >200ms → muted
- User unmutes → IO activity resumes → unmuted

This is how Krisp detects mute state - same principle.

### Single Driver Solves Both Features

| Feature | Solution |
|---------|----------|
| System audio at full volume | Virtual output device (forked BlackHole) |
| Mic mute detection | Driver-level IO monitoring (same driver) |

**No AppleScript/Accessibility needed.** One driver, one permission.

---

## Architecture Overview

### Current State
```
System Audio → Volume Control → ScreenCaptureKit (captures quiet/muted audio)
Real Mic → AVCaptureSession → Recording (no mute awareness)
```

### Target State
```
System Audio → Engram Virtual Output → Our capture (full volume)
                      ↓
                Also → User's speakers (normal playback)

Real Mic → Engram Virtual Mic → Meeting App (Zoom/Teams/etc)
                ↓
         We capture here + monitor IO activity
         No IO calls = app muted → pause mic track
```

---

## Implementation Plan

### Phase 1: BlackHole Integration (System Audio at Full Volume)

**Goal:** Capture system audio before volume controls are applied.

#### 1.1 Bundle BlackHole Driver

**Files to add:**
- `Resources/Drivers/BlackHole2ch.driver/` - Bundled driver
- `Sources/AudioEngine/AudioDriverInstaller.swift` - Installation logic

**User flow:**
1. First launch: Prompt "Engram needs to install an audio driver for high-quality recording"
2. User approves System Extension in System Settings (one-time)
3. Driver installed, no further prompts

**Permissions required:**
- System Extension approval (one-time, in System Settings > Privacy & Security)
- No additional entitlements needed

#### 1.2 Menubar Device Selector UI

**Why needed:** User selects BlackHole as their meeting app's mic/speaker. They need to pick which ACTUAL device they hear audio from.

**New file:** `Sources/UI/AudioDeviceSelector.swift`

**Features:**
- Dropdown showing available output devices (speakers, Bluetooth headphones, etc.)
- Dropdown showing available input devices (built-in mic, external mic, etc.)
- Auto-detect when devices connect/disconnect (Bluetooth headphones)
- Show current routing status

**User flow:**
1. User connects Bluetooth headphones
2. Opens Engram menubar → Audio Devices
3. Selects "AirPods Pro" as output
4. Audio now routes: Meeting → BlackHole → Engram capture → AirPods

**CoreAudio APIs:**
```swift
// Listen for device changes
AudioObjectAddPropertyListener(
    kAudioObjectSystemObject,
    kAudioHardwarePropertyDevices,
    deviceChangeCallback
)

// Get device list
kAudioHardwarePropertyDevices
kAudioDevicePropertyDeviceName
```

#### 1.3 Create Multi-Output Device

**File to modify:** `Sources/AudioEngine/AudioCaptureEngine.swift`

**Approach:**
1. Programmatically create an Aggregate Device combining:
   - BlackHole (for capture)
   - User's actual output device (for playback)
2. Set as system default output (or per-app)
3. Capture from BlackHole input

```swift
// CoreAudio APIs needed:
AudioHardwareCreateAggregateDevice()  // Create multi-output
kAudioAggregateDevicePropertyFullSubDeviceList
kAudioAggregateDevicePropertyMasterSubDevice
```

#### 1.4 Modify Capture Pipeline

**File:** `Sources/AudioEngine/AudioCaptureEngine.swift`

**Changes:**
- Add `BlackHoleCapture` class using CoreAudio HAL APIs
- Replace ScreenCaptureKit for system audio (keep for video if needed)
- Capture from BlackHole device at full volume

**Key code path:**
```swift
// Instead of SCStream for audio:
let blackholeDeviceID = findBlackHoleDevice()
let audioUnit = createInputAudioUnit(device: blackholeDeviceID)
// Capture directly from BlackHole - bypasses system volume
```

---

### Phase 2: Mic Mute Detection

**Goal:** Detect when user mutes in meeting apps, pause mic recording.

#### 2.0 Driver-Level IO Monitoring (Reliable Detection)

**Key insight:** When user mutes in a meeting app, the app stops calling IOProc (stops reading audio samples from our virtual mic). We detect this directly in the driver.

**CoreAudio APIs available:**
| API | Purpose |
|-----|---------|
| `AddDeviceClient`/`RemoveDeviceClient` | Track which apps are connected |
| `kAudioDevicePropertyDeviceIsRunning` | Check if client has active IO proc |
| `WillDoIOOperation` with `mProcessID` | Monitor per-client read activity |

**Implementation in virtual mic driver:**
```swift
// Track active clients and their last IO timestamp
var clientActivity: [pid_t: ClientState] = [:]

struct ClientState {
    let processID: pid_t
    let bundleID: String?
    var lastIOTime: CFAbsoluteTime
    var isMuted: Bool { CFAbsoluteTimeGetCurrent() - lastIOTime > 0.2 }
}

// Called by CoreAudio each IO cycle
func willDoIOOperation(clientInfo: AudioServerPlugInIOCycleInfo, operation: UInt32) {
    let pid = clientInfo.mProcessID
    clientActivity[pid]?.lastIOTime = CFAbsoluteTimeGetCurrent()
}

// Called when client connects
func addDeviceClient(clientInfo: AudioServerPlugInClientInfo) {
    clientActivity[clientInfo.mProcessID] = ClientState(
        processID: clientInfo.mProcessID,
        bundleID: getBundleID(pid: clientInfo.mProcessID),
        lastIOTime: CFAbsoluteTimeGetCurrent()
    )
}

// Query mute state
func isMuted(pid: pid_t) -> Bool {
    return clientActivity[pid]?.isMuted ?? true
}
```

**Why this works:**
1. App mutes → stops reading from our virtual mic
2. No IOProc calls for >200ms → we detect mute
3. User unmutes → IOProc calls resume → we detect unmute

**Pros:**
- No extra permissions needed (driver already approved)
- Works for ALL apps using our virtual mic
- No false positives (directly measures IO activity, not audio levels)
- Per-process tracking (know exactly which app is muted)

**Cons:**
- Requires building/forking our own audio driver (can't use stock BlackHole)
- Small delay (200ms) to detect mute state change

#### 2.1 Integration with Recording

**File to modify:** `Sources/AudioEngine/AudioCaptureEngine.swift`

**Changes:**
- Add `muteStateChanged(isMuted: Bool)` method
- When muted: Stop writing to mic track (or write silence)
- When unmuted: Resume writing

**Option A - Pause track:**
```swift
func muteStateChanged(isMuted: Bool) {
    microphonePaused = isMuted
    // In write loop: skip mic samples when paused
}
```

**Option B - Write silence:**
```swift
func muteStateChanged(isMuted: Bool) {
    if isMuted {
        // Write zero samples to maintain timeline sync
    }
}
```

---

## Files to Create/Modify

### New Files
| File | Purpose |
|------|---------|
| `EngramAudioDriver/` | Forked BlackHole with IO monitoring (separate Xcode project) |
| `Sources/AudioEngine/AudioDriverInstaller.swift` | Driver installation logic |
| `Sources/AudioEngine/EngramAudioCapture.swift` | CoreAudio capture from our driver |
| `Sources/AudioEngine/AggregateDeviceManager.swift` | Create/manage multi-output device |
| `Sources/AudioEngine/DriverMuteMonitor.swift` | Query driver for per-app mute state (via XPC or property) |
| `Sources/UI/AudioDeviceSelector.swift` | Menubar UI for device selection |

### Modified Files
| File | Changes |
|------|---------|
| `Sources/AudioEngine/AudioCaptureEngine.swift` | Use Engram driver for system audio, integrate mute state |
| `Sources/App/MeetingDetector.swift` | Query driver for mute state |
| `Sources/UI/MenuBarController.swift` | Add device selector submenu |
| `project.yml` | Add driver resources, new source files |

---

## Permissions Summary

| Permission | When Requested | User Action |
|------------|----------------|-------------|
| System Extension | First launch | Approve in System Settings (one-time) |

**That's it!** No Accessibility permission needed. The driver handles mute detection directly.

---

## Developer Setup: System Extension Entitlement

**Required:** Apple Developer account with System Extension capability.

### Step 1: Request System Extension Entitlement

1. Go to [developer.apple.com/contact/request/system-extension](https://developer.apple.com/contact/request/system-extension/)
2. Fill out the form:
   - **Extension Type:** Audio (DriverKit)
   - **Use Case:** Virtual audio device for meeting recording
3. Apple typically approves within 1-2 business days

### Step 2: Create Provisioning Profile

1. In Apple Developer Portal → Certificates, Identifiers & Profiles
2. Create new App ID for the driver (e.g., `dev.balakumar.engram.driver`)
3. Enable "System Extension" capability
4. Create provisioning profile with System Extension entitlement

### Step 3: Configure Xcode Project

Driver's `Info.plist`:
```xml
<key>com.apple.developer.system-extension.install</key>
<true/>
<key>com.apple.developer.driverkit</key>
<true/>
<key>com.apple.developer.driverkit.transport.usb</key>
<false/>
```

Driver's entitlements:
```xml
<key>com.apple.developer.driverkit</key>
<true/>
<key>com.apple.developer.driverkit.family.audio</key>
<true/>
```

### Step 4: Notarization

```bash
# Build driver
xcodebuild -project EngramAudioDriver.xcodeproj -scheme EngramAudioDriver archive

# Create zip for notarization
ditto -c -k --keepParent EngramAudioDriver.dext EngramAudioDriver.zip

# Submit for notarization
xcrun notarytool submit EngramAudioDriver.zip --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID --password @keychain:AC_PASSWORD --wait

# Staple the ticket
xcrun stapler staple EngramAudioDriver.dext
```

### Development Note

During development, you can disable SIP to load unsigned drivers:
```bash
# In Recovery Mode (hold Cmd+R on boot):
csrutil disable
# Reboot normally, then:
systemextensionsctl developer on
```

**⚠️ Re-enable SIP before distribution testing.**

---

## Verification Plan

### Phase 1 Testing (Audio Capture)
1. Install driver, verify System Extension approval flow
2. Play audio with system volume at 50%, verify recording is full volume
3. Mute system, verify recording still captures audio
4. Test with Bluetooth headphones - verify no audio routing issues
5. Test aggregate device doesn't affect user's normal audio playback

### Phase 2 Testing (Mute Detection via Driver)
1. Zoom: Start meeting, mute/unmute, verify driver detects IO stop/start
2. Teams: Same test
3. Google Meet (browser): Same test
4. Verify mic track pauses/resumes correctly in recording
5. Test edge cases: rapid mute/unmute, app crash while muted

---

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Driver development complexity | Fork BlackHole (well-tested base), add minimal changes |
| macOS updates break driver | Test on betas, maintain compatibility layer |
| User denies System Extension | Show clear explanation, app works without (uses ScreenCaptureKit fallback, no mute detection) |
| Some apps don't stop IO when muted | Rare edge case - can add AppleScript fallback for specific apps if needed |
| Notarization requirements | Apply for proper entitlements, follow Apple's system extension guidelines |

---

## Implementation Order

1. **Fork BlackHole + add IO monitoring** (core infrastructure)
   - Fork BlackHole source (MIT license, open source)
   - Add `AddDeviceClient`/`RemoveDeviceClient` tracking
   - Add `WillDoIOOperation` per-client activity monitoring
   - Expose mute state via custom property or XPC
2. **Device selector UI + aggregate device**
   - Menubar device picker
   - Programmatic aggregate device creation
3. **Integrate mute detection with recording**
   - Query driver for per-app mute state
   - Pause mic track when muted

## User Setup Flow (Final UX)

1. **First launch:** "Engram needs to install an audio driver" → User approves System Extension
2. **In meeting app (Zoom/Teams/Meet):**
   - Set microphone to "Engram Mic" (our virtual mic)
   - Set speaker to "Engram Speaker" (our virtual output)
3. **In Engram menubar:**
   - Select actual output device (AirPods, speakers, etc.)
   - Select actual input device (built-in mic, external mic, etc.)
4. **During meeting:**
   - Audio captured at full volume regardless of system volume
   - Mic mute detected via driver IO monitoring
   - Muted periods excluded from transcription
