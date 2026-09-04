# OpenFly Go for iOS

OpenFly Go is an open-source mobile ground application for low-cost DJI aircraft. This repository
contains the iOS client based on DJI Mobile SDK V4, including live camera operation, MapKit survey
planning, simulator/HIL integration, resumable execution and reconstruction-oriented capture data.

The current public release intentionally excludes VLN, model inference, model distribution and all
native model runtimes. The corresponding UI is not compiled into the public build.

## Verified hardware

| Client | SDK | Physically verified aircraft |
| --- | --- | --- |
| iOS | DJI MSDK 4.16.2 | DJI Mini 2 |

DJI Mini 4 Pro validation belongs to the Android MSDK V5 client. Compatibility is reported per
client and SDK generation rather than inferred from a DJI product list.

## Features

- DJI connection, account state, telemetry, camera, gimbal and flight status;
- live camera preview and photo/video operations;
- MapKit survey editing, route preview, capture scheduling and time estimation;
- resumable execution, manual-takeover detection and DJI return-to-home handoff;
- UE/AirSim HIL transport and DJI Simulator validation;
- capture metadata for reconstruction workflows;
- experimental terrain/DSM planning retained behind a build flag and off by default.

## Requirements

- macOS with Xcode 26 or a compatible newer release;
- XcodeGen and CocoaPods;
- an Apple Developer team for device signing;
- a DJI Developer account and an iOS MSDK V4 App Key for your Bundle Identifier.

## Configuration

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

Configure your own values in the ignored local file:

```xcconfig
OPENFLY_BUNDLE_ID = com.example.openflygo
DJI_SDK_APP_KEY = your_dji_app_key
DEVELOPMENT_TEAM = YOUR_APPLE_TEAM_ID
```

Never commit a production DJI key, Apple certificate private key, `.p12` file or provisioning
material. Official builds inject maintainer credentials in a private signing environment.

## Build and test

The simulator build uses the mock flight provider and does not require the device-only DJI runtime:

```bash
xcodegen generate
xcodebuild -project DJIVLNiOS.xcodeproj -scheme DJIVLNiOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

For a device build, restore CocoaPods and use the workspace:

```bash
xcodegen generate
pod install
xcodebuild -workspace DJIVLNiOS.xcworkspace -scheme DJIVLNiOS \
  -destination 'generic/platform=iOS' build
```

## Feature gates

Terrain planning remains in the source but is **off by default**. The public Release configuration
does not define `OPENFLY_ENABLE_TERRAIN`; importing a mission that requires terrain following fails
closed. In development builds, exposing the terrain UI still leaves its user toggle off initially.

VLN/model-inference feature flags and implementations are not part of this public snapshot.

## Architecture

```text
DJI iOS MSDK V4 ── telemetry / camera / gimbal / control
          │
          ├── SwiftUI flight HUD and MapKit
          ├── survey planner and execution policies
          ├── DJI Simulator / UE HIL bridge
          └── reconstruction-oriented capture metadata
```

## Safety

This is research software, not a replacement for the remote pilot, DJI flight-safety systems,
airspace authorization, site inspection or legal compliance. Keep visual line of sight, maintain a
manual takeover path and validate changes in simulation before any real flight. Unsupported or stale
telemetry must fail closed.

Useful documentation:

- [Simulator validation](docs/SIMULATOR_VALIDATION.md)
- [Real-device checklist](docs/REAL_DEVICE_CHECKLIST.md)
- [Release feature gates](docs/RELEASE_FEATURE_FLAGS.md)

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md) before submitting flight-control
changes. OpenFly Go is licensed under the [Apache License 2.0](LICENSE). Third-party components retain
their own terms; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
