# Simulator and HIL validation

The public iOS build validates survey planning, flight-state handling and the UE/AirSim HIL boundary
without model inference.

## Build

```bash
xcodegen generate
xcodebuild -project DJIVLNiOS.xcodeproj -scheme DJIVLNiOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## Required checks

- a known X-only HIL displacement appears east and a Y-only displacement appears north;
- stale, replayed and out-of-order pose packets are rejected;
- virtual-camera loss pauses an active HIL survey and cannot auto-resume it;
- collision, emergency stop, app backgrounding and manual takeover emit zero/release;
- hotspot discovery locks one peer and safely rediscovers after an explicit reset;
- survey checkpoints survive a connection loss and restore only to `PAUSED`;
- terrain following starts disabled and terrain missions fail closed when the build flag is absent.

Simulator success is not real-flight acceptance. Device testing still requires the DJI App Key,
correct Bundle Identifier, signing, live telemetry and a supported aircraft.
