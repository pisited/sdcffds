// v0.084 consumes BeamRT GI as confidence-premultiplied expected radiance.
// Support remains a reconstruction guide instead of being applied twice.
#define BEAMRT_RAY_HIT_DIAGNOSTIC 1
#define BEAMRT_CONFIDENCE_AWARE_COMPOSE 1
#define BEAMRT_CONSERVATIVE_RECEIVER_RESPONSE 1
#define BEAMRT_RECEIVER_REFLECTANCE 1
#define BEAMRT_PREMULTIPLIED_GI_COMPOSE 1
#include "beamrtLightingComposeP_v052.hlsl"
