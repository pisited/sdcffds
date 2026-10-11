// One traversal. Hit-aware GGX replaces only trace alpha with exact packed UV;
// RGB retains the original confidence-premultiplied BRDF contribution.
#define BEAMRT_REFLECTION_HIT_AWARE 1
#include "beamrtReflectionTraceP_v030.hlsl"
