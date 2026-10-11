// v0.074 estimates bounded receiver diffuse reflectance from BeamNG's final
// surface radiance and direct-light buffer, then suppresses metal-like F0. This
// removes the diffuse-white coating previously visible on wheels and tires.
#define BEAMRT_RAY_HIT_DIAGNOSTIC 1
#define BEAMRT_CONFIDENCE_AWARE_COMPOSE 1
#define BEAMRT_CONSERVATIVE_RECEIVER_RESPONSE 1
#define BEAMRT_RECEIVER_REFLECTANCE 1
#include "beamrtLightingComposeP_v052.hlsl"
