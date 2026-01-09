# Engram - Development Guidelines

Engram is a macOS meeting recorder and AI assistant by Bala Kumar.
https://balakumar.dev

## Building the App

**Never run the app yourself.** Always let the user run it manually.

To build, use the build script:
```bash
./scripts/build_app.sh
```

This script:
1. Kills any running instance
2. Removes old `Engram.app`
3. Builds in debug mode (`swift build`)
4. Creates the app bundle
5. Signs with `Engram Development` certificate

The user will run the app themselves after building.

## Code Signing

The app uses a self-signed `Engram Development` certificate for stable code signing. This preserves macOS TCC permissions (microphone, screen recording) across rebuilds.

If the certificate doesn't exist, create it:
```bash
./scripts/create_signing_cert.sh
```

## Scripts

- `scripts/build_app.sh` - Build and sign the app bundle (don't launch)
- `scripts/create_signing_cert.sh` - Create the signing certificate (one-time setup)

## Log Files

The app writes to multiple log files for debugging:

| Log File | Location | Purpose |
|----------|----------|---------|
| Debug Log | `~/engram_debug.log` | Meeting detection, app lifecycle, recording events |
| RAG Log | `~/engram_rag.log` | AI/RAG operations, summarization, agent queries, model loading |
| Error Log | `~/Library/Application Support/Engram/Logs/engram_errors.log` | Crashes, errors, warnings (via CrashLogger) |

### Viewing Logs

```bash
# Debug log (meeting detection, recording)
tail -f ~/engram_debug.log

# RAG/AI log (summarization, transcription agent)
tail -f ~/engram_rag.log

# Error log
tail -f ~/Library/Application\ Support/Engram/Logs/engram_errors.log
```

### Key Log Patterns

- `[AIService]` - Model loading, auto-unload, initialization
- `[Agent]` - TranscriptAgent query processing, strategy selection
- `[AgentChat]` - RAG pipeline chat responses
- `[Init]` - RAG pipeline initialization, document indexing
- `checkForActiveMeetingApps` - Meeting detection status
