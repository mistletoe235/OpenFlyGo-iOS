# Release feature flags

OpenFly Go keeps terrain-following behind a Swift compilation condition:

- `OPENFLY_ENABLE_TERRAIN` enables DSM/DEM import, terrain planning and terrain missions.

The public repository does not contain the native on-device inference runtime or model binaries,
and `project.yml` never defines `OPENFLY_ENABLE_VLN`. Both Debug and Release therefore hide the
inference surface. Debug currently enables terrain tools for development; Release omits the terrain
symbol and rejects missions containing `terrainPlan` before execution.

After changing a publication gate, regenerate the project with `xcodegen generate` and rebuild both
Debug and Release. Adding the inference symbol alone is insufficient: its separately released source
module and native runtime must also be integrated.
