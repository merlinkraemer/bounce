# Bounce

Instructions for coding agents and contributors working in this repo.

## Layout

- Mac app: `apps/BounceSender/` (macOS 26)
- iPhone app: `apps/BounceReceiver/` (iOS 18)
- Shared models: `apps/BounceKit/` (Swift package: Track, Version, Note)
- Scripts: `scripts/` (`npm run gen:projects`, `run:mac`, `run:ios`, `install:*`)
- Build and run steps: [BUILDING.md](BUILDING.md)

## Architecture

- Two SwiftUI apps. iOS deployment target is 18.0. Mac deployment target is 26.0.
- Models live in the local BounceKit package.
- `AudioPlayer` is `@Observable`, injected via `@Environment`.
- `DownloadManager` handles Bonjour sync from the Mac.
- No third-party dependencies.

## Sync lanes

Dev and production builds must stay isolated. Never pair a dev app with a production app.

- Production: bundle IDs `com.merlinkraemer.bounce.sender` and `.receiver`, Bonjour `_bounce-sync._tcp`, keychain `com.bounce.pairingKey`, Mac data in `~/Library/Application Support/Bounce`. Scripts: `npm run install:mac`, `npm run install:ios`.
- Dev: same bundle IDs with a `.dev` suffix, product name `Bounce Dev`, Bonjour `_bounce-dev._tcp`, keychain `com.bounce.dev.pairingKey`, data in `~/Library/Application Support/Bounce Dev`. Scripts: `npm run run:mac`, `npm run run:ios`.
- `BounceConstants.isDevelopmentBuild` derives the lane from the `.dev` bundle ID suffix.
- `npm run run:ios` installs over the dev app to preserve its data; do not add uninstall-before-install.
- `npm run install:mac` keeps pairing and sync state by default. Reset only with `--reset` or `--reset-pairing`.
- If pairing, bundle IDs, Bonjour services, keychain services or data paths change, update this section and BUILDING.md.

## Swift conventions

- Use `@Observable`, not `ObservableObject` or `StateObject`.
- Use `@Environment(AudioPlayer.self)` for audio.
- Use `@Query` for SwiftData fetches.
- Prefer `foregroundStyle` over `foregroundColor`.
- Prefer `.sheet(item:)` over `.sheet(isPresented:)`.

## SwiftUI rules

- Spacing on a 4/8 grid: 4, 8, 12, 16, 20, 24, 32, 40, 48.
- At most 5 font sizes; differentiate with weight. One font design.
- Use semantic colors. Avoid many hardcoded opacity values (use 2 or 3 with clear purposes).
- Cards: secondary background, 10pt corner radius, no custom gradients.
- Use `NavigationStack`, not manual titles in a `ZStack`.
- Default to MV, not MVVM: `@State`, `@Environment`, `@Query`, `.task`, `onChange` before view models. Inject services via `@Environment`.
- View file order: environment, `let` properties, `@State`, computed vars, `init`, `body`, view helpers, async helpers.
- Prefer dedicated subview structs over computed `some View` helpers. Keep button actions and logic out of `body`.
- Watch for invalidation storms, unstable `ForEach` identity, heavy work in `body`, and main-thread image decoding.

## Checks

- `swift test` in `apps/BounceKit`.
- Both apps build after `npm run gen:projects`.
- Keep changes small. Do not add dependencies.
