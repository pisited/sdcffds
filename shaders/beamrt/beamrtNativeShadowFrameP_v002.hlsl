#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(sceneTex,0);
cbuffer perDraw:register(b0){float nativeShadowEpoch;float nativeScheduledEpoch;POSTFX_UNIFORMS};
#include "shaders/common/postFx/postFx.hlsl"
#ifdef SHADER_STAGE_VS
#define mainV main
#else
#define mainP main
#endif
float4 mainP(PFXVertToPix IN):SV_Target0
{
    if(nativeShadowEpoch<32||nativeScheduledEpoch!=nativeShadowEpoch)return 0;
    return float4(nativeShadowEpoch,.375,.625,1);
}
PFXVertToPix mainV(PFXVert IN){return processPostFxVert(IN);}
