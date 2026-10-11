// v0.032 applies receiver weighting exactly once: GGX trace is already
// Fresnel/BRDF weighted, while mode zero retains the legacy mirror response.
#define BEAMRT_REFLECTION_GGX 1
#include "beamrtReflectionComposeP_v028.hlsl"
