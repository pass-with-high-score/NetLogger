---
name: netlogger-dev
description: Expert guide and domain knowledge for developing, maintaining, and debugging the NetLogger jailbreak tweak project. Use this skill whenever the user asks to modify NetLogger, add features, or fix bugs.
---

# NetLogger Development Guide

This skill provides essential procedural knowledge and architecture overview for maintaining and developing the NetLogger jailbreak tweak.

## Core Architecture

NetLogger is an in-process network interceptor (Tweak) for iOS (specifically Dopamine rootless). It intercepts network requests and responses directly within the target application's process.

### Key Components
1. **Core Hooking (`Tweak.x`)**:
   - Hooks `NSURLSessionConfiguration` to inject `NLURLProtocol`.
   - Hooks C-level SSL/TLS and POSIX socket functions (e.g., `SSLWrite`, `SSLRead`, `send`, `recv`) using `MSHookFunction`.
   - Implements `applyMitmRules`, `applyMitmRequestRules`, `applyMitmResponseRules` to intercept and manipulate JSON/Headers via a **JavaScriptCore Engine** or key-path matching.

2. **Preference Bundle (`netloggerprefs/`)**:
   - iOS Settings app integration using PreferenceLoader.
   - **Important**: Detail Controllers (like `NLBlacklistController`, `NLMitmRulesController`, `NLLogDetailViewController`) **MUST** subclass `PSViewController` (not `UIViewController`), implement `loadView`, and avoid manual view initialization in `viewDidLoad` to prevent `doesNotRecognizeSelector:` SIGABRT crashes in the Settings app.
   - **Localization (i18n)**: Supports English (`en.lproj`) and Vietnamese (`vi.lproj`). Strings are managed via `Localizable.strings` and `Root.strings` and accessed using the `NLLocalizedString` macro in `NLLocalization.h`.

3. **Sileo Depiction (`docs/depictions/com.minh.netlogger.json`)**:
   - Uses Sileo Native Depiction format.
   - `minVersion` must be at least `0.4` to support Screenshots.

## Build and Deployment Workflow

Always use the custom build script instead of manually running `make package`.

```bash
# Clean, compile (with DEBUG=0 FINALPACKAGE=1), package, and update apt repository hashes (MD5, SHA256)
./update_repo.sh
```

**Git Workflow:**
After a successful build, always commit the changes and push to the remote repository (GitHub Pages acts as the APT repository).
```bash
git add .
git commit -m "feat/fix: Description"
git push
```

## Best Practices & Guidelines

### 1. Handling Settings UI (PreferenceLoader)
- **NEVER** subclass `UIViewController` directly for screens launched from `Root.plist` or other preference cells. Always use `<Preferences/PSViewController.h>`.
- **Keyboard Handling**: For screens with text inputs at the bottom (e.g., MitM Rules), always implement `UIKeyboardWillShowNotification` and `UIKeyboardWillHideNotification` to adjust the `tableView.contentInset`.
- **Background Colors**: When highlighting table cells in iOS 13+, restore the color to `[UIColor secondarySystemGroupedBackgroundColor]` instead of `nil` to prevent transparency bugs in grouped tables.

### 2. Floating Debugger Injection
- Avoid injecting UI components during `UIApplicationDidFinishLaunchingNotification` as Scene-based apps (like 1.1.1.1, Locket, iOS 13+) haven't initialized their `UIWindowScene` yet, causing a crash.
- Delay injection until `UIApplicationDidBecomeActiveNotification` or `UISceneDidActivateNotification`.

### 3. JavaScriptCore Engine (MitM)
- The MitM engine uses `JSContext` to evaluate user-provided JavaScript scripts.
- The payload is injected as a global variable named `body` (Object if JSON, String if text).
- Always wrap JS evaluation in try-catch or use `JSContext.exceptionHandler` to prevent user-provided scripts from crashing the host app.

### 4. Localization
- When adding new UI text in `netloggerprefs/`, wrap strings in `NLLocalizedString(@"Key", @"Fallback")`.
- Update both `netloggerprefs/Resources/en.lproj/Localizable.strings` and `netloggerprefs/Resources/vi.lproj/Localizable.strings`.

### 5. Debugging
- Use `NSLog(@"[NetLogger] ...")` for logging in `Tweak.x`. Use the Console app or `oslog` to view them.
- Ensure `DEBUG = 0` and `FINALPACKAGE = 1` are set in the root `Makefile` before releasing to remove debug symbols and reduce `.deb` size.
