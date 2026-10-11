// v0.022 keeps material/F0-aware Fresnel but remaps it for visible screen-space
// detail after roughness and hit-confidence attenuation. It remains far below
// the legacy composer's unconditional 22% dielectric minimum.
#define BEAMRT_MATERIAL_FRESNEL 1
#define BEAMRT_VISIBLE_SSR 1
#include "beamrtReflectionComposeP_v020.hlsl"
