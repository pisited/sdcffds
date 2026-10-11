// Preserve visible near-field DDA travel to BeamNG's native near plane.
#define BEAMRT_NATIVE_NEAR_CLIP 1
// Continue the experimental scalar atlas by translating lookups, not values.
#define BEAMRT_PRESERVE_ATLAS_VALUES 1
// Ray diagnostics share the beauty path's receiver geometry rejection.
#define BEAMRT_DIAGNOSTIC_GEOMETRY_GUARD 1
#include "beamrtGITraceP_v080.hlsl"
