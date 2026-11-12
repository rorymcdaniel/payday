# Payday on Android

Payday’s personal Android app carries over the Mac workflow: paycheck entry, Ready to Assign, optional deposit linking, ordered defaults, temporary adjustments, review, and allocation history. It uses automatic decimal entry: `1` means `0.01`, `100` means `1.00`. It follows your phone’s light/dark appearance and requires fingerprint or screen-lock authentication on opening and after returning from another app.

## Install on your Pixel 7

1. Build with `bash scripts/package-android.sh`, or use the already-built `dist/Payday-android.apk`.
2. Transfer the APK to your phone using a method you already use for files, such as Google Drive or USB. Open it in Files and allow that file source to install apps when Android asks. Install Payday.
3. Open Payday and unlock with your fingerprint or screen lock. You can try **Settings → Try practice mode** before connecting your real budget.

No Play Store account, subscription, backend, or public distribution is required. The app supports Android 13 and later, including Android 17. It is compiled and targeted against API 36 using a pinned toolchain; Android 17 runs it through the platform’s app compatibility support. Keep the app open during an allocation. If Android kills it, History will retain the interruption and require reconciliation.

Future updates should be installed over the existing app. Do not uninstall to update: uninstalling deletes local history. Builds use a private signing key in `~/.local/share/payday/android-signing/`. Keep that folder in a protected backup so future APKs can update the same installation. Signing credentials are never included in the APK or repository.

## Move your Mac data

1. Build the updated Mac app with `bash scripts/package.sh`, then open `dist/Payday.app`.
2. Open **Connection → Export for Android…**. Save `Payday-transfer.json`.
3. Copy that file to your phone. In Android Payday, choose **Settings → Import from Mac** and select it in Android’s file picker.
4. Unlock Payday again when prompted. Review the budget, category count, history count, and export date, then tap **Import data**.
5. In Settings, connect your own YNAB Personal Access Token. The selected budget from the import is retained. Go to Paycheck and refresh before reviewing an allocation.

The transfer includes the selected budget, defaults for all budgets, category order, current draft, and complete allocation history with deposit aliases and reconciliation notes. The token is excluded. The older **Export history** action produces a history-only file and cannot be used for this move.

Import replaces the phone’s current draft and defaults for budgets present in the file. Existing phone history and defaults for other budgets are retained. Repeated imports preserve existing history, including local reconciliation. Conflicting claims are rejected before any write. Interrupted records still block allocation; importing does not resume them. The confirmation happens before a single atomic local transaction. Import and export never send financial changes to YNAB.

Use Android as your main allocation device after the handoff. The apps do not sync, and an old transfer cannot include later allocations on your Mac. Export again before using Android after another Mac allocation. Android can also export a backup using **Settings → Export data backup**; the same import action restores it on Android. Mac import is not implemented. Practice and real files are labeled and cannot be mixed.

## Build and verify

Requires JDK 17, Android SDK platform 36, build-tools 35.0.0, and network access for the first dependency download. The included Gradle wrapper pins Gradle 8.14.2 and verifies its distribution checksum. The packaging script uses the SDK at `$ANDROID_HOME`, defaulting to `~/Library/Android/sdk` on macOS, and finds JDK 17 through `java_home`. It generates a personal signing key once and runs unit tests, release lint, and release assembly before copying the APK to `dist/`.

```sh
bash scripts/package-android.sh
# Optional, with a phone connected and USB debugging enabled:
adb install -r dist/Payday-android.apk

# Development and tests:
cd android
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
./gradlew :app:connectedDebugAndroidTest
```

No test reads real credentials or calls the YNAB service. Core tests use fakes; HTTP contract tests use a local mock server; device tests use only the synthetic practice store. Device tests reset practice data. The shared `fixtures/mac-transfer-v1.json` is checked against Swift’s actual encoding and decoded by Kotlin tests.

## Implementation and boundaries

The Android project uses Kotlin and Jetpack Compose with a pure allocation engine behind `BudgetAPI` and `StateStore`. It ports the Mac’s integer milliunit calculations and durable claim protocol. SQLite uses a full synchronous transaction before each remote write. Only a single launcher Activity owns the app state; activity recreation retains its ViewModel. An engine mutex and UI operation guard prevent concurrent confirms. An HTTP PATCH uses a one-shot request body and a client with connection retries and redirects disabled, including protection against HTTP 503 retry follow-ups. Lost responses stay uncertain.

Real and practice databases are separate in Android app-private storage. The token is AES-GCM encrypted using a non-exportable Android Keystore key usable only while the device is unlocked. App content is gated by Android’s biometric/device credential prompt and hidden from screenshots and recent-app previews. Automatic cloud backup and device transfer are disabled to avoid silently restoring stale allocation history. Transfer files are plain JSON containing financial information and should be stored privately. No broad file permission is requested; Android’s document picker grants access only to chosen files.

The local journal is not separately encrypted; Android’s app sandbox and device encryption protect it. The unlock screen is an application access control, not per-operation cryptographic authentication. Rooted/compromised devices, deleted history, stale exports, assignments made elsewhere, and simultaneous YNAB edits remain outside duplicate/race guarantees. An imported or manually typed draft never proves the paycheck has not already been assigned on another device.

Official references checked during implementation: [Android biometric/device credential authentication](https://developer.android.com/identity/sign-in/biometric-auth), [Android 17 SDK](https://developer.android.com/about/versions/17/setup-sdk), [AGP 8.13 compatibility](https://developer.android.com/build/releases/agp-8-13-0-release-notes), and [YNAB API](https://api.ynab.com/).

## Verification on 2026-10-15

- 60 Swift tests passed, including export round-trip, synthetic cross-platform fixture equivalence, cancellation, busy-state protection, write failure, and private file permissions. Warning-clean build and Mac packaging passed. Financial core line coverage: 93.60%; allocation engine: 99.08%; changed measured lines: 100%.
- 24 Android JVM tests passed, covering integer precision, default synchronization, duplicate/deposit identities, compatible transfer merge, malformed imports, preflight checks, concurrent confirmation, local commit failures, lost/mismatched responses, final verification, and HTTP no-retry behavior.
- Four device tests passed on an Android 17 (API 37) ARM64 emulator at 1080 × 2400, 420 dpi, covering the full practice workflow, import preview/cancel/confirmation, durable SQLite reopening/corruption, and token encryption/tampering. The workflow also passed on Android 16 before the Android 17 run.
- The signed release APK was installed and opened on Android 17. Device PIN authentication succeeded; switching to Android Settings and returning displayed the authentication prompt again. Fingerprint hardware remains a physical-device check.
- Light and dark practice screens were captured and inspected. See [light screenshot](screenshots/android-paycheck-light.png) and [dark screenshot](screenshots/android-paycheck-dark.png). These contain synthetic data only.
- Release lint and APK signing verification passed. Lint retains informational dependency-update/style suggestions; no lint errors are suppressed.

The app was installed on the physical Pixel 7; the owner confirmed fingerprint authentication and loading budgets with their API token. A real YNAB write has not been exercised. All automated financial testing uses synthetic data. Keep the same signing key for future builds and install updates over the existing app.

### Android 1.0.1 document-picker fix

The original authentication gate removed Compose’s activity-result registrations when the system file picker stopped Payday. Returning from the picker and unlocking recreated those registrations with new keys, losing the selected document. Registrations now remain mounted outside the authentication gate. Pending document URIs survive saved-state restoration, and file access waits until Payday is unlocked and idle. Import still requires preview confirmation before changing saved data.

The regression test reproduced the missing preview twice before the fix. All nine device tests passed on an isolated API 36 emulator after the fix, including results arriving before/after unlock, picker cancellation, pending import saved-state restoration, and export waiting for unlock. All 24 JVM tests, release lint, and APK signature verification passed. The update uses the existing personal signing key and preserves installed app data.
