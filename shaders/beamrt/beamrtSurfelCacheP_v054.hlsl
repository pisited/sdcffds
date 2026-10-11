// v0.054: the persistent cache uses the same direct-diffuse source selector as
// live screen-space hits, preventing final-image specular energy from persisting.
#define BEAMRT_DIRECT_DIFFUSE_SOURCE 1
#include "beamrtSurfelCacheP_v051.hlsl"
