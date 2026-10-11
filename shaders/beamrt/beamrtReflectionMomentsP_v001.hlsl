// BeamRT optional GGX variance experiment (v0.102 overlay).
// Stores raw-sample luminance moments in linear estimator space.
// R = E[L], G = E[L^2], B = accepted sample count, A = receiver depth (0..1).
// Zero radiance is a sample, not automatically an invalid geometry hit.
#include "shaders/common/postFx/postFx.h.hlsl"

uniform_sampler2D(currentReflectionTex, 0);
uniform_sampler2D(prepassTex, 1);
uniform_sampler2D(prepassDepthTex, 2);
uniform_sampler2D(velocityTex, 3);
uniform_sampler2D(historyMomentsTex, 4);

cbuffer perDraw : register(b0)
{
    uniform float reflectionHistoryValid;
    uniform float reflectionHistoryDepthTolerance;
    uniform float reflectionCameraMotion;
    uniform float reflectionMaxRoughness;
    uniform float reflectionMomentsMaxHistory;
    uniform float2 targetSize;
    POSTFX_UNIFORMS
};
#include "shaders/common/postFx/postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float4 receiver = decodeGBuffer(
        TEX_SAMPLER(prepassDepthTex), TEX_SAMPLER(prepassTex), IN.uv1, projParams);
    float roughness = max(tex2D(prepassTex, IN.uv1).b, 0.02);
    // Do not use raw trace alpha as a validity boolean: hit-aware GGX
    // packs a hit UV in alpha, and accepted dark hits have zero RGB.
    if (receiver.w >= 0.9999 || roughness >= max(reflectionMaxRoughness, 0.021)
        || dot(receiver.xyz, normalize(-IN.wsEyeRay)) <= 0.001)
        return 0.0;

    float3 rawRadiance = max(tex2D(currentReflectionTex, IN.uv0).rgb, 0.0);
    float L = dot(rawRadiance, float3(0.2126, 0.7152, 0.0722));
    float2 sampleMoments = float2(L, L * L);
    float2 accumulated = sampleMoments;
    float historyLength = 1.0;

    float2 motion = tex2D(velocityTex, IN.uv3).xy;
    float2 previousUv = IN.uv0 + motion;
    float velocityPixels = length(motion * max(targetSize, float2(1.0, 1.0)));
    bool onScreen = all(previousUv >= 0.0) && all(previousUv < 1.0);
    // Strong camera movement makes a previous specular sampling distribution
    // less representative even when the receiver depth still matches.
    if (reflectionHistoryValid > 0.5 && onScreen && velocityPixels < 96.0
        && reflectionCameraMotion < 0.12)
    {
        // Point-sampled history: do not interpolate counts/depth across pixels.
        float4 prev = tex2Dlod(historyMomentsTex, float4(previousUv, 0.0, 0.0));
        float relDepth = abs(prev.a - receiver.w) / max(receiver.w, 0.0001);
        float tolerance = max(reflectionHistoryDepthTolerance, 0.0001);
        float depthConfidence = 1.0 - smoothstep(tolerance, tolerance * 4.0, relDepth);
        float velocityConfidence = 1.0 - smoothstep(12.0, 96.0, velocityPixels);
        float confidence = depthConfidence * velocityConfidence;
        if (prev.b >= 1.0 && prev.a > 0.0 && confidence > 0.001)
        {
            float maxHistory = clamp(reflectionMomentsMaxHistory, 2.0, 128.0);
            historyLength = min(prev.b + 1.0, maxHistory);
            float alpha = 1.0 / historyLength;
            float2 blended = lerp(prev.rg, sampleMoments, alpha);
            accumulated = lerp(sampleMoments, blended, confidence);
            historyLength = lerp(1.0, historyLength, confidence);
        }
    }
    accumulated.y = max(accumulated.y, accumulated.x * accumulated.x);
    return float4(accumulated, historyLength, receiver.w);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
