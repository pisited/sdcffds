// Opt-in full-mesh opaque visibility. Same GI integrator/noise/history as v082.
// Slot3 packs only native light RGB + retro A; slot5 becomes BVH data.
#define BEAMRT_SHARED_MESH_GI 1
#include "beamrtGITraceP_v082.hlsl"
