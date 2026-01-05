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
