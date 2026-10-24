// v0.025 filters nonnegative, confidence-premultiplied reflected radiance.
// Alpha retains categorical lifetime and receiver forward depth in metres:
// positive is fresh, negative is one grace frame, zero is invalid. Physical
// depth avoids clamping close receivers to a far-plane-normalized floor.
#include "beamrtReflectionTemporal_v025.h.hlsl"
#ifdef BEAMRT_REFLECTION_HIT_AWARE
#include "beamrtReflectionHitPacking.h.hlsl"
#endif
#ifdef BEAMRT_REFLECTION_RECEIVER_HISTORY
#include "beamrtReflectionReceiverHistory.h.hlsl"

bool beamrtReflectionInputsLayoutValid()
{
    if (reflectionHitAwareEnabled <= 0.5) return true;
    if (!beamrtReceiverLogicalSizeValid(targetSize)) return false;
    uint width, height;
    velocityTexTex.GetDimensions(width, height);
    return width == uint(targetSize.x) && height == uint(targetSize.y * 2.0);
}

float4 beamrtReflectionMotionInputs(float2 transformedUV)
{
    float4 result = velocityTexTex.SampleLevel(velocityTex_sampler_, transformedUV, 0);
    uint width, height;
    velocityTexTex.GetDimensions(width, height);
    int2 logicalSize = max(int2(targetSize), int2(1, 1));
    if (reflectionHitAwareEnabled > 0.5)
    {
        result = 0.0;
        if (width == uint(logicalSize.x) && height == uint(logicalSize.y * 2))
        {
            float2 viewportUV = (transformedUV - rtParams3.xy) / rtParams3.zw;
            int2 pixel = clamp(int2(viewportUV * logicalSize), int2(0, 0), logicalSize - 1);
            result = velocityTexTex.Load(int3(pixel, 0));
        }
    }
    return result;
}

float beamrtReflectionPreviousReceiverConfidence(int2 pixel, float3 normalWS,
    float roughness, float3 specular)
{
    uint width, height;
    velocityTexTex.GetDimensions(width, height);
    int2 logicalSize = max(int2(targetSize), int2(1, 1));
    if (width != uint(logicalSize.x) || height != uint(logicalSize.y * 2)
        || any(pixel < 0) || any(pixel >= logicalSize)) return 0.0;
    float4 descriptor = velocityTexTex.Load(int3(pixel + int2(0, logicalSize.y), 0));
    return beamrtReceiverHistoryConfidence(descriptor, normalWS, roughness, specular);
}
#endif

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

#ifdef BEAMRT_REFLECTION_COLOR_FILTER
float3 beamrtReflectionHistoryColor(float2 uv, float depth, bool currentHit, float3 fallback
#ifdef BEAMRT_REFLECTION_RECEIVER_HISTORY
    , float3 normalWS, float roughness, float3 specular, bool validateReceiver
#endif
)
{
    float2 position = uv * targetSize - 0.5;
    int2 base = int2(floor(position));
    float2 phase = frac(position);
    int2 size = int2(targetSize);
    float3 sum = 0;
    float weights = 0;
    [unroll] for (int y = 0; y < 2; ++y)
    [unroll] for (int x = 0; x < 2; ++x)
    {
        int2 p = base + int2(x, y);
        if (all(p >= 0) && all(p < size))
        {
            float4 history = historyReflectionTexTex.Load(int3(p, 0));
            if (!all(isfinite(history))) continue;
            bool valid = currentHit ? abs(history.a) > 0.000001 : history.a > 0.000001;
            float error = abs(abs(history.a) - depth) / max(depth, 0.0001);
            float tolerance = max(reflectionHistoryDepthTolerance, 0.0001);
            float2 axis = lerp(1.0 - phase, phase, float2(x, y));
            float weight = valid ? axis.x * axis.y
                * (1.0 - smoothstep(tolerance, tolerance * 4.0, error)) : 0.0;
#ifdef BEAMRT_REFLECTION_RECEIVER_HISTORY
            if (validateReceiver)
            {
                float receiverWeight = beamrtReflectionPreviousReceiverConfidence(p, normalWS, roughness, specular);
                if (!(receiverWeight > 0.0)) continue;
                weight *= receiverWeight;
            }
#endif
            sum += history.rgb * weight;
            weights += weight;
        }
    }
    // Color only. Signed lifetime/depth and packed hits never interpolate.
    return weights > 0.0001 ? sum / weights : fallback;
}
#endif

#ifdef BEAMRT_REFLECTION_HIT_AWARE
float beamrtHitRealDepth(float2 viewportUV)
{
    float2 depthUV = viewportCoordToRenderTarget(viewportUV, rtParams2);
    float depth = ndcToRealDepth(tex2D(prepassDepthTex, depthUV).r, projParams.zw);
    return depth > 0.0 && depth < projParams.y * 0.9999 ? depth : projParams.y;
}

float3 beamrtHitEyeRay(float2 hitUV, float2 receiverUV, float3 eyeRay,
    float3 eyeDx, float3 eyeDy, float2 viewportStep)
{
    float2 pixelOffset = (hitUV - receiverUV) / viewportStep;
    return eyeRay + eyeDx * pixelOffset.x + eyeDy * pixelOffset.y;
}

float beamrtHitSourceHistoryConfidence(float4 previousInputs, float currentPacked,
    bool stationaryCamera, float2 imageSize)
{
    float confidence = 1.0;
    if (beamrtHasHitUV(currentPacked))
    {
        float2 hitUV = beamrtUnpackHitUV(currentPacked);
#ifdef BEAMRT_REFLECTION_RECEIVER_HISTORY
        float2 sourceVelocity = beamrtReflectionMotionInputs(viewportCoordToRenderTarget(hitUV, rtParams3)).xy;
#else
        float2 sourceVelocity = tex2D(velocityTex, viewportCoordToRenderTarget(hitUV, rtParams3)).xy;
#endif
        confidence *= 1.0 - smoothstep(0.35, 3.0, length(sourceVelocity * imageSize));
    }
    // Old screen coordinates are meaningful only while the camera is still.
    // Never compare two independent GGX hit distances frame-to-frame.
    if (stationaryCamera && beamrtHasHitUV(previousInputs.z) && previousInputs.w > 0.0)
    {
        float2 hitUV = beamrtUnpackHitUV(previousInputs.z);
#ifdef BEAMRT_REFLECTION_RECEIVER_HISTORY
        float2 sourceVelocity = beamrtReflectionMotionInputs(viewportCoordToRenderTarget(hitUV, rtParams3)).xy;
#else
        float2 sourceVelocity = tex2D(velocityTex, viewportCoordToRenderTarget(hitUV, rtParams3)).xy;
#endif
        confidence *= 1.0 - smoothstep(0.35, 3.0, length(sourceVelocity * imageSize));
        // One-pixel neighborhood protects quantized UV and depth-edge samples.
        // A disoccluded old source must disagree at ALL five probes to reject.
        float oldDepth = previousInputs.w;
        float error = abs(beamrtHitRealDepth(hitUV) - oldDepth);
        error = min(error, abs(beamrtHitRealDepth(saturate(hitUV + float2(1.0 / imageSize.x, 0.0))) - oldDepth));
        error = min(error, abs(beamrtHitRealDepth(saturate(hitUV - float2(1.0 / imageSize.x, 0.0))) - oldDepth));
        error = min(error, abs(beamrtHitRealDepth(saturate(hitUV + float2(0.0, 1.0 / imageSize.y))) - oldDepth));
        error = min(error, abs(beamrtHitRealDepth(saturate(hitUV - float2(0.0, 1.0 / imageSize.y))) - oldDepth));
        float tolerance = max(0.02, oldDepth * 0.003);
        confidence *= 1.0 - smoothstep(tolerance, tolerance * 4.0, error);
    }
    return confidence;
}
#endif

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float4 rawCurrent = tex2D(currentReflectionTex, IN.uv0);
    if (!all(isfinite(rawCurrent))) return 0.0;
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
#ifdef BEAMRT_REFLECTION_GGX_HISTORY
    bool useGGXEstimator = reflectionSamplingMode > 0.5;
    float3 estimatorToEye = normalize(-IN.wsEyeRay);
    bool receiverEstimatorEligible = centerRoughness < max(reflectionMaxRoughness, 0.021)
        && dot(centerDecoded.xyz, estimatorToEye) > 0.001;
    if (useGGXEstimator && !receiverEstimatorEligible) return 0.0;
#endif
#ifdef BEAMRT_REFLECTION_GGX_PLAYABLE_RECONSTRUCTION
    bool usePlayableGGX = useGGXEstimator && reflectionReconstructionMode > 0.5;
#endif
#ifdef BEAMRT_REFLECTION_HIT_AWARE
    bool useHitAware = usePlayableGGX && reflectionHitAwareEnabled > 0.5;
    float2 receiverViewportUV = (IN.uv0 - rtParams0.xy) / rtParams0.zw;
    float3 hitEyeDx = ddx(IN.wsEyeRay), hitEyeDy = ddy(IN.wsEyeRay);
    float2 viewportStep = float2(ddx(receiverViewportUV.x), ddy(receiverViewportUV.y));
    bool hitDerivativesValid = abs(viewportStep.x) > 0.00000001 && abs(viewportStep.y) > 0.00000001;
    float centerHitDistance = 0.0;
    bool centerGeometryValid = useHitAware && hitDerivativesValid && beamrtHasHitUV(rawCurrent.a);
    [branch] if (centerGeometryValid && centerRoughness < 0.14)
    {
        float2 hitUV = beamrtUnpackHitUV(rawCurrent.a);
        float depth = beamrtHitRealDepth(hitUV);
        float3 hitRay = beamrtHitEyeRay(hitUV, receiverViewportUV, IN.wsEyeRay, hitEyeDx, hitEyeDy, viewportStep);
        centerHitDistance = length(hitRay * (depth / projParams.y) - IN.wsEyeRay * centerDecoded.w);
    }
#endif
    // PFX provides four independent RT transforms. RT0 and RT1 are matching
    // prepass MRTs, so the RT0 coordinates are intentionally shared here.
    float3 centerSpecular = saturate(tex2D(materialSpecTex, IN.uv1).rgb);
    float normalizedRoughness = saturate(
        centerRoughness / max(reflectionMaxRoughness, 0.05));
    float filterRadiusPixels = lerp(
        1.0, 3.5, normalizedRoughness * normalizedRoughness);
#ifdef BEAMRT_REFLECTION_TUNING
    // Only playable GGX; no mirror/legacy history changes or metadata blending.
    if (usePlayableGGX) filterRadiusPixels *= clamp(reflectionFilterRadiusScale, 0.25, 3.0);
#endif

    float3 filteredSum = 0.0;
    float weightSum = 0.0;
    float3 neighborhoodMin = 0.0;
    float3 neighborhoodMax = 0.0;
    bool hasNeighborhoodHit = false;
    float safeCenterDepth = max(centerDecoded.w, 0.0000001);
    float centerRealDepth = centerDecoded.w * max(projParams.y, 0.001);
    if (centerRealDepth >= 65504.0) return 0.0; // R16F history depth capacity

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
        // Unsupported/zero-weight neighbors must not poison the sum through
        // Inf*0 or NaN*0. Valid zero GGX samples remain in the denominator.
        if (!all(isfinite(sampleReflection))) continue;
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
#ifdef BEAMRT_REFLECTION_COLOR_FILTER
        if (usePlayableGGX && reflectionColorFilterEnabled > 0.5)
            normalWeight = pow(saturate(dot(centerDecoded.xyz, sampleDecoded.xyz)),
                lerp(24.0, 8.0, smoothstep(0.04, 0.20, centerRoughness)));
#endif
        float roughnessWeight = 1.0 - smoothstep(
            0.015, 0.18, abs(max(samplePacked.b, 0.02) - centerRoughness));
        float specularWeight = 1.0 - smoothstep(
            0.02, 0.35, length(sampleSpecular - centerSpecular));
        float sampleConfidence = saturate(sampleReflection.a);
        float spatialWeight = exp2(-0.35 * dot(filterOffsets[tapIndex], filterOffsets[tapIndex]));
        float surfaceWeight = depthWeight * normalWeight * roughnessWeight * specularWeight;
        float weight = surfaceWeight * sqrt(sampleConfidence) * spatialWeight;
#ifdef BEAMRT_REFLECTION_GGX_HISTORY
        // Trace RGB already contains geometry confidence and the Monte Carlo
        // weight. A below-hemisphere ray or SSR miss is a valid zero estimator
        // sample, so its compatible receiver must remain in the denominator.
        // Across this small receiver footprint use the center view direction for the
        // neighbor's eligibility; no reflected hit-distance metadata is implied.
        bool sampleEstimatorEligible = sampleDecoded.w < 0.9999
            && max(samplePacked.b, 0.02) < max(reflectionMaxRoughness, 0.021)
            && dot(sampleDecoded.xyz, estimatorToEye) > 0.001;
        if (useGGXEstimator)
            weight = sampleEstimatorEligible ? surfaceWeight * spatialWeight : 0.0;
#endif
#ifdef BEAMRT_REFLECTION_HIT_AWARE
        // Near-polished reflections must not blur across distinct hit layers.
        // Rough lobes legitimately cover multiple layers, so disable this gate
        // by roughness .14. Eligible zero samples keep their original weight.
        [branch] if (centerGeometryValid && centerRoughness < 0.14
            && sampleEstimatorEligible && beamrtHasHitUV(sampleReflection.a))
        {
            float2 hitUV = beamrtUnpackHitUV(sampleReflection.a);
            float depth = beamrtHitRealDepth(hitUV);
            float3 hitRay = beamrtHitEyeRay(hitUV, receiverViewportUV, IN.wsEyeRay, hitEyeDx, hitEyeDy, viewportStep);
            float3 sampleEyeRay = IN.wsEyeRay + hitEyeDx * offsetPixels.x + hitEyeDy * offsetPixels.y;
            float3 receiverTravel = sampleEyeRay * sampleDecoded.w - IN.wsEyeRay * centerDecoded.w;
            float distanceToHit = length(hitRay * (depth / projParams.y) - sampleEyeRay * sampleDecoded.w);
            float tolerance = max(0.05, min(centerHitDistance, distanceToHit)
                * (0.005 + 8.0 * centerRoughness * centerRoughness)) + length(receiverTravel);
            float layerWeight = 1.0 - smoothstep(tolerance, tolerance * 4.0, abs(distanceToHit - centerHitDistance));
            float detailStrength = 1.0 - smoothstep(0.04, 0.14, centerRoughness);
            weight *= lerp(1.0, layerWeight, detailStrength);
        }
#endif
        filteredSum += sampleReflection.rgb * weight;
        weightSum += weight;

        // Mirror mode uses only material-compatible actual hits for the clamp.
        // Its misses and samples rejected by bilateral gates cannot widen it.
        bool sampleSupportsHistory = surfaceWeight > 0.05 && sampleConfidence > 0.005;
#ifdef BEAMRT_REFLECTION_GGX_HISTORY
        // GGX bounds instead include compatible eligible estimator samples,
        // including zero. The existing clamp is still an approximate denoiser.
        if (useGGXEstimator)
            sampleSupportsHistory = surfaceWeight > 0.05 && sampleEstimatorEligible;
#endif
        if (sampleSupportsHistory)
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
#ifdef BEAMRT_REFLECTION_GGX_PLAYABLE_RECONSTRUCTION
    // Use the complete existing bilateral estimate at the usual 0.5 setting.
    // Explicit zero still supplies the raw current sample. Receiver weights
    // and all eligible zero samples are unchanged; add no confidence/F0 gain.
    if (usePlayableGGX) denoiseAmount = saturate(2.0 * reflectionDenoiseStrength);
#endif
    float3 currentRadiance = lerp(rawCurrent.rgb, filteredCurrent, denoiseAmount);
    // Mirror spatial support may reconstruct color, but only a ray from this
    // exact pixel is allowed to refresh its geometric history lifetime.
#ifdef BEAMRT_REFLECTION_VALID_BLACK_HITS
    // Accepted geometry is valid even when its weighted radiance is black.
    bool currentHit = saturate(rawCurrent.a) > 0.015;
#else
    bool currentHit = saturate(rawCurrent.a) > 0.015
        && beamrtMaxAbs3(rawCurrent.rgb) > 0.00005;
#endif
#ifdef BEAMRT_REFLECTION_GGX_HISTORY
    // In GGX mode this means a valid estimator sample, not a geometric hit.
    // Zero samples refresh the estimate rather than entering a stale grace frame.
    if (useGGXEstimator) currentHit = receiverEstimatorEligible;
#endif

    if (!hasNeighborhoodHit)
    {
        neighborhoodMin = rawCurrent.rgb;
        neighborhoodMax = rawCurrent.rgb;
    }

#ifdef BEAMRT_REFLECTION_RECEIVER_HISTORY
    bool validateReceiverHistory = useHitAware && reflectionReceiverHistoryEnabled > 0.5;
    bool receiverInputLayoutValid = beamrtReflectionInputsLayoutValid();
    float2 velocity = beamrtReflectionMotionInputs(IN.uv3).xy;
#else
    float2 velocity = tex2D(velocityTex, IN.uv3).xy;
#endif
    float2 previousUv = IN.uv0 + velocity;
    float velocityPixels = length(velocity * targetSize);
#ifdef BEAMRT_REFLECTION_HIT_AWARE
    float hitSourceConfidence = 1.0;
    [branch] if (useHitAware)
    {
#ifdef BEAMRT_REFLECTION_RECEIVER_HISTORY
        float4 oldHitInputs = beamrtReflectionMotionInputs(IN.uv3);
#else
        float4 oldHitInputs = tex2D(velocityTex, IN.uv3);
#endif
        hitSourceConfidence = beamrtHitSourceHistoryConfidence(oldHitInputs, rawCurrent.a,
            reflectionCameraMotion <= 0.0001, targetSize);
    }
#endif
    bool previousUvValid = all(previousUv >= 0.0) && all(previousUv <= 1.0);

    float historyConfidence = 0.0;
    float3 historyRadiance = currentRadiance;
    bool historyFresh = false;
    bool historyGrace = false;
    if (reflectionHistoryValid > 0.5 && previousUvValid && velocityPixels <= 96.0
#ifdef BEAMRT_REFLECTION_RECEIVER_HISTORY
        && receiverInputLayoutValid
#endif
    )
    {
        // Lifetime is categorical, so read one exact history texel. Linear
        // filtering could otherwise invent a grace frame between fresh and
        // invalid neighbors.
        int2 historyMaxPixel = max(int2(targetSize) - 1, int2(0, 0));
        int2 historyPixel = clamp(int2(previousUv * targetSize), int2(0, 0), historyMaxPixel);
        float4 history = historyReflectionTexTex.Load(int3(historyPixel, 0));
        // Do not let rejected history enter a zero-factor lerp. Invalid data
        // leaves currentRadiance and its geometric lifetime untouched.
        if (all(isfinite(history)))
        {
        historyFresh = history.a > 0.000001;
        historyGrace = history.a < -0.000001;
        bool historyHit = historyFresh || historyGrace;
        float historyDepth = abs(history.a);
        float relativeHistoryDepth = abs(historyDepth - centerRealDepth) / max(centerRealDepth, 0.0001);
        float safeTolerance = max(reflectionHistoryDepthTolerance, 0.0001);
        float depthConfidence = 1.0 - smoothstep(
            safeTolerance, safeTolerance * 4.0, relativeHistoryDepth);
        float velocityConfidence = 1.0 - smoothstep(24.0, 96.0, velocityPixels);

        // Current hits may reuse either history state. A current miss may reuse
        // only a fresh hit, producing exactly one finite grace frame.
        bool historyLifetimeValid = currentHit ? historyHit : historyFresh;
        historyConfidence = depthConfidence * velocityConfidence
            * (historyLifetimeValid ? 1.0 : 0.0);
#ifdef BEAMRT_REFLECTION_RECEIVER_HISTORY
        if (validateReceiverHistory)
            historyConfidence *= beamrtReflectionPreviousReceiverConfidence(historyPixel,
                centerDecoded.xyz, centerRoughness, centerSpecular);
#endif

        // Receiver motion vectors locate the old pixel, but cannot make a
        // view-dependent reflected ray valid for the new camera direction.
        float viewMotionConfidence = 1.0 - smoothstep(0.35, 6.0, velocityPixels);
        // Real camera motion remains available when native velocity is zero
        // or stale for a particular render view. Prefer live reflected rays.
        viewMotionConfidence *= 1.0 - smoothstep(0.0, 0.20,
            saturate(reflectionCameraMotion));
        historyConfidence *= viewMotionConfidence;
#ifdef BEAMRT_REFLECTION_HIT_AWARE
        if (useHitAware) historyConfidence *= hitSourceConfidence;
#endif

#ifdef BEAMRT_REFLECTION_GGX_PLAYABLE_RECONSTRUCTION
        if (usePlayableGGX)
        {
            // Current-only random neighborhoods are not authoritative color
            // bounds. In particular, a zero neighborhood must not erase rare
            // bright energy accumulated in valid stationary history. Existing
            // geometry and motion rejection still controls historyConfidence.
            historyRadiance = history.rgb;
#ifdef BEAMRT_REFLECTION_COLOR_FILTER
            if (reflectionColorFilterEnabled > 0.5)
                historyRadiance = beamrtReflectionHistoryColor(previousUv, centerRealDepth, currentHit,
#ifdef BEAMRT_REFLECTION_RECEIVER_HISTORY
                    validateReceiverHistory ? currentRadiance : history.rgb,
                    centerDecoded.xyz, centerRoughness, centerSpecular, validateReceiverHistory
#else
                    history.rgb
#endif
                );
#endif
        }
        else
#endif
        {
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
        historyRadiance = lerp(history.rgb, boundedHistory, clampStrength);
        }
        }
    }

    float currentWeight = saturate(reflectionTemporalBlend);
#ifdef BEAMRT_REFLECTION_GGX_HISTORY
    // A bounded exponential mean must keep accepting zero and nonzero samples.
    if (useGGXEstimator) currentWeight = max(currentWeight, 1.0 / 64.0);
#endif
#ifdef BEAMRT_REFLECTION_GGX_PLAYABLE_RECONSTRUCTION
    if (usePlayableGGX)
    {
        // Short, frame-time-independent rolling history, not a long exposure.
        // User 0.25 maps to 0.125 at 60Hz; the minimum never freezes history,
        // and user 1 remains immediate. Static source changes decay normally.
        float userWeight = saturate(reflectionTemporalBlend);
        float weight60 = clamp(userWeight * sqrt(userWeight), 0.10, 1.0);
#ifdef BEAMRT_REFLECTION_LAB
        // Opt-in bounded laboratory EMA. Zero/unset preserves the production
        // floor exactly; motion, material/depth rejection and valid zeros stay.
        if ((asuint(reflectionLabCurrentWeight) & 0x7f800000u) != 0x7f800000u
            && reflectionLabCurrentWeight > 0.0)
            weight60 = clamp(reflectionLabCurrentWeight, 1.0 / 64.0, 1.0);
#endif
        float frameDelta = clamp(reflectionFrameDelta, 1.0 / 240.0, 1.0 / 15.0);
        currentWeight = 1.0 - pow(1.0 - weight60, frameDelta * 60.0);
    }
#endif
    float viewMotionCurrentWeight = smoothstep(0.20, 3.0, velocityPixels);
    viewMotionCurrentWeight = max(viewMotionCurrentWeight,
        smoothstep(0.0, 0.20, saturate(reflectionCameraMotion)));
    currentWeight = lerp(currentWeight, 1.0, viewMotionCurrentWeight);
    float historyBlend = historyConfidence * (1.0 - currentWeight);
    if (!currentHit)
    {
        historyBlend *= 0.35;
    }
    float3 accumulatedRadiance = lerp(currentRadiance, historyRadiance, historyBlend);

    bool graceFrame = !currentHit && historyFresh
        && historyConfidence > 0.05
        && beamrtMaxAbs3(accumulatedRadiance) > 0.00005;
    if (!currentHit && !graceFrame)
    {
        accumulatedRadiance = 0.0;
    }
    float storedDepth = max(centerRealDepth, 0.0001);
#ifdef BEAMRT_REFLECTION_GGX_HISTORY
    // GGX positive alpha represents fresh receiver estimator history. Raw
    // trace alpha remains geometric confidence in every diagnostic view.
#endif
    float lifetimeAndDepth = currentHit ? storedDepth : (graceFrame ? -storedDepth : 0.0);
    return float4(max(accumulatedRadiance, 0.0), lifetimeAndDepth);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
