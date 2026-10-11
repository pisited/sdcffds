// v0.022 filters signed reflection deltas with depth, normal, roughness, and F0
// agreement. Rough receivers get a wider Poisson reconstruction instead of a
// dim sharp mirror image. Alpha stores receiver depth directly: positive is a
// fresh center-pixel hit, negative is its one allowed grace frame, and zero is
// invalid. Keeping depth near its original magnitude preserves R16F precision.
#include "beamrtReflectionTemporal_v022.h.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float beamrtMaxAbs3(float3 value)
{
    value = abs(value);
    return max(value.x, max(value.y, value.z));
}

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float4 rawCurrent = tex2D(currentReflectionTex, IN.uv0);
    float4 centerPacked = tex2D(prepassTex, IN.uv1);
    float4 centerDecoded = decodeGBuffer(
        TEX_SAMPLER(prepassDepthTex),
        TEX_SAMPLER(prepassTex),
        IN.uv1,
        projParams
    );
    if (centerDecoded.w >= 0.9999)
    {
        return 0.0;
    }

    float centerRoughness = max(centerPacked.b, 0.02);
    // PFX provides four independent RT transforms. RT0 and RT1 are matching
    // prepass MRTs, so the RT0 coordinates are intentionally shared here.
    float3 centerSpecular = saturate(tex2D(materialSpecTex, IN.uv1).rgb);
    float normalizedRoughness = saturate(
        centerRoughness / max(reflectionMaxRoughness, 0.05));
    float filterRadiusPixels = lerp(
        1.0, 3.5, normalizedRoughness * normalizedRoughness);

    float3 filteredSum = 0.0;
    float weightSum = 0.0;
    float3 neighborhoodMin = 0.0;
    float3 neighborhoodMax = 0.0;
    bool hasNeighborhoodHit = false;
    float safeCenterDepth = max(centerDecoded.w, 0.0001);

    static const float2 filterOffsets[13] = {
        float2(0.0, 0.0),
        float2(0.527, 0.085), float2(-0.372, 0.359),
        float2(0.116, -0.543), float2(-0.589, -0.171),
        float2(0.874, 0.381), float2(-0.821, 0.493),
        float2(0.418, 0.891), float2(-0.302, -0.931),
        float2(0.978, -0.516), float2(-1.061, -0.284),
        float2(0.681, -1.013), float2(-0.716, 1.046)
    };

    [unroll]
    for (int tapIndex = 0; tapIndex < 13; ++tapIndex)
    {
        float2 offsetPixels = filterOffsets[tapIndex] * filterRadiusPixels;
        float2 offset = offsetPixels * oneOverTargetSize;
        float4 sampleReflection = tex2D(currentReflectionTex, IN.uv0 + offset);
        float4 samplePacked = tex2D(prepassTex, IN.uv1 + offset);
        float4 sampleDecoded = decodeGBuffer(
            TEX_SAMPLER(prepassDepthTex),
            TEX_SAMPLER(prepassTex),
            IN.uv1 + offset,
            projParams
        );
        float3 sampleSpecular = saturate(tex2D(materialSpecTex, IN.uv1 + offset).rgb);

        float relativeDepthDelta = abs(sampleDecoded.w - centerDecoded.w) / safeCenterDepth;
        float depthWeight = 1.0 - smoothstep(0.002, 0.025, relativeDepthDelta);
        float normalWeight = pow(saturate(dot(centerDecoded.xyz, sampleDecoded.xyz)), 24.0);
        float roughnessWeight = 1.0 - smoothstep(
            0.015, 0.18, abs(max(samplePacked.b, 0.02) - centerRoughness));
        float specularWeight = 1.0 - smoothstep(
            0.02, 0.35, length(sampleSpecular - centerSpecular));
        float sampleConfidence = saturate(sampleReflection.a);
        float spatialWeight = exp2(-0.35 * dot(filterOffsets[tapIndex], filterOffsets[tapIndex]));
        float surfaceWeight = depthWeight * normalWeight * roughnessWeight * specularWeight;
        float weight = surfaceWeight * sqrt(sampleConfidence) * spatialWeight;
        filteredSum += sampleReflection.rgb * weight;
        weightSum += weight;

        // Only material-compatible, actual hits define the history clamp.
        // Misses and samples rejected by the bilateral gates cannot widen it.
        if (surfaceWeight > 0.05 && sampleConfidence > 0.005)
        {
            if (!hasNeighborhoodHit)
            {
                neighborhoodMin = sampleReflection.rgb;
                neighborhoodMax = sampleReflection.rgb;
                hasNeighborhoodHit = true;
            }
            else
            {
                neighborhoodMin = min(neighborhoodMin, sampleReflection.rgb);
                neighborhoodMax = max(neighborhoodMax, sampleReflection.rgb);
            }
        }
    }

    float3 filteredCurrent = weightSum > 0.0001
        ? filteredSum / weightSum
        : rawCurrent.rgb;
    float denoiseAmount = saturate(reflectionDenoiseStrength);
    float3 currentDelta = lerp(rawCurrent.rgb, filteredCurrent, denoiseAmount);
    // Spatial support may reconstruct color, but only a ray from this exact
    // pixel is allowed to refresh history lifetime.
    bool currentHit = saturate(rawCurrent.a) > 0.015
        && beamrtMaxAbs3(rawCurrent.rgb) > 0.00005;

    if (!hasNeighborhoodHit)
    {
        neighborhoodMin = rawCurrent.rgb;
        neighborhoodMax = rawCurrent.rgb;
    }

    float2 velocity = tex2D(velocityTex, IN.uv3).xy;
    float2 previousUv = IN.uv0 + velocity;
    float velocityPixels = length(velocity * targetSize);
    bool previousUvValid = all(previousUv >= 0.0) && all(previousUv <= 1.0);

    float historyConfidence = 0.0;
    float3 historyDelta = currentDelta;
    bool historyFresh = false;
    bool historyGrace = false;
    if (reflectionHistoryValid > 0.5 && previousUvValid && velocityPixels <= 96.0)
    {
        // Lifetime is categorical, so read one exact history texel. Linear
        // filtering could otherwise invent a grace frame between fresh and
        // invalid neighbors.
        int2 historyMaxPixel = max(int2(targetSize) - 1, int2(0, 0));
        int2 historyPixel = clamp(int2(previousUv * targetSize), int2(0, 0), historyMaxPixel);
        float4 history = historyReflectionTexTex.Load(int3(historyPixel, 0));
        historyFresh = history.a > 0.000001;
        historyGrace = history.a < -0.000001;
        bool historyHit = historyFresh || historyGrace;
        float historyDepth = abs(history.a);
        float relativeHistoryDepth = abs(historyDepth - centerDecoded.w) / safeCenterDepth;
        float safeTolerance = max(reflectionHistoryDepthTolerance, 0.0001);
        float depthConfidence = 1.0 - smoothstep(
            safeTolerance, safeTolerance * 4.0, relativeHistoryDepth);
        float velocityConfidence = 1.0 - smoothstep(24.0, 96.0, velocityPixels);

        // Current hits may reuse either history state. A current miss may reuse
        // only a fresh hit, producing exactly one finite grace frame.
        bool historyLifetimeValid = currentHit ? historyHit : historyFresh;
        historyConfidence = depthConfidence * velocityConfidence
            * (historyLifetimeValid ? 1.0 : 0.0);

        // Receiver motion vectors locate the old pixel, but cannot make a
        // view-dependent reflected ray valid for the new camera direction.
        float viewMotionConfidence = 1.0 - smoothstep(0.35, 6.0, velocityPixels);
        historyConfidence *= viewMotionConfidence;

        float3 range = neighborhoodMax - neighborhoodMin;
        float3 neighborhoodMagnitude = max(abs(neighborhoodMin), abs(neighborhoodMax));
        float3 extent = max(range * 0.50, 0.015 + neighborhoodMagnitude * 0.08);
        float3 boundedHistory = clamp(
            history.rgb, neighborhoodMin - extent, neighborhoodMax + extent);
        // Even a static receiver can reflect a moving source. Keep an
        // always-on clamp, strongest on glossy materials where errors read as
        // sharp, disconnected images.
        float staticClamp = 0.55 + (1.0 - normalizedRoughness) * 0.30;
        float clampStrength = lerp(
            staticClamp, 1.0, smoothstep(0.5, 12.0, velocityPixels));
        historyDelta = lerp(history.rgb, boundedHistory, clampStrength);
    }

    float currentWeight = saturate(reflectionTemporalBlend);
    float viewMotionCurrentWeight = smoothstep(0.20, 3.0, velocityPixels);
    currentWeight = lerp(currentWeight, 1.0, viewMotionCurrentWeight);
    float historyBlend = historyConfidence * (1.0 - currentWeight);
    if (!currentHit)
    {
        historyBlend *= 0.35;
    }
    float3 accumulatedDelta = lerp(currentDelta, historyDelta, historyBlend);

    bool graceFrame = !currentHit && historyFresh
        && historyConfidence > 0.05
        && beamrtMaxAbs3(accumulatedDelta) > 0.00005;
    if (!currentHit && !graceFrame)
    {
        accumulatedDelta = 0.0;
    }
    float storedDepth = max(centerDecoded.w, 0.0001);
    float lifetimeAndDepth = currentHit ? storedDepth : (graceFrame ? -storedDepth : 0.0);
    return float4(accumulatedDelta, lifetimeAndDepth);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
