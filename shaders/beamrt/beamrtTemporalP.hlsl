#include "beamrtTemporal.h.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float4 centerDecoded = decodeGBuffer(
        TEX_SAMPLER(prepassDepthTex),
        TEX_SAMPLER(prepassTex),
        IN.uv1,
        projParams
    );

    if (centerDecoded.w >= 0.9999)
    {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    float3 rawCurrent = tex2D(currentGITex, IN.uv0).rgb;
    float3 filteredSum = 0.0;
    float filterWeightSum = 0.0;
    float3 neighborhoodMin = rawCurrent;
    float3 neighborhoodMax = rawCurrent;
    float safeCenterDepth = max(centerDecoded.w, 0.0001);

    [unroll]
    for (int y = -1; y <= 1; ++y)
    {
        [unroll]
        for (int x = -1; x <= 1; ++x)
        {
            float2 offset = float2((float)x, (float)y) * oneOverTargetSize;
            float2 giUv = IN.uv0 + offset;
            float2 prepassUv = IN.uv1 + offset;
            float4 sampleGI = tex2D(currentGITex, giUv);
            float4 sampleDecoded = decodeGBuffer(
                TEX_SAMPLER(prepassDepthTex),
                TEX_SAMPLER(prepassTex),
                prepassUv,
                projParams
            );

            neighborhoodMin = min(neighborhoodMin, sampleGI.rgb);
            neighborhoodMax = max(neighborhoodMax, sampleGI.rgb);

            float relativeDepthDelta = abs(sampleDecoded.w - centerDecoded.w) / safeCenterDepth;
            float depthWeight = 1.0 - smoothstep(0.002, 0.03, relativeDepthDelta);
            float normalWeight = pow(saturate(dot(centerDecoded.xyz, sampleDecoded.xyz)), 16.0);
            float hitWeight = lerp(0.20, 1.0, saturate(sampleGI.a));
            float spatialWeight = (x == 0 && y == 0) ? 2.0 : 1.0;
            float weight = depthWeight * normalWeight * hitWeight * spatialWeight;
            filteredSum += sampleGI.rgb * weight;
            filterWeightSum += weight;
        }
    }

    float3 filteredCurrent = filterWeightSum > 0.0001 ? filteredSum / filterWeightSum : rawCurrent;
    float3 currentGI = lerp(rawCurrent, filteredCurrent, saturate(denoiseStrength));
    float2 velocity = tex2D(velocityTex, IN.uv3).xy;
    float2 previousUv = IN.uv0 + velocity;
    float velocityPixels = length(velocity * targetSize);
    bool previousUvValid = all(previousUv >= 0.0) && all(previousUv <= 1.0);

    float historyConfidence = 0.0;
    float3 historyGI = currentGI;
    if (historyValid > 0.5 && previousUvValid && velocityPixels <= 96.0)
    {
        float4 history = tex2D(historyTex, previousUv);
        float relativeHistoryDepth = abs(history.a - centerDecoded.w) / safeCenterDepth;
        float safeTolerance = max(historyDepthTolerance, 0.0001);
        float depthConfidence = 1.0 - smoothstep(safeTolerance, safeTolerance * 4.0, relativeHistoryDepth);
        float velocityConfidence = 1.0 - smoothstep(32.0, 96.0, velocityPixels);
        historyConfidence = depthConfidence * velocityConfidence;

        // Match the shipped GTAO strategy: a stationary, already-reprojected
        // pixel may keep its converged mean even when one stochastic frame is
        // outside the local AABB. Tighten the neighborhood clamp as motion
        // rises, where stale history is far more likely to form a trail.
        float3 neighborhoodRange = neighborhoodMax - neighborhoodMin;
        float3 clampExtent = max(neighborhoodRange * 0.5, 0.025);
        float3 boundedHistory = clamp(
            history.rgb,
            neighborhoodMin - clampExtent,
            neighborhoodMax + clampExtent
        );
        float motionClampStrength = smoothstep(1.0, 16.0, velocityPixels);
        historyGI = lerp(history.rgb, boundedHistory, motionClampStrength);
    }

    float currentWeight = saturate(temporalBlend);
    float3 accumulatedGI = lerp(currentGI, historyGI, historyConfidence * (1.0 - currentWeight));
    return float4(max(accumulatedGI, 0.0), centerDecoded.w);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
