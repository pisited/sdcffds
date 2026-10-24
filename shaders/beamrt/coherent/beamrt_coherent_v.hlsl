#include "beamrt_coherent.h.hlsl"

PFXVertToPix main(PFXVert IN)
{
    return processPostFxVert(IN);
}
