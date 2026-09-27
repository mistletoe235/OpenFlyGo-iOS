# Cloud point clouds and routes

[English](CLOUD_ROUTE_WORKFLOW.md) · [中文](CLOUD_ROUTE_WORKFLOW.zh-CN.md)

## Connect and review

See the [main workstation guide](https://github.com/mistletoe235/OpenFlyScan/blob/main/docs/workstation.md)
for deployment. Obtain the phone-reachable service root, bearer token and existing
session ID. Alternatively, create/upload/finalize in the separate
[upload section](CLOUD_UPLOAD.md). Saving a photo is not uploading it, and uploading
is not submitting reconstruction.

Enter the service root, not SSH, an API path or `127.0.0.1`. Supply the token only;
the app adds the Bearer prefix. Use HTTPS and verify local-network permission,
routing and certificates. Do not globally disable ATS or certificate checks.

After connect/refresh, inspect session status and errors, view the generated PLY,
and review the downloaded mission summary before importing to the library/map.
Before flight, check takeoff location, relative-height/ASL datum, WGS84 coordinates,
camera, groups/capture points, full return/transit paths and battery budget.
Validate a small mission in HIL and complete local preflight; keep the app foreground
for Mini 2 execution. Do not rewrite approval fields. iOS warning-based preview
import is not flight authorization or the same policy as Android import.

Schema 14 uses app-side Virtual Stick, not V5 KMZ. Select the experimental mode
when creating a session; stopped capture remains the default. Do not manually
change the schema. See the [schema 14 notes](SCHEMA14_CONTINUOUS_RECAPTURE_2026-09-22.md).
After execution, check actual photos and mission records. A new upload session
can start the next round; submit reconstruction and refresh explicitly. There is
no automatic reacquisition loop.

| Symptom | Check first |
| --- | --- |
| Timeout / ATS error | Reachable root URL, routing/VPN, HTTPS certificate and local-network permission |
| HTTP 401 / 403 | Token/session permissions; keep tokens out of logs and screenshots |
| HTTP 404 / wrong session | Service/ID pairing and accidentally appended API paths |
| Disabled download | Artifact readiness and test-session restrictions; SSH is not involved |
| PLY not visible | Format, same-origin URL and the 32 MiB limit below |
| Import/execution blocked | Schema, terrain feature gate, task lock, review and local preflight |

Progressive output depends on the workstation. Browsing uses manual refresh and
does not provide a server session-list interface.

This route-related functionality is part of the public app. It does not depend on MNN, VLN,
model inference, model downloads, or the private inference repository.

## Use

Open the survey planner, then tap the cloud icon (also available in More actions). Enter your
HTTP/HTTPS service root URL, bearer access code and an **existing** session ID. This is a V86
reconstruction service connection, not SSH. The public app leaves the endpoint blank by default.

1. Connect/refresh calls `GET /api/sessions/{id}/result` and verifies the returned session ID.
2. Download/view opens `point_cloud.url` as a rotatable, zoomable PLY point cloud.
3. Download mission reads `openfly_v5_mission.url`, validates it and shows a summary.
4. Import saves it to the local mission library and displays it on the map. It does not execute,
   request flight control, or take off. Confirm coordinates/altitude and complete normal preflight.

The browser does not upload images, create sessions, start reconstruction, retry processing or
cancel a server task. The separate [upload section](CLOUD_UPLOAD.md) can create an iOS session,
queue survey-trigger downlink frames or geotagged originals, and explicitly finalize reconstruction.
There is no session-list/SSH interface and no candidate camera overlay in the iOS viewer yet.

## Boundaries

- Mission schema 1–14, WGS84 only. Schema 14 requires an explicit known recapture mode; continuous
  missions use bounded app-side Virtual Stick guidance, not KMZ. The cloud checkbox defaults off.
  Active recapture uses the existing contract validator. Release builds reject
  terrain-following missions when that feature is disabled.
- `test_only=true` or `contract.altitude_mode=relative_height_test` cannot be downloaded as a mission.
- A missing/false `safe_to_execute` is explicitly warned about. Import for review is not a safety
  certification and does not skip local execution checks.
- An executing/paused mission cannot be replaced; the import callback checks the live lock again.
- JSON/result limit 1 MiB, mission limit 8 MiB, PLY limit 32 MiB. The viewer supports ASCII and
  binary-little-endian XYZ PLY, at most 5 million source vertices and 50,000 displayed samples.
- This is an existing reconstruction result, **not** a live obstacle map.

## Credentials and transport

Use HTTPS for public services. The public app does not globally disable ATS or include an exception
for the private production server. Local networking remains enabled. HTTP can expose the bearer
token on the network; do not disable certificate validation to work around server configuration.

Access codes are stored in the device Keychain, isolated by service origin. Only same-origin asset
links are accepted and HTTP redirects are rejected. Credentials are not written into mission files
or logs. Editing connection settings or closing the panel cancels the previous request.

## Build

Run `xcodegen generate`, then `pod install --no-repo-update`, then build/test the workspace. The
app/test Debug/Release xcconfig files include the appropriate CocoaPods configuration and retain
the public `OpenFlyGo.xcconfig` / ignored `Local.xcconfig` overrides. Do not replace the public
project configuration with the private MNN-enabled one.

The latest capture-policy sync also requires `FlightTelemetry.gimbalStateTimestamp` and the real
DJI gimbal callback timestamp. These dependencies are included; a missing/stale timestamp still
fails the capture-pose gate rather than faking freshness.

Protocol tests use controlled responses, not a production login. A valid service credential and
session are still required for an end-to-end check against your reconstruction server.

## Phone copies and upload storage

Extra phone image archives are off by default. Cloud collection is explicit and still uses a bounded
local retry queue; it does not require an extra permanent downlink-image archive. See
[phone image storage behavior](PHONE_IMAGE_STORAGE_2026-09-25.md). Old images are not deleted.
