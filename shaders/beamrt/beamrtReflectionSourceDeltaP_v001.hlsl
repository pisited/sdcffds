#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(liveTex, 0);
uniform_sampler2D(nativeTex, 1);
cbuffer perDraw : register(b0) { POSTFX_UNIFORMS };
#include "shaders/common/postFx/postFx.hlsl"
#ifdef SHADER_STAGE_VS
#define mainV main
#else
#define mainP main
#endif
float4 mainP(PFXVertToPix IN) : SV_Target0
{
    // Matched SAME-FRAME before/after our GI composer, not guessed native
    // cubemap subtraction. Keep signed net changes (visibility can darken).
    float3 live = hdrDecode(tex2D(liveTex, IN.uv0).rgb);
    float3 native = hdrDecode(tex2D(nativeTex, IN.uv1).rgb);
    return float4(live - native, 1.0);
}
PFXVertToPix mainV(PFXVert IN) { return processPostFxVert(IN); }
