# NetLogger

A jailbreak tweak for iOS 15+ (Dopamine rootless) that intercepts and logs network requests from user-selected apps, viewable directly inside the Settings app.

## Features

- Hooks `NSURLSession` to capture outgoing HTTP/HTTPS requests from any app
- Per-app opt-in — only monitors apps you explicitly select
- Logs method, URL, HTTP status code, app bundle ID, timestamp, and response body
- Built-in log viewer inside Settings with Refresh and Clear actions
- Zero performance overhead on apps not in the selected list

## Requirements

- iOS 15.0+ (tested on iOS 16 Dopamine rootless)
- [Dopamine](https://github.com/opa334/Dopamine) or any rootless jailbreak
- [AltList](https://github.com/opa334/AltList) — for the app selection UI in Settings

## Installation

### Build from source

1. Install [Theos](https://theos.dev/docs/installation)

2. Clone this repo and enter the project directory:
   ```bash
   git clone <repo-url>
   cd NetLogger
   ```

3. Build and install to your device:
   ```bash
   make package install
   ```

> **Note:** AltList must be installed on the device (available via Sileo/Zebra). No compile-time linking is required — the dependency is resolved at runtime.

## Usage

1. Open **Settings → NetLogger**
2. Toggle **Enable NetLogger** on
3. Tap **Select Apps to Monitor** and choose the apps you want to intercept
4. Use the selected app normally — network requests are captured in the background
5. Return to **Settings → NetLogger → View Network Logs** to inspect captured traffic

Each log entry contains:
```
[2024-01-15 14:32:01] POST https://api.example.com/login
Status: 200
App: com.example.app
Response:
{"token":"eyJ...","user":{"id":42}}
---
```

Response bodies larger than 8 KB or binary data are recorded as `(no body / binary)`.

## Project Structure

```
NetLogger/
├── Tweak.x                         # NSURLSession hook + log writer
├── Makefile                        # Root build file (rootless, arm64/arm64e)
├── control                         # Package metadata + AltList dependency
├── NetLogger.plist                 # Substrate bundle filter (com.apple.UIKit)
├── layout/
│   └── Library/PreferenceLoader/
│       └── Preferences/
│           └── NetLogger/
│               └── Preferences.plist   # Settings entry point
└── netloggerprefs/                 # Preference bundle subproject
    ├── Makefile
    ├── NetLoggerPreferences.mm     # Main settings + log viewer controllers
    └── Resources/
        ├── Info.plist
        └── Root.plist              # Settings UI layout (AltList + log link)
```

## Log File Location

```
/var/mobile/Library/Preferences/com.minh.netlogger.logs.txt
```

This file is readable by both the hooked app processes and the Settings (Preferences) process, making it the safe shared storage path on rootless jailbreaks.

## How It Works

```
Target App Process
  └── NSURLSession hook (Tweak.x)
        ├── isAppEnabled() → reads com.minh.netlogger.plist
        │     checks: enabled=YES AND bundleID in selectedApps
        └── on match → writeLog() appends to .logs.txt

Settings Process (netloggerprefs bundle)
  └── NetLoggerLogViewerController
        └── reads .logs.txt on viewWillAppear
```

## License

MIT
