# Building Bounce

## Requirements

- Xcode 26
- macOS 26 to build and run the Mac app (deployment target 26.0)
- iOS 18 or later on the device or simulator (deployment target 18.0)
- [xcodegen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Node.js, only to run the `npm run` shortcuts. The scripts in `scripts/` also run directly.

No third-party Swift dependencies.

## Generate the Xcode projects

```sh
npm run gen:projects
```

This runs xcodegen for `apps/BounceSender` (Mac) and `apps/BounceReceiver` (iPhone). Both import the shared package in `apps/BounceKit`.

## Run the apps

Mac (dev build, installs to `/Applications/Bounce Dev.app`, unsigned, no team needed):

```sh
npm run run:mac
```

iPhone (dev build, installs on a connected device or the simulator):

```sh
BOUNCE_DEVELOPMENT_TEAM=<your team id> npm run run:ios
```

Optional: `BOUNCE_IOS_DEVICE_UDID` picks a specific device.

## Dev and production lanes

Dev builds and production builds are fully separate, so a dev build never pairs with or overwrites the released app.

| | Production | Dev |
| --- | --- | --- |
| Mac bundle ID | `com.merlinkraemer.bounce.sender` | `com.merlinkraemer.bounce.sender.dev` |
| iPhone bundle ID | `com.merlinkraemer.bounce.receiver` | `com.merlinkraemer.bounce.receiver.dev` |
| Product name | Bounce | Bounce Dev |
| Bonjour service | `_bounce-sync._tcp` | `_bounce-dev._tcp` |
| Keychain service | `com.bounce.pairingKey` | `com.bounce.dev.pairingKey` |
| Mac data directory | `~/Library/Application Support/Bounce` | `~/Library/Application Support/Bounce Dev` |

The app decides the lane from a `.dev` suffix on its bundle ID.

## Forks

You cannot sign the `com.merlinkraemer.*` bundle IDs. Use your own:

```sh
export BOUNCE_DEVELOPMENT_TEAM=<your team id>
export BOUNCE_IOS_BUNDLE_ID=<your.id>.dev
npm run run:ios
```

Keep the `.dev` suffix. Without it the app treats the build as production and uses the production Bonjour service and keychain item. For the Mac app, `BOUNCE_MAC_BUNDLE_ID` works the same way (also ending in `.dev`).

The `install:*` scripts (`npm run install:mac`, `npm run install:ios`, `npm run install:apps`) build the production lane. Use them only if you are producing your own production build with your own signing setup. For day-to-day work use `run:*`.

## Tests

Shared models and logic:

```sh
cd apps/BounceKit
swift test
```

## Test audio

`npm run gen:test-audio` generates sample audio files for trying out sync and playback.
