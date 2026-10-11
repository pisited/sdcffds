#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(sourceTex, 0);
uniform_sampler2D(reflectionTex, 1);
uniform_sampler2D(deltaTex, 2);
cbuffer perDraw : register(b0) { uniform float sourceDisplay; uniform float reflectionStrength; POSTFX_UNIFORMS };
#include "shaders/common/postFx/postFx.hlsl"
#ifdef SHADER_STAGE_VS
#define mainV main
#else
#define mainP main
#endif
float4 mainP(PFXVertToPix IN) : SV_Target0
{
    if (sourceDisplay < 1.5) return tex2D(sourceTex, IN.uv0);
    if (sourceDisplay < 2.5)
        return float4(hdrEncode(max(tex2D(reflectionTex, IN.uv1).rgb, 0.0) * reflectionStrength), 1.0);
    return float4(hdrEncode(abs(tex2D(deltaTex, IN.uv2).rgb)), 1.0);
}
PFXVertToPix mainV(PFXVert IN) { return processPostFxVert(IN); }
