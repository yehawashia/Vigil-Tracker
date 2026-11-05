# Vigil for iPhone and iPad

One universal app (iPhone tab bar, iPad sidebar) that pairs with Vigil on your Mac.
Its screens and sync engine live in `Sources/VigilMobile` (shared Swift package, type-checked on
macOS with `swift build`); this folder holds only the iOS-specific parts.

| Folder | What |
|---|---|
| `App/` | App entry, camera QR scanner, Screen Time blocking + app groups, shared usage store |
| `Monitor/` | Screen Time monitor extension: records app-group time in 15-minute steps, lifts shields when a focus window ends |
| `SafariExtension/` | Safari Web Extension: time per website (domain only) |

## Run it on your own devices (free Apple ID)

1. Install **Xcode** from the Mac App Store and open it once.
2. Install **XcodeGen** (generates the Xcode project from `project-free.yml`).
3. In `project-free.yml`, change `com.CHANGE-ME.vigil` to something unique, e.g. `com.yourname.vigil`.
4. `cd iOS && xcodegen --spec project-free.yml && open Vigil.xcodeproj`
5. In Xcode: select the **VigiliOS** target → *Signing & Capabilities* → Team: your Apple ID (Personal Team).
6. Plug in your iPhone or iPad, pick it as the run destination, press **Run**. On the device, trust the
   developer in *Settings → General → VPN & Device Management*.
7. On the Mac: Vigil → **Devices** → **Start pairing**, then scan the code from the app.

Free installs stop opening after 7 days; press Run again to renew.

## Full build (paid Apple Developer account)

Adds Screen Time blocking during focus sessions and time blocks, app-group time, and the Safari
extension. Use `project.yml` instead, change the bundle prefix **and** the App Group
(`group.dev.vigil.mobile` in `project.yml`, `App/SharedUsage.swift`, `Monitor/UsageMonitor.swift`,
`SafariExtension/SafariWebExtensionHandler.swift`), and enable *Family Controls* for your team.

## Privacy

- Talks only to the paired Mac over the local network (TLS with a per-device key). No internet.
- The pairing key is in the Keychain (this device only, never synced to iCloud).
- Safari: only the site's domain and seconds. Screen Time: only "group X reached N minutes";
  Apple never tells Vigil which apps.
