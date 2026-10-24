#include "shaders/common/postFx/postFx.h.hlsl"

uniform_sampler2D(currentGITex, 0);
uniform_sampler2D(prepassTex, 1);
uniform_sampler2D(prepassDepthTex, 2);
uniform_sampler2D(velocityTex, 3);
uniform_sampler2D(historyMomentsTex, 4);

cbuffer perDraw : register(b0)
{
    uniform float historyValid;
    uniform float historyDepthTolerance;
    uniform float momentsMaxHistory;
    uniform float2 targetSize;
    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float beamrtMomentLuminance(float3 color)
{
    return dot(max(color, 0.0), float3(0.2126, 0.7152, 0.0722));
}

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float4 decoded = decodeGBuffer(
        TEX_SAMPLER(prepassDepthTex),
        TEX_SAMPLER(prepassTex),
        IN.uv1,
        projParams
    );
    if (decoded.w >= 0.9999)
    {
        return 0.0;
    }

    float luminance = beamrtMomentLuminance(tex2D(currentGITex, IN.uv0).rgb);
    float mean = luminance;
    float secondMoment = luminance * luminance;
    float historyLength = 1.0;

    float2 velocity = tex2D(velocityTex, IN.uv3).xy;
    float2 previousUv = IN.uv0 + velocity;
    float velocityPixels = length(velocity * targetSize);
    bool previousUvValid = all(previousUv >= 0.0) && all(previousUv <= 1.0);
    if (historyValid > 0.5 && previousUvValid && velocityPixels <= 96.0)
    {
        float4 previous = tex2D(historyMomentsTex, previousUv);
        float relativeDepthDelta = abs(previous.a - decoded.w) / max(decoded.w, 0.0001);
        float safeTolerance = max(historyDepthTolerance, 0.0001);
        float depthConfidence = 1.0 - smoothstep(safeTolerance, safeTolerance * 4.0, relativeDepthDelta);
        float velocityConfidence = 1.0 - smoothstep(32.0, 96.0, velocityPixels);
        float confidence = depthConfidence * velocityConfidence;
        // Invalid statistics restart this pixel instead of poisoning all
        // subsequent variance/history estimates, even with matching depth.
        if (all(isfinite(previous)) && confidence > 0.0001 && previous.b > 0.5)
        {
            float maxHistory = clamp(momentsMaxHistory, 1.0, 256.0);
            historyLength = min(previous.b + 1.0, maxHistory);
            float currentWeight = 1.0 / historyLength;
            mean = lerp(previous.r, luminance, currentWeight);
            secondMoment = lerp(previous.g, luminance * luminance, currentWeight);
            mean = lerp(luminance, mean, confidence);
            secondMoment = lerp(luminance * luminance, secondMoment, confidence);
            historyLength = lerp(1.0, historyLength, confidence);
        }
    }

    return float4(mean, max(secondMoment, mean * mean), historyLength, decoded.w);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}

/* Historical GGX reflection-moments example, not this GI shader's executable
   code. The reflection pass is implemented in beamrtReflectionMomentsP_v001.
   Keep this example as documentation: its names are not GI shader bindings.
float3 radiance = max(
    tex2D(currentReflectionTex, IN.uv0).rgb,
    0.0
);

float L = dot(
    radiance,
    float3(0.2126, 0.7152, 0.0722)
);

// Each GGX estimator sample contributes,
// including samples with zero radiance.
float2 currentMoments = float2(L, L * L);

// Reuse only geometrically valid history.
float2 accumulatedMoments = historyValid
    ? lerp(previousMoments, currentMoments, alpha)
    : currentMoments;

float variance = max(
    accumulatedMoments.y -
    accumulatedMoments.x * accumulatedMoments.x,
    0.0
);
*/
