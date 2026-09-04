# OpenFly Go iOS real-device checklist

The public snapshot intentionally excludes on-device model inference. Validate the DJI and survey
features below on a connected iPhone before treating a build as flight-ready.

## DJI iOS MSDK V4.16.2

1. Confirm the DJI iOS App Key build setting matches this Bundle ID.
2. Use the linked real `DJIFlightProviderV4`; the unavailable provider remains only as a build fallback.
3. Validate only with an iOS MSDK V4-supported aircraft. Do not use M30/M30T, M350 or Mavic 3 Enterprise.
4. Map only documented V4 sources for video, GPS, altitude/ASL, velocity, RC sticks, camera, media, gimbal, Virtual Stick, RTH and landing.
5. Verify manual stick takeover, background release, stale telemetry, stop threshold and emergency reset before permitting outdoor control.
6. Mark every capability unsupported by the connected aircraft as unavailable instead of guessing or substituting another telemetry field.
7. Open the full-screen map and Survey Planner with live video. Confirm the PIP owns the DJI render
   target while visible, the main full-screen feed resumes immediately after closing it, and no PIP
   or hidden return hit target exists while the camera is disconnected.
8. On the ground, open Aircraft Gallery for both selected SD and internal storage when supported.
   Verify file count, photo/video filter, thumbnail-to-preview fallback, and restoration to
   shoot-photo mode plus live preview after closing. Do not test media-mode switching in flight.
9. Trigger DJI's landing-confirmation-required state above a verified clear landing area. Confirm the
   app shows the explicit action, sends it once, and does not auto-confirm on a real aircraft.
10. Measure Virtual Stick sends from device logs: automated survey control should use one 25 Hz
    send loop, with zero-command plus release on inactive/background, manual takeover, stale
    telemetry, camera/storage loss and HIL frame loss.
11. While grounded and propellers removed, disconnect/reconnect the product and, if available, hot
    switch between two SDK products. Before the new FlightController callback, Home, flying, GPS,
    signal, battery, limits, Simulator and Virtual Stick must remain unavailable; no old nonzero
    command may resume without a fresh explicit arm.
12. For iOS Simulator HIL, verify a known X-only displacement appears east and a Y-only displacement
    appears north in the UE pose. Android uses the opposite SDK field mapping even though both wire
    payloads are ENU.
13. Hold each RC stick away from center before requesting an automated or manual control action and confirm it
    remain unavailable. Repeat while DJI is already returning home, landing or in emergency mode.
14. Request RTH and landing while App Virtual Stick is active. Confirm the log reports zero/release
    first, the DJI action is not submitted until VS is observed inactive (or the documented 1.5 s
    fallback expires), and no old nonzero command is sent after the autopilot action starts.
15. Block the main thread while SDK flight states are arriving, then release it. Confirm queued old
    callbacks retain their callback-boundary age and cannot satisfy the 1.5 s flight-state freshness
    gate or resurrect telemetry from a replaced aircraft session.
