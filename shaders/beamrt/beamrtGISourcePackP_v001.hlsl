// Preserve precisely the channels GI uses: direct-light RGB + material retro A.
// Full receiver resolution, point copies, R32F target. No HDR decode/encode,
// opacity guess, source shaping, noise/history changes or half-res metadata.
#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(lightInfoTex,0);
uniform_sampler2D(materialSpecTex,1);
cbuffer perDraw:register(b0){POSTFX_UNIFORMS};
#include "shaders/common/postFx/postFx.hlsl"
#ifdef SHADER_STAGE_VS
#define mainV main
#else
#define mainP main
#endif
float4 mainP(PFXVertToPix IN):SV_Target0
{return float4(tex2D(lightInfoTex,IN.uv0).rgb,tex2D(materialSpecTex,IN.uv1).a);}
PFXVertToPix mainV(PFXVert IN){return processPostFxVert(IN);}
