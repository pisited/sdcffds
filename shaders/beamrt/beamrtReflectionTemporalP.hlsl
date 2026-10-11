#include "beamrtReflectionTemporal.h.hlsl"

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

    float4 rawCurrent = tex2D(currentReflectionTex, IN.uv0);
    float3 filteredSum = 0.0;
    float weightSum = 0.0;
    float3 neighborhoodMin = rawCurrent.rgb;
    float3 neighborhoodMax = rawCurrent.rgb;
    bool currentHit = rawCurrent.a > 0.5;
    float safeCenterDepth = max(centerDecoded.w, 0.0001);

    [unroll]
    for (int y = -1; y <= 1; ++y)
    {
        [unroll]
        for (int x = -1; x <= 1; ++x)
        {
            float2 offset = float2((float)x, (float)y) * oneOverTargetSize;
            float4 sampleReflection = tex2D(currentReflectionTex, IN.uv0 + offset);
            float4 sampleDecoded = decodeGBuffer(
                TEX_SAMPLER(prepassDepthTex),
                TEX_SAMPLER(prepassTex),
                IN.uv1 + offset,
                projParams
            );
            neighborhoodMin = min(neighborhoodMin, sampleReflection.rgb);
            neighborhoodMax = max(neighborhoodMax, sampleReflection.rgb);
            float relativeDepthDelta = abs(sampleDecoded.w - centerDecoded.w) / safeCenterDepth;
            float depthWeight = 1.0 - smoothstep(0.002, 0.025, relativeDepthDelta);
            float normalWeight = pow(saturate(dot(centerDecoded.xyz, sampleDecoded.xyz)), 24.0);
            float hitWeight = sampleReflection.a > 0.5 ? 1.0 : 0.05;
            float spatialWeight = (x == 0 && y == 0) ? 2.0 : 1.0;
            float weight = depthWeight * normalWeight * hitWeight * spatialWeight;
            filteredSum += sampleReflection.rgb * weight;
            weightSum += weight;
        }
    }

    float3 filteredCurrent = weightSum > 0.0001 ? filteredSum / weightSum : rawCurrent.rgb;
    float3 currentReflection = lerp(rawCurrent.rgb, filteredCurrent, saturate(reflectionDenoiseStrength));
    float2 velocity = tex2D(velocityTex, IN.uv3).xy;
    float2 previousUv = IN.uv0 + velocity;
    float velocityPixels = length(velocity * targetSize);
    bool previousUvValid = all(previousUv >= 0.0) && all(previousUv <= 1.0);

    float historyConfidence = 0.0;
    float3 historyReflection = currentReflection;
    bool historyHit = false;
    if (reflectionHistoryValid > 0.5 && previousUvValid && velocityPixels <= 96.0)
    {
        float4 history = tex2D(historyReflectionTex, previousUv);
        historyHit = history.a >= 1.5;
        float historyDepth = historyHit ? history.a - 2.0 : history.a;
        float relativeHistoryDepth = abs(historyDepth - centerDecoded.w) / safeCenterDepth;
        float safeTolerance = max(reflectionHistoryDepthTolerance, 0.0001);
        float depthConfidence = 1.0 - smoothstep(safeTolerance, safeTolerance * 4.0, relativeHistoryDepth);
        float velocityConfidence = 1.0 - smoothstep(24.0, 96.0, velocityPixels);
        historyConfidence = depthConfidence * velocityConfidence * (historyHit ? 1.0 : 0.0);

        float3 range = neighborhoodMax - neighborhoodMin;
        float3 extent = max(range * 0.75, 0.05);
        float3 boundedHistory = clamp(history.rgb, neighborhoodMin - extent, neighborhoodMax + extent);
        float clampStrength = smoothstep(0.5, 12.0, velocityPixels);
        historyReflection = lerp(history.rgb, boundedHistory, clampStrength);
    }

    float currentWeight = saturate(reflectionTemporalBlend);
    float3 accumulated = lerp(currentReflection, historyReflection, historyConfidence * (1.0 - currentWeight));
    bool resultHit = currentHit || historyConfidence > 0.01;
    return float4(max(accumulated, 0.0), centerDecoded.w + (resultHit ? 2.0 : 0.0));
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
