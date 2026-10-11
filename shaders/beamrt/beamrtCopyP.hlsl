#include "beamrtCopy.h.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    return tex2D(inputTex, IN.uv0);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
