// v0.082 experimental GI shadow-aware world-surfel visibility.
// Shader v081 features remain selected. The new world-triangle segment
// occlusion requires a separate GE-Lua toggle and verified opaque triangles.
// At zero triangle count or when disabled, the GI result is unchanged.
#define BEAMRT_SCENE_VISIBILITY_GI 1
#include "beamrtGITraceP_v081.hlsl"
