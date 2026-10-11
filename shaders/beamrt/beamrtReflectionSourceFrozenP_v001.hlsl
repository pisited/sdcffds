#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(nativeTex, 0);
uniform_sampler2D(deltaTex, 1);
cbuffer perDraw : register(b0) { POSTFX_UNIFORMS };
#include "shaders/common/postFx/postFx.hlsl"
#ifdef SHADER_STAGE_VS
#define mainV main
#else
#define mainP main
#endif
float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float4 native = tex2D(nativeTex, IN.uv0);
    float3 delta = tex2D(deltaTex, IN.uv1).rgb;
    return float4(hdrEncode(max(hdrDecode(native.rgb) + delta, 0.0)), native.a);
}
PFXVertToPix mainV(PFXVert IN) { return processPostFxVert(IN); }
