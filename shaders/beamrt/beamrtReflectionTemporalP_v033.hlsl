// v0.033 reconstructs optional playable GGX with the existing 13 bilateral
// taps and a short, FPS-independent rolling average. Static color clipping is
// bypassed so zero samples do not selectively erase sparse bright energy.
// Mirror and legacy reconstruction retain v0.031 formulas. Depth/camera/velocity
// guards remain active; reflected-source motion can still leave brief trails.
#define BEAMRT_REFLECTION_GGX_PLAYABLE_RECONSTRUCTION 1
#include "beamrtReflectionTemporalP_v031.hlsl"
