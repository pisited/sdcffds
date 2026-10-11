#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(currentReflectionTex, 0);
uniform_sampler2D(prepassDepthTex, 1);
uniform_sampler2D(hitInputsTex, 2);
uniform_sampler2D(temporalReflectionTex, 3);
cbuffer perDraw : register(b0)
{
    uniform float reflectionHistoryValid;
    uniform float reflectionCameraMotion;
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
    if (reflectionHitAwareEnabled <= 0.5) return 0.0;
    // Derivatives must be evaluated before the per-pixel hit/miss branch.
    float2 receiverUV = (IN.uv0 - rtParams0.xy) / rtParams0.zw;
    float3 eyeDx = ddx(IN.wsEyeRay), eyeDy = ddy(IN.wsEyeRay);
    float2 uvStep = float2(ddx(receiverUV.x), ddy(receiverUV.y));
    float packed = tex2D(currentReflectionTex, IN.uv0).a;
    float2 hitUV = 0.0;
    float hitDepth = 0.0;
    if (beamrtHasHitUV(packed))
    {
        hitUV = beamrtUnpackHitUV(packed);
        float2 hitTargetUV = viewportCoordToRenderTarget(hitUV, rtParams1);
        hitDepth = ndcToRealDepth(tex2D(prepassDepthTex, hitTargetUV).r, projParams.zw);
        if (!(hitDepth > 0.0 && hitDepth < projParams.y * 0.9999)) return 0.0;
    }
    else
    {
        // A stochastic zero must not erase geometry still represented by
        // nonzero accumulated color. Carry a proxy only under a still camera.
        float4 color = tex2D(temporalReflectionTex, IN.uv3);
        if (reflectionHistoryValid <= 0.5 || reflectionCameraMotion > 0.0001
            || color.a <= 0.0 || max(color.r, max(color.g, color.b)) <= 0.0)
            return 0.0;
        float4 previous = tex2D(hitInputsTex, IN.uv2);
        if (!beamrtHasHitUV(previous.z) || previous.w <= 0.0) return 0.0;
        hitUV = beamrtUnpackHitUV(previous.z);
        hitDepth = previous.w;
    }
    float receiverDepth = ndcToRealDepth(tex2D(prepassDepthTex, IN.uv1).r, projParams.zw);
    float distanceToHit = 0.0;
    if (abs(uvStep.x) > 0.00000001 && abs(uvStep.y) > 0.00000001)
    {
        float2 pixelOffset = (hitUV - receiverUV) / uvStep;
        float3 hitEyeRay = IN.wsEyeRay + eyeDx * pixelOffset.x + eyeDy * pixelOffset.y;
        distanceToHit = length(hitEyeRay * (hitDepth / projParams.y)
            - IN.wsEyeRay * (receiverDepth / projParams.y));
    }
    // Separate physical geometry; no confidence, PDF, BRDF or radiance scale.
    // W is receiver-to-source surface distance, not the camera's primary depth.
    return float4(hitUV, hitDepth, distanceToHit);
}
PFXVertToPix mainV(PFXVert IN) { return processPostFxVert(IN); }
