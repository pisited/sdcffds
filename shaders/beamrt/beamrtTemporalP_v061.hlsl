#define BEAMRT_PROGRESSIVE_ACCUMULATION 1
#include "beamrtTemporal.h.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

#ifdef BEAMRT_VARIANCE_GUIDED
float beamrtTemporalLuminance(float3 color)
{
    return dot(max(color, 0.0), float3(0.2126, 0.7152, 0.0722));
}
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
#ifdef BEAMRT_PRESERVE_HIT_CONFIDENCE
        return float4(0.0, 0.0, 0.0, 0.0);
#else
        return float4(0.0, 0.0, 0.0, 1.0);
#endif
    }

    float4 centerGI = tex2D(currentGITex, IN.uv0);
#ifdef BEAMRT_RAY_HIT_DIAGNOSTIC
    if (giTraceDebugMode > 0.5)
    {
#ifdef BEAMRT_PRESERVE_HIT_CONFIDENCE
        return float4(centerGI.rgb, saturate(centerGI.a));
#else
        return float4(centerGI.rgb, centerDecoded.w);
#endif
    }
#endif
    float3 rawCurrent = centerGI.rgb;
    float3 filteredSum = 0.0;
    float filterWeightSum = 0.0;
#ifdef BEAMRT_PRESERVE_HIT_CONFIDENCE
    float rawSupport = saturate(centerGI.a);
    float filteredSupportSum = 0.0;
#endif
    float3 neighborhoodMin = rawCurrent;
    float3 neighborhoodMax = rawCurrent;
#ifdef BEAMRT_COMPATIBLE_HISTORY_CLAMP
    float3 compatibleSum = 0.0;
    float3 compatibleSquareSum = 0.0;
    float compatibleSampleCount = 0.0;
#endif
    float safeCenterDepth = max(centerDecoded.w, 0.0001);
    bool spatialFilterEnabled = denoiseStrength > 0.0001;
#ifdef BEAMRT_VARIANCE_GUIDED
    float4 centerMoments = tex2D(momentsTex, IN.uv0);
    float variance = max(centerMoments.g - centerMoments.r * centerMoments.r, 0.0);
    float varianceSigma = sqrt(variance);
    float varianceResponse = saturate(varianceSigma * max(svgfVarianceScale, 0.0));
    float varianceGuide = saturate(svgfStrength);
    spatialFilterEnabled = spatialFilterEnabled || varianceGuide > 0.0001;
#endif

    [unroll]
    for (int y = -1; y <= 1; ++y)
    {
        [unroll]
        for (int x = -1; x <= 1; ++x)
        {
            bool centerSample = x == 0 && y == 0;
            float2 offset = float2((float)x, (float)y) * oneOverTargetSize;
            float2 giUv = IN.uv0 + offset;
            float4 sampleGI = centerSample ? centerGI : tex2D(currentGITex, giUv);

            float4 sampleDecoded = centerDecoded;
            if (!centerSample && (spatialFilterEnabled
#ifdef BEAMRT_COMPATIBLE_HISTORY_CLAMP
                || historyValid > 0.5
#endif
                ))
            {
                sampleDecoded = decodeGBuffer(
                    TEX_SAMPLER(prepassDepthTex),
                    TEX_SAMPLER(prepassTex),
                    IN.uv1 + offset,
                    projParams
                );
            }

            float relativeDepthDelta = abs(sampleDecoded.w - centerDecoded.w) / safeCenterDepth;
            float normalAgreement = saturate(dot(centerDecoded.xyz, sampleDecoded.xyz));
#ifdef BEAMRT_COMPATIBLE_HISTORY_CLAMP
            // The old temporal bounds included every color in the 3x3 tile before
            // checking geometry. At silhouettes that let bright road markings widen
            // the clamp used by a dark vehicle, so the marking could be reprojected
            // as an orange band while the camera moved. Build bounds and statistics
            // only from samples that plausibly belong to the receiver surface.
            bool surfaceCompatible = centerSample
                || (sampleDecoded.w < 0.9999
                    && relativeDepthDelta < 0.02
                    && normalAgreement > 0.90);
            if (surfaceCompatible)
            {
                neighborhoodMin = min(neighborhoodMin, sampleGI.rgb);
                neighborhoodMax = max(neighborhoodMax, sampleGI.rgb);
                compatibleSum += sampleGI.rgb;
                compatibleSquareSum += sampleGI.rgb * sampleGI.rgb;
                compatibleSampleCount += 1.0;
            }
#else
            neighborhoodMin = min(neighborhoodMin, sampleGI.rgb);
            neighborhoodMax = max(neighborhoodMax, sampleGI.rgb);
#endif

            if (spatialFilterEnabled)
            {

                float depthWeight = 1.0 - smoothstep(0.002, 0.03, relativeDepthDelta);
                float normalWeight = pow(normalAgreement, 16.0);
#ifdef BEAMRT_PRESERVE_HIT_CONFIDENCE
                float sampleSupport = saturate(sampleGI.a);
                float hitWeight = centerSample
                    ? lerp(0.05, 1.0, sampleSupport)
                    : smoothstep(0.02, 0.45, sampleSupport);
#else
                float hitWeight = lerp(0.20, 1.0, saturate(sampleGI.a));
#endif
                float spatialWeight = centerSample ? 2.0 : 1.0;
                float weight = depthWeight * normalWeight * hitWeight * spatialWeight;
#ifdef BEAMRT_VARIANCE_GUIDED
                if (!centerSample && varianceGuide > 0.0001)
                {
                    float luminanceDelta = abs(beamrtTemporalLuminance(sampleGI.rgb) - centerMoments.r);
                    float luminanceWeight = exp(-luminanceDelta / max(0.015 + varianceSigma * 2.0, 0.015));
                    weight *= lerp(1.0, luminanceWeight, varianceGuide);
                }
#endif
                filteredSum += sampleGI.rgb * weight;
                filterWeightSum += weight;
#ifdef BEAMRT_PRESERVE_HIT_CONFIDENCE
                filteredSupportSum += sampleSupport * weight;
#endif
            }
        }
    }

#ifdef BEAMRT_LOW_PATH_RESCUE
    // At low path counts, sixteen extra bilateral texture taps are much cheaper
    // than tracing twelve more rays (each ray may perform hundreds of depth
    // samples). This outer ring is depth/normal aware and fades away by twelve
    // paths, leaving higher-path rendering on the original 3x3 reconstruction.
    float lowPathFactor = saturate(lowPathRescue)
        * (1.0 - smoothstep(4.0, 12.0, progressivePathCount));
    if (spatialFilterEnabled && lowPathFactor > 0.0001)
    {
        static const float2 outerRing[16] = {
            float2(-2.0, -2.0), float2(-1.0, -2.0), float2(0.0, -2.0), float2(1.0, -2.0),
            float2( 2.0, -2.0), float2(-2.0, -1.0), float2(2.0, -1.0), float2(-2.0,  0.0),
            float2( 2.0,  0.0), float2(-2.0,  1.0), float2(2.0,  1.0), float2(-2.0,  2.0),
            float2(-1.0,  2.0), float2( 0.0,  2.0), float2(1.0,  2.0), float2( 2.0,  2.0)
        };

        [unroll]
        for (int ringIndex = 0; ringIndex < 16; ++ringIndex)
        {
            float2 offset = outerRing[ringIndex] * oneOverTargetSize;
            float4 sampleGI = tex2D(currentGITex, IN.uv0 + offset);
            float4 sampleDecoded = decodeGBuffer(
                TEX_SAMPLER(prepassDepthTex),
                TEX_SAMPLER(prepassTex),
                IN.uv1 + offset,
                projParams
            );
            float relativeDepthDelta = abs(sampleDecoded.w - centerDecoded.w) / safeCenterDepth;
            float depthWeight = 1.0 - smoothstep(0.0015, 0.025, relativeDepthDelta);
            float normalWeight = pow(saturate(dot(centerDecoded.xyz, sampleDecoded.xyz)), 24.0);
#ifdef BEAMRT_PRESERVE_HIT_CONFIDENCE
            float sampleSupport = saturate(sampleGI.a);
            float hitWeight = smoothstep(0.05, 0.55, sampleSupport);
#else
            float hitWeight = lerp(0.15, 1.0, saturate(sampleGI.a));
#endif
            float weight = depthWeight * normalWeight * hitWeight * lowPathFactor * 0.65;
#ifdef BEAMRT_VARIANCE_GUIDED
            if (varianceGuide > 0.0001)
            {
                float luminanceDelta = abs(beamrtTemporalLuminance(sampleGI.rgb) - centerMoments.r);
                float luminanceWeight = exp(-luminanceDelta / max(0.02 + varianceSigma * 2.5, 0.02));
                weight *= lerp(1.0, luminanceWeight, varianceGuide);
            }
#endif
            filteredSum += sampleGI.rgb * weight;
            filterWeightSum += weight;
#ifdef BEAMRT_PRESERVE_HIT_CONFIDENCE
            filteredSupportSum += sampleSupport * weight;
#endif
        }
    }
#endif

    float3 filteredCurrent = spatialFilterEnabled && filterWeightSum > 0.0001
        ? filteredSum / filterWeightSum
        : rawCurrent;
    float effectiveDenoise = saturate(denoiseStrength);
#ifdef BEAMRT_VARIANCE_GUIDED
    effectiveDenoise = max(effectiveDenoise, varianceResponse * varianceGuide);
#endif
    float3 currentGI = lerp(rawCurrent, filteredCurrent, effectiveDenoise);
#ifdef BEAMRT_PRESERVE_HIT_CONFIDENCE
    float filteredSupport = filterWeightSum > 0.0001
        ? filteredSupportSum / filterWeightSum
        : rawSupport;
    float currentSupport = saturate(lerp(rawSupport, filteredSupport, effectiveDenoise));
#endif
    float2 velocity = tex2D(velocityTex, IN.uv3).xy;
    float2 previousUv = IN.uv0 + velocity;
    float velocityPixels = length(velocity * targetSize);
    bool previousUvValid = all(previousUv >= 0.0) && all(previousUv <= 1.0);

    float historyConfidence = 0.0;
    float3 historyGI = currentGI;
#ifdef BEAMRT_PRESERVE_HIT_CONFIDENCE
    float historySupport = currentSupport;
#endif
    if (historyValid > 0.5 && previousUvValid && velocityPixels <= 96.0)
    {
        float4 history = tex2D(historyTex, previousUv);
#ifdef BEAMRT_PRESERVE_HIT_CONFIDENCE
        float historyDepth = tex2D(historyMomentsTex, previousUv).a;
        float relativeHistoryDepth = abs(historyDepth - centerDecoded.w) / safeCenterDepth;
        historySupport = saturate(history.a);
#else
        float relativeHistoryDepth = abs(history.a - centerDecoded.w) / safeCenterDepth;
#endif
        float safeTolerance = max(historyDepthTolerance, 0.0001);
        float depthConfidence = 1.0 - smoothstep(safeTolerance, safeTolerance * 4.0, relativeHistoryDepth);
        float velocityConfidence = 1.0 - smoothstep(32.0, 96.0, velocityPixels);
        historyConfidence = depthConfidence * velocityConfidence;
#ifdef BEAMRT_ECHO_HISTORY_GUARD
        // The current GI alpha is a coverage/confidence signal from the tracer.
        // Do not punish stationary stochastic misses, because progressive/SVGF
        // accumulation needs them. During motion, however, weak current support
        // is exactly where an old reprojected GI image turns into a visible
        // offset echo. Blend this gate with the legacy path so strength zero is
        // identical to v0.063.
        float echoGuard = saturate(echoHistoryGuard);
        float motionActivity = smoothstep(0.25, 2.0, velocityPixels);
#ifdef BEAMRT_CAMERA_MOTION_GUARD
        // The BeamNG velocity target is not trustworthy for every camera/view
        // configuration. A real-camera delta supplied by Lua prevents a near-zero
        // sampled velocity from preserving an entire stale GI frame while the
        // viewpoint is visibly moving.
        motionActivity = max(motionActivity, saturate(cameraMotion));
#endif
        float currentHitSupport = smoothstep(0.02, 0.35, saturate(centerGI.a));
        float currentSupportGate = lerp(1.0, currentHitSupport, echoGuard * motionActivity);
        historyConfidence *= currentSupportGate;
#ifdef BEAMRT_CAMERA_MOTION_GUARD
        // Preserve a small amount of history for continuity, but strongly prefer
        // the live frame during camera motion. Stationary long-exposure behavior
        // remains unchanged because cameraMotion is zero without real movement.
        float cameraHistoryScale = lerp(1.0, 0.08, echoGuard * saturate(cameraMotion));
        historyConfidence *= cameraHistoryScale;
#endif
#endif

        float3 neighborhoodRange = neighborhoodMax - neighborhoodMin;
        float3 clampExtent = max(neighborhoodRange * 0.5, 0.025);
#ifdef BEAMRT_VARIANCE_GUIDED
        clampExtent = max(clampExtent, varianceSigma * max(svgfVarianceScale, 0.0) * varianceGuide);
#endif
        float3 historyClampMin = neighborhoodMin - clampExtent;
        float3 historyClampMax = neighborhoodMax + clampExtent;
#ifdef BEAMRT_COMPATIBLE_HISTORY_CLAMP
        // A color-channel sigma envelope is intentionally used instead of a
        // luminance-only/desaturation clamp: legitimate colored bounce survives,
        // while a temporally displaced orange/blue sample cannot poison a dark
        // receiver simply because it was bright in a neighboring material.
        float safeCompatibleCount = max(compatibleSampleCount, 1.0);
        float3 compatibleMean = compatibleSum / safeCompatibleCount;
        float3 compatibleVariance = max(
            compatibleSquareSum / safeCompatibleCount - compatibleMean * compatibleMean,
            0.0
        );
        float3 compatibleSigma = sqrt(compatibleVariance);
        float3 robustExtent = max(compatibleSigma * 1.25 + 0.01, 0.018);
        float3 robustMin = compatibleMean - robustExtent;
        float3 robustMax = compatibleMean + robustExtent;
        float robustMotionStrength = saturate(echoHistoryGuard)
            * smoothstep(0.25, 6.0, velocityPixels);
#ifdef BEAMRT_CAMERA_MOTION_GUARD
        robustMotionStrength = max(
            robustMotionStrength,
            saturate(echoHistoryGuard) * saturate(cameraMotion)
        );
#endif
        historyClampMin = lerp(historyClampMin, max(historyClampMin, robustMin), robustMotionStrength);
        historyClampMax = lerp(historyClampMax, min(historyClampMax, robustMax), robustMotionStrength);

        float3 normalizedHistoryDelta = abs(history.rgb - compatibleMean) / max(robustExtent, 0.018);
        float historyOutlier = max(normalizedHistoryDelta.r, max(normalizedHistoryDelta.g, normalizedHistoryDelta.b));
        float outlierConfidence = 1.0 - smoothstep(1.5, 4.0, historyOutlier);
        historyConfidence *= lerp(1.0, outlierConfidence, robustMotionStrength);
#endif
        float3 boundedHistory = clamp(history.rgb, historyClampMin, historyClampMax);
        float motionClampStrength = smoothstep(1.0, 16.0, velocityPixels);
#ifdef BEAMRT_ECHO_HISTORY_GUARD
        // Clamp earlier during motion, but interpolate from the exact legacy
        // thresholds so echoHistoryGuard=0 remains a strict v0.063 A/B.
        float guardedMotionClamp = smoothstep(0.25, 8.0, velocityPixels);
        motionClampStrength = lerp(motionClampStrength, guardedMotionClamp, saturate(echoHistoryGuard));
#endif
        float clampStrength = progressiveEnabled > 0.5
            ? max(motionClampStrength, saturate(progressiveClampStrength))
            : motionClampStrength;
        historyGI = lerp(history.rgb, boundedHistory, clampStrength);
    }

    float currentWeight = progressiveEnabled > 0.5
        ? saturate(progressiveCurrentWeight)
        : saturate(temporalBlend);
    float3 accumulatedGI = lerp(currentGI, historyGI, historyConfidence * (1.0 - currentWeight));
#ifdef BEAMRT_PRESERVE_HIT_CONFIDENCE
    float accumulatedSupport = lerp(
        currentSupport,
        historySupport,
        historyConfidence * (1.0 - currentWeight));
    return float4(max(accumulatedGI, 0.0), saturate(accumulatedSupport));
#else
    return float4(max(accumulatedGI, 0.0), centerDecoded.w);
#endif
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
