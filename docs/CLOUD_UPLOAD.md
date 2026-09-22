# iOS image uploads and cloud reconstruction

[English](CLOUD_UPLOAD.md) · [Chinese reference](CLOUD_UPLOAD.zh-CN.md)

Use a source build containing this feature; older installation/TestFlight builds
do not update automatically. Private and source-release clients share the protocol
and need no on-phone model. Workstation setup is documented in the
[main repository](https://github.com/mistletoe235/OpenFlyScan/blob/main/docs/workstation.md).

## Create a session

1. Open the survey cloud icon or cloud entry in More actions, then expand the upload section.
2. Enter a phone-reachable HTTP/HTTPS service root and access code, not SSH. `127.0.0.1` means the phone itself. Prefer HTTPS; the source-release client has no private public-HTTP allowlist.
3. Enter the name, horizontal FOV matching the uploaded images, minimum capture interval and optional absolute takeoff altitude (ASL). Confirmed camera settings only prefill these values: check video crop/photo mode, and do not treat the values as calibrated intrinsics.
4. Create the upload session and save its ID. The queue remains bound to that server and camera/height configuration. Changing the read-only browser's address does not redirect the queue. Create a new session for a different camera or takeoff datum.

iOS advertises schemas 13/14 and requests stopped capture by default. Explicitly
selecting experimental continuous reacquisition requests schema 14 with
`CONTINUOUS_EXPERIMENTAL`; changing the option does not rewrite an existing session.
Without takeoff ASL, reconstruction/cloud viewing is still possible, but the server
does not export a flight mission. **Relative flight height is not ASL.**

## Image sources

**Live capture:** upload fresh downlink frames after subsequent survey capture
triggers, not continuous video, manual-shutter events or onboard SD originals.
Frames preserve their aspect ratio and use a maximum long edge of 1920 pixels;
model-stretched images are not reused. Networking does not block flight control.
Fresh flight state and valid GPS/ASL are required; fresh actual gimbal attitude is
attached when available. Coordinates are not fabricated. HIL/DJI Simulator/Mock
frames are excluded from real sessions. Rejected records may remain in survey
logs, and the UI reports their count; they are not uploaded images.

**Historical photos:** select JPEG/PNG from Files or Photos, at most 100 per batch.
Original EXIF latitude, longitude and absolute altitude are used, not the phone's
or aircraft's current position. Images without positioning/altitude are rejected.
Export HEIC to metadata-preserving JPEG first. Originals are not recompressed.
Disable live capture before importing history; historical selection is disabled
while a mission is executing/paused, and the two import modes do not run together.

Limits: 48 MiB and 60 million pixels per image, at most 1,000 queued images and
512 MiB of pending copies. Do not mix different image geometry, FOV or takeoff
data in one session.

## Queue, retry and submission

- Files are copied into a dedicated disk queue and uploaded by serial PUT. Queue copies are removed only after server acknowledgement; original photos/logs remain. Retries reuse the sequence number. The client does not add a whole-file hash; the server can acknowledge duplicates.
- Temporary network failures and HTTP 408/429/5xx retry automatically at most twice, then pause with files retained. Update the bound session's access code for HTTP 401/403. Resume uploads manually.
- Closing the panel preserves the queue. Backgrounding pauses uploads and live capture. Restart restores a paused queue; confirm the session before resuming. This is not an unlimited background-upload service.
- Disable live capture and wait for imports/pending uploads to succeed, then explicitly finish uploading and submit reconstruction. **No automatic finalization.** Rejected images are not pending; inspect rejection records before submission. A submitted session cannot accept appended images.
- Refresh status, explicitly retry submitted reconstruction, or open the session's [cloud results](CLOUD_ROUTE_WORKFLOW.md). Results still require manual reading/refresh.
- Canceling the server task retains local copies. Clearing the local queue removes pending copies but not remote data. Both require confirmation; save the session ID first. A damaged queue is not silently overwritten and has an explicit cleanup/recovery path.
- Access codes use the device Keychain, isolated by service origin, rather than queue manifests, missions or logs.

## Flight and validation boundaries

The existing-session browser remains read-only. Only the upload section creates,
submits or cancels server tasks. Upload/import does not obtain control, take off
or execute a mission. Current server exports carry `safe_to_execute=false` and
`flight_authorized=false`; review and existing camera/coordinate/height/preflight
checks remain required. Differences between downlink and original-image geometry
can legitimately fail camera checks; do not edit fields to bypass them.

Tests use mock HTTP and local images to cover protocol, queue recovery, retained
files on failure and explicit submission. They do not replace iPhone photo
permission/DJI capture, workstation GPU reconstruction or real reacquisition
flight acceptance.
