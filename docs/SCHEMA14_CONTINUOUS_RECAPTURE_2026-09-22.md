# iOS schema 14 continuous reacquisition

[English](SCHEMA14_CONTINUOUS_RECAPTURE_2026-09-22.md) · [Chinese reference](SCHEMA14_CONTINUOUS_RECAPTURE_2026-09-22.zh-CN.md)

Updated September 22, 2026. Both private and source-release clients are adapted;
app version 1.0, build 20260922.

## Use and compatibility

1. Select experimental continuous reacquisition when creating a cloud upload session; it defaults off.
2. The phone advertises `[13,14]`. Default sessions request `STOP_AND_CAPTURE`; opt-in sessions request `CONTINUOUS_EXPERIMENTAL`. Existing sessions are not changed retroactively, and the server must negotiate compatible exports.
3. Downloaded routes still require preview, camera/height-datum review, preflight and explicit start. Downloads, mode selection and mission-library restoration never initiate takeoff.
4. iOS accepts WGS84 schemas 1–14. Continuous mode requires `active_mapping`; schema 14 requires a known recapture mode. Unknown/missing modes, fields forced into older schemas and schema 15 are rejected, not downgraded by editing version numbers.
5. Ordinary/stopped missions export schema 13. Old libraries, checkpoints and upload queues remain readable. Older Codable data without the new mode field restores stopped capture.
6. Active-recapture validation, cloud review warnings, relative-height test restrictions and Release terrain exclusions remain in force.

The existing control loop is scheduled every 40 ms. This is not a claim about DJI
fresh-telemetry frequency or physical control accuracy.

## Continuous execution

The client uses app-side Virtual Stick control, not the V5 KMZ backend. Keep the
app foreground, the controller connected and control authority available. This
is not an offline onboard mission that can run after closing the app.

Only eligible intermediate capture points use continuous following:

- The previous/current/next points are captures with the same view direction.
- Where pass metadata is present, all three belong to the same region and have the `SURVEY` role; reconstruction bridge points are excluded. `pass_index` identifies individual points, not a shared continuous segment.
- Both adjacent horizontal legs are at least 3 m, with a turn of at most 30 degrees.
- Adjacent yaw differences are at most 5 degrees, gimbal-pitch differences at most 3 degrees, and altitude differences at most 0.5 m.
- Endpoints, transit/resume legs and ineligible turns retain stopped-capture behavior.

Bounded lookahead follows adjacent segments, with speed capped by leg length and
the camera's minimum capture interval. This does not reproduce V5 KMZ turn curves
or introduce a global trajectory optimizer.

## Capture confirmation and failure handling

- Flight/gimbal telemetry must be at most one second old and not future-dated, with a valid connection.
- Capture requires yaw error at most 3 degrees, altitude error at most 0.4 m and the existing gimbal readback/stability checks.
- The aircraft must enter the horizontal 1.2 m capture window. Continuous mode does not require zero horizontal speed.
- Only one capture request remains pending at a time. The mission advances only after a successful callback.
- Following may continue while awaiting acknowledgement, but lookahead is bounded by the next segment's midpoint. A slow camera can still cause slowing or stopping.
- A missed capture window, invalid waiting pose, capture failure or eight-second timeout pauses execution rather than marking a missing photo successful. Resume retains the existing preflight/recovery path.

A successful DJI capture-command callback does not establish precise exposure
time or verify the SD-card photo. Motion blur, actual exposure position, camera
cadence and flight tracking require hardware acceptance, not just software tests.

Callbacks received after manual takeover cannot restart motion or advance the mission.

## Validation scope

Tests cover schema 14 round trips/cloud validation, invalid inputs, older Codable
data, default/explicit capability requests, geometry/region eligibility and
telemetry freshness. Numerical following covers 64 spacing/speed/capture-delay
combinations. State-machine cases cover continued movement while waiting, advance
only on success, pause on failure, ignored callbacks after takeover and missed
capture windows. These use XCTest, simplified kinematics and fake providers,
not DJI Simulator or real-flight acceptance.

No aircraft was connected/controlled, no phone package was installed, and no build
was uploaded to App Store Connect during this validation.

## Recorded build and regression results

| Project | Xcode Simulator Debug suite | arm64 device Release build |
| --- | --- | --- |
| Private iOS | 265 passed, 0 failed | Successful, build 20260922 |
| Source-release iOS | 189 passed, 2 skipped, 0 failed | Successful, build 20260922 |

All 11 new targeted tests passed, including 64 numerical-following combinations
and four asynchronous execution tests. The two source-release skips require an
explicitly configured online service and an Android DSM fixture not bundled here.
Flight, camera and mission validation were not weakened to pass tests.

Run from the relevant iOS project:

```sh
xcodegen generate
pod install --no-repo-update
xcodebuild -workspace DJIVLNiOS.xcworkspace -scheme DJIVLNiOS \
  -destination 'platform=iOS Simulator,id=F79457A2-9EAF-4585-850A-8B30BAFC8013' \
  -derivedDataPath build test
xcodebuild -workspace DJIVLNiOS.xcworkspace -scheme DJIVLNiOS \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build-release CODE_SIGNING_ALLOWED=NO build
```

Replace the Simulator ID with an available local device. The Release command
checks device-architecture compilation without signing; it does not produce a
distributable signed IPA or upload a build to App Store Connect.
