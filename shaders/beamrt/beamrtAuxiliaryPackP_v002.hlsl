// Native-noise baseline: leave history, velocity, native noise and surfels
// identical to v001, but never sample the rejected experimental DDS bank.
#define BEAMRT_SKIP_STBN_BANK 1
#include "beamrtAuxiliaryPackP_v001.hlsl"
