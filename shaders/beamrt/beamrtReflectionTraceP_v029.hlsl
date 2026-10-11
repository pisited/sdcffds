// v0.029 keeps the first observed surface authoritative. The only unbracketed
// departure allowance is the original receiver depth texel within 2 mm travel.
// Invalid refinement evidence and rejected first crossings terminate the ray.
#define BEAMRT_REFLECTION_FIRST_SURFACE 1
#include "beamrtReflectionTraceP_v027.hlsl"
