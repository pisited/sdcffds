// v0.056: apply the same corrected de-light/re-light estimator and lightinfo
// target-space mapping before radiance enters the persistent surfel cache.
#define BEAMRT_DIRECT_DIFFUSE_SOURCE 1
#define BEAMRT_RADIANCE_CLEANUP_V056 1
#define BEAMRT_LIGHTINFO_SLOT3 1
#include "beamrtSurfelCacheP_v051.hlsl"
