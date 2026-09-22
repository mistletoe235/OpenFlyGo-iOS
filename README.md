# OpenFly Go for iOS

> [!WARNING]
> **Flight safety — read before flying**
>
> This is a research and development tool, not a flight-safety guarantee. **Passing simulation does not establish real-flight safety. Automated routes and obstacle avoidance do not replace site inspection or pilot supervision.**
>
> - **Simulate before every flight:** rehearse the planned route, capture, pause/resume and completion in the App's built-in simulator. If simulation is unavailable or fails to start, do not substitute a real flight for validation.
> - **Use HIL where supported:** connect the real flight controller to UE to inspect simulated telemetry, heading, altitude and control responses. Remove propellers, secure the aircraft and verify that DJI Simulator is active; an HIL connection alone is not sufficient. See the [HIL guide](docs/HIL_QUICKSTART.md).
> - **Check clearance and signals:** inspect buildings, trees, wires, transit and return paths. Height relative to takeoff is not clearance above terrain or rooftops. Check positioning, control/video links, failsafe behavior and return-to-home settings.
> - **Enable available obstacle avoidance; do not use Sport/S mode.** Not all consumer aircraft have omnidirectional sensing. Verify active sensing directions and limitations, use the supported normal positioning mode and maintain safe clearance.
> - **Recheck before real flight:** exit simulation, restore the real camera and verify takeoff/home positions, route, battery and weather. Maintain pilot supervision and readiness to pause or take over; follow local flight rules.

> Quick links: [Client selection](#client-selection-and-aircraft-support) · [HIL](docs/HIL_QUICKSTART.md) · [Cloud workflow](docs/CLOUD_ROUTE_WORKFLOW.md)
>
> [Project home](https://github.com/mistletoe235/OpenFlyScan) · [English](README.md) · [Chinese reference](README.zh-CN.md)


OpenFly Go is an open-source mobile ground application for low-cost DJI aircraft. This repository
contains the iOS client based on DJI Mobile SDK V4, including live camera operation, MapKit survey
planning, simulator/HIL integration, resumable execution and reconstruction-oriented capture data.

The current public release intentionally excludes VLN, model inference, model distribution and all
native model runtimes. The corresponding UI is not compiled into the public build.

## Client selection and aircraft support

Reviewed September 21, 2026. **V4 and V5 are different DJI SDK product lines,
not older and newer versions of one app. Mini 2 cannot gain V5 features by
installing the V5 client.** Check the exact build as well as the platform.

| Client | Pinned SDK | Project reference aircraft | Map | Mission schemas | Cloud uploads | Cloud results |
| --- | --- | --- | --- | --- | --- | --- |
| Android V4 | MSDK 4.16.4 | **DJI Mini 2** | Baidu Maps | 1–14 | Trigger frames and historical photos | Supported |
| Android V5 | MSDK 5.18.0 | **DJI Mini 4 Pro** | Baidu Maps | 1–14 | Trigger frames and historical photos | Supported |
| iOS | MSDK 4.16.2 | **DJI Mini 2** | MapKit | 1–14 | Trigger frames and historical photos; updated build required | Supported |

Reference aircraft have project hardware-use records; this does not mean every
release has repeated all flight acceptance tests. SDK connectivity and a camera
profile entry do not establish verified camera, gimbal, control, survey or
simulator support for a particular aircraft.

### Official DJI support references

- [MSDK supported products and platforms](https://developer.dji.com/mobile-sdk/)
- [MSDK V5 supported products](https://github.com/dji-sdk/Mobile-SDK-Android-V5#what-is-dji-mobile-sdk-v5)
- [MSDK V4 product support](https://developer.dji.com/mobile-sdk/documentation/introduction/product_introduction.html#supported-products)
- [Android V4 4.16.4 release](https://github.com/dji-sdk/Mobile-SDK-Android/tree/V4.16.4)
- [iOS V4 4.16.2 release](https://github.com/dji-sdk/Mobile-SDK-iOS/tree/v4.16.2)

Official pages change, and older V4 pages may omit later additions. Check the
pinned SDK, Android/iOS platform, aircraft firmware and remote controller together.

| Aircraft / product family | Client selection | Project support boundary |
| --- | --- | --- |
| Mini 2 | Android V4 or iOS | Project hardware-use record; preflight is still required for the installed firmware |
| Mini 4 Pro | Android V5 | Project hardware-use record; not supported by this iOS client |
| Mini 3 / Mini 3 Pro | Listed by DJI for V5; use Android V5 for compatibility testing | Full project workflow not yet hardware-validated |
| Mavic 3 Enterprise, Mavic 3TA, Matrice 30 / 300 RTK / 350 RTK / 400, Matrice 4 / 4D Enterprise | Check the V5 product list and firmware requirements | Enterprise payloads, multiple cameras and all survey functions are not guaranteed; Mavic 3 Enterprise is not the consumer Mavic 3 |
| Mavic Pro / Mavic Air, Mavic 2 Pro / Zoom / Enterprise, Spark, Phantom, Inspire, earlier Matrice products | Check the exact V4 model and platform | SDK candidates, not individually accepted by this project |
| Mavic Mini, Mini SE, Mavic Air 2, Air 2S and other V4 products | Check the matching Android/iOS SDK release | Android support does not imply iOS support; not listed as project-validated aircraft |
| Avata / Avata 2, Neo / Neo 2 and other unadapted products | Outside project support | No bypass integration; installing an app or receiving video does not establish control support |

Use an SDK-supported remote controller with a USB data connection to the phone.
The V5 source excludes RC2 bypass/video compatibility experiments. Installing an
APK on a controller is not sufficient. Listed gimbals or payloads such as H30
are not separate aircraft models.

### Platform and build differences

- All three clients provide survey planning, preview, preflight, pause/resume and HIL; hardware APIs remain model-dependent.
- V5 supports DJI WPMZ/KMZ execution. V4/iOS Mini 2 missions use app-side control: **keep the app in the foreground and connected**, rather than treating them as offline onboard missions.
- Default reacquisition uses stable stop-and-capture points (schema 13). All three clients support experimental schema 14: V4/iOS use Virtual Stick and V5 uses DJI KMZ. Only eligible intermediate capture points pass continuously; boundaries and turns may still stop. V4/iOS require the September 22, 2026 adaptation or a later compatible build. This is not merely relaxed version parsing or a new real-flight acceptance claim.
- The source excludes MNN, VLN, model downloads and private inference runtimes. Cloud routes and point clouds do not depend on them.
- Android retains experimental terrain following, disabled by default. iOS Release rejects missions with `terrainPlan`.
- Debug is for development; Release is a build configuration, not an all-aircraft acceptance label. Supply your own keys/signing for local builds. Maintainer installation packages use private signing; different signatures cannot overwrite one another. Do not erase app data merely to switch packages.

See the [schema 14 implementation and validation notes](docs/SCHEMA14_CONTINUOUS_RECAPTURE_2026-09-22.md).

## Features

- DJI connection, account state, telemetry, camera, gimbal and flight status;
- live camera preview and photo/video operations;
- MapKit survey editing, route preview, capture scheduling and time estimation;
- resumable execution, manual-takeover detection and DJI return-to-home handoff;
- UE/AirSim HIL transport and DJI Simulator validation;
- capture metadata for reconstruction workflows;
- remote V86 point-cloud viewing and cloud mission download/import, without model inference;
- experimental terrain/DSM planning retained behind a build flag and off by default.

## Basic workflow: connect, survey, reconstruct and reacquire

1. **Connect:** attach the iPhone to a supported controller with a data cable and grant the required permissions. Verify SDK registration, aircraft/camera identity, fresh telemetry and video. Local builds require a DJI key matching the Bundle ID and valid signing.
2. **Plan:** open the area survey planner from the map. Add at least three polygon vertices and adjust them by dragging. Match the camera, lens and aspect ratio; select nadir/oblique views. Set altitude or GSD, speed, overlap, gimbal angle, start point and completion behavior. Save the mission and inspect its path, photo count and duration.
3. **Preview and execute:** confirm the altitude datum; missions store WGS84 coordinates without manually added map offsets. Start with a small-area preview, resolve GPS/home/camera/control preflight blocks, then execute explicitly. Import never takes off automatically. Mini 2 uses app-side control, so keep the app foreground and connected.
4. **Simulate first:** follow the [HIL guide](docs/HIL_QUICKSTART.md). Xcode Mock is not DJI flight-controller simulation. Investigate pauses or manual intervention before explicitly resuming; an executing/paused mission cannot be replaced by import.
5. **Read cloud results:** open the survey cloud icon or the cloud entry in More actions. Enter the workstation root URL, bearer access code and existing session ID. Connect/refresh, view the point cloud, then download the proposed route.
6. **Reacquire:** inspect the download summary before importing to the mission library/map. Check ASL/takeoff datum, path, camera and review metadata, then complete local preflight. A warning about missing/false `safe_to_execute` is not flight authorization. iOS accepts schemas 1–14; continuous reacquisition requires explicit experimental selection, not manual schema editing. Release builds still reject terrain-following missions.

The cloud upload section supports session creation, survey-trigger downlink frames,
historical photos, explicit reconstruction submission and retries. Originals must
contain GPS/ASL metadata; live frames are not onboard SD-card photos. Queues persist
to disk and require manual resume after restart. Upload completion neither submits
reconstruction nor executes a mission automatically. See the
[upload guide](docs/CLOUD_UPLOAD.md) and [cloud workflow](docs/CLOUD_ROUTE_WORKFLOW.md).
Older installation packages need an update to expose these features.
Workstation setup is documented in the
[main repository](https://github.com/mistletoe235/OpenFlyScan/blob/main/docs/workstation.md).

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

The simulator build uses the mock flight provider. Integrate Pods after generating the project
so that both simulator and device builds retain the correct dependency configuration:

```bash
xcodegen generate
pod install --no-repo-update
xcodebuild -workspace DJIVLNiOS.xcworkspace -scheme DJIVLNiOS \
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

- [Cloud point clouds and routes](docs/CLOUD_ROUTE_WORKFLOW.md)
- [Simulator validation](docs/SIMULATOR_VALIDATION.md)
- [Real-device checklist](docs/REAL_DEVICE_CHECKLIST.md)
- [Release feature gates](docs/RELEASE_FEATURE_FLAGS.md)

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md) before submitting flight-control
changes. OpenFly Go is licensed under the [Apache License 2.0](LICENSE). Third-party components retain
their own terms; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Camera profile compatibility

Read the [camera compatibility guide](docs/CAMERA_PROFILE_COMPATIBILITY.md) before
changing aircraft, lens or photo mode. SDK connectivity does not verify the camera
profile; unconfirmed geometry must not authorize mission execution.

## License and third-party software

Original OpenFly Go code uses [Apache-2.0](LICENSE). DJI SDK binaries, map
services and other dependencies retain their own terms. See
[third-party notices](THIRD_PARTY_NOTICES.md) and the retained files in `LICENSES/`;
include the applicable notices when distributing an installation package.
