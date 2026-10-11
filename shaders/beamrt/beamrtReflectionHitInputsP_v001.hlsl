#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(velocityTex, 0);
uniform_sampler2D(historyHitTex, 1);
cbuffer perDraw : register(b0)
{
    uniform float reflectionHistoryValid;
    uniform float reflectionHitAwareEnabled;
    POSTFX_UNIFORMS
};
#include "shaders/common/postFx/postFx.hlsl"
#include "beamrtReflectionHitPacking.h.hlsl"
#ifdef SHADER_STAGE_VS
#define mainV main
#else
#define mainP main
#endif
float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float2 velocity = tex2D(velocityTex, IN.uv0).xy;
    // Read old geometry BEFORE this frame's trace/history copies.
    if (reflectionHitAwareEnabled <= 0.5 || reflectionHistoryValid <= 0.5)
        return float4(velocity, 0.0, 0.0);
    float2 receiverUV = (IN.uv0 - rtParams0.xy) / rtParams0.zw;
    float2 previousUV = receiverUV + velocity;
    if (any(previousUV < 0.0) || any(previousUV > 1.0)) return float4(velocity, 0.0, 0.0);
    float4 hit = tex2D(historyHitTex, viewportCoordToRenderTarget(previousUV, rtParams1));
    bool valid = hit.z > 0.0 && hit.z < projParams.y * 0.9999
        && all(hit.xy >= 0.0) && all(hit.xy <= 1.0);
    return float4(velocity, valid ? beamrtPackHitUV(hit.xy) : 0.0, valid ? hit.z : 0.0);
}
PFXVertToPix mainV(PFXVert IN) { return processPostFxVert(IN); }
