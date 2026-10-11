// v0.061 experimental transport: long-sequence sampling, a selectable
// cosine-weighted estimator, locality shaping, and optional previous-GI reuse.
#define BEAMRT_DIRECT_DIFFUSE_SOURCE 1
#define BEAMRT_RADIANCE_CLEANUP_V056 1
#define BEAMRT_LIGHTINFO_SLOT3 1
#define BEAMRT_PTGI_CLEAN_SOURCE 1
#define BEAMRT_EXPERIMENTAL_TRANSPORT 1
#define main beamrtLegacyMain_v051
#ifdef SHADER_STAGE_VS
    #define mainP beamrtLegacyMainP_v051
#else
    #define mainV beamrtLegacyMainV_v051
#endif
#define beamrtTraceRay beamrtTraceRay_v051
#define beamrtDiffuseDirection beamrtDiffuseDirection_v051
#define beamrtTraceLightingSample beamrtTraceLightingSample_v051
#define beamrtSampleVisibleSurfelRadiance beamrtSampleVisibleSurfelRadiance_v051
#include "beamrtGITraceP_v065_base.hlsl"
#undef beamrtSampleVisibleSurfelRadiance
#undef beamrtTraceLightingSample
#undef beamrtDiffuseDirection
#undef beamrtTraceRay
#undef mainP
#undef mainV
#undef main

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

void beamrtSelectedSourceComponents(
    float2 prepassUv,
    float2 backbufferUv,
    out float3 reflectedRadiance,
    out float3 emissiveRadiance)
{
    reflectedRadiance = beamrtDiffuseLikeRadiance(prepassUv, backbufferUv);
    emissiveRadiance = 0.0;

    if (ptgiRadianceSourceMode > 0.5)
    {
        float3 cleanRadiance = max(
            tex2Dlod(cleanRadianceTex, float4(backbufferUv, 0.0, 0.0)).rgb,
            0.0);
        float3 nativeEmissive = max(
            tex2Dlod(maskedEmissiveTex, float4(backbufferUv, 0.0, 0.0)).rgb,
            0.0);

        // CleanRadiance already contains native emissive once. Split it back
        // into reflected and emitted terms so a BSDF-sampled path does not
        // accidentally apply the reflector-facing cosine to Material_Emissive.
        reflectedRadiance = max(cleanRadiance - nativeEmissive, 0.0);
        emissiveRadiance = nativeEmissive * max(giEmissiveBoost, 0.0);
    }

    if (giSecondBounceStrength > 0.0001 && giHistoryValid > 0.5)
    {
        float4 previousGI = tex2Dlod(previousGITex, float4(prepassUv, 0.0, 0.0));
        float sceneNdcDepth = tex2Dlod(prepassDepthTex, float4(prepassUv, 0.0, 0.0)).r;
        float sceneRealDepth = ndcToRealDepth(sceneNdcDepth, projParams.zw);
        float sceneEyeDepth = realToEyeLinearDepth(sceneRealDepth, projParams);
        float relativeDepthDelta = abs(previousGI.a - sceneEyeDepth) / max(sceneEyeDepth, 0.0001);
        float historyAgreement = 1.0 - smoothstep(0.01, 0.04, relativeDepthDelta);
        reflectedRadiance += beamrtClampRadiance(max(previousGI.rgb, 0.0))
            * max(giSecondBounceStrength, 0.0) * historyAgreement;
    }
}

float3 beamrtSelectedSourceRadiance(float2 prepassUv, float2 backbufferUv)
{
    float3 reflectedRadiance;
    float3 emissiveRadiance;
    beamrtSelectedSourceComponents(prepassUv, backbufferUv, reflectedRadiance, emissiveRadiance);
    return max(reflectedRadiance + emissiveRadiance, 0.0);
}

bool beamrtSampleVisibleSurfelRadiance(
    float3 surfelPosition,
    float3 surfelNormal,
    float3 currentEyeRay,
    float3 eyeRayDu,
    float3 eyeRayDv,
    float2 currentUv,
    out float3 radiance,
    out float confidence)
{
    radiance = 0.0;
    confidence = 0.0;
    float2 surfelUv;
    float surfelEyeDepth;
    if (!beamrtProjectEyeVector(
        surfelPosition - eyePosWorld,
        currentEyeRay,
        eyeRayDu,
        eyeRayDv,
        currentUv,
        surfelUv,
        surfelEyeDepth))
    {
        return false;
    }

    float2 viewportOtherCorner = rtParams0.xy + rtParams0.zw;
    float2 viewportMin = min(rtParams0.xy, viewportOtherCorner);
    float2 viewportMax = max(rtParams0.xy, viewportOtherCorner);
    if (surfelEyeDepth >= 0.9999 || any(surfelUv <= viewportMin) || any(surfelUv >= viewportMax))
    {
        return false;
    }

    float sceneNdcDepth = tex2Dlod(prepassDepthTex, float4(surfelUv, 0.0, 0.0)).r;
    float sceneRealDepth = ndcToRealDepth(sceneNdcDepth, projParams.zw);
    float sceneEyeDepth = realToEyeLinearDepth(sceneRealDepth, projParams);
    if (sceneEyeDepth >= 0.9999)
    {
        return false;
    }

    float tolerance = max(surfelVisibilityTolerance, 0.05);
    float depthDeltaWorld = abs(surfelEyeDepth - sceneEyeDepth) * projParams.y;
    if (depthDeltaWorld > tolerance)
    {
        return false;
    }

    float3 visibleNormal = decodeNormalXY(tex2Dlod(prepassTex, float4(surfelUv, 0.0, 0.0)).xy);
    float normalAgreement = dot(visibleNormal, surfelNormal);
    if (normalAgreement <= 0.2)
    {
        return false;
    }

    float2 backbufferUv = beamrtPrepassUvToBackbufferUv(surfelUv);
    radiance = beamrtSelectedSourceRadiance(surfelUv, backbufferUv);
    float depthConfidence = saturate(1.0 - depthDeltaWorld / tolerance);
    float normalConfidence = saturate((normalAgreement - 0.2) / 0.8);
    confidence = depthConfidence * normalConfidence * beamrtScreenEdgeConfidence(surfelUv);
    return confidence > 0.0001;
}

#ifdef BEAMRT_ADAPTIVE_RAY_BUDGET
float beamrtAdaptiveRayReach(float3 rayDirection, float3 currentEyeRay)
{
    // currentEyeRay points from the camera into the visible scene. Rays with a
    // negative alignment head back toward/behind the camera and usually leave
    // useful screen-space coverage quickly. Keep a small near-field budget for
    // local color bounce without paying the full deep-scene march distance.
    float viewAlignment = dot(normalize(rayDirection), normalize(currentEyeRay));
    float rearAmount = saturate(-viewAlignment);
    float rearScale = lerp(1.0, clamp(giRearRayReach, 0.02, 1.0), rearAmount);
    return clamp(giRayReach, 0.05, 1.0) * rearScale;
}
#endif

#ifdef BEAMRT_HIT_VALIDATION
// Reject-reason values used by the raw diagnostic:
// 0 accepted, 1 no crossing, 2 near-origin/self, 3 background/hole,
// 4 backface, 5 depth error, 6 screen edge, 7 local discontinuity,
// 8 outside the viewport.
void beamrtValidateScreenHit(
    inout BeamRTRayHit candidate,
    float3 rayOrigin,
    float3 rayDirection,
    float3 currentEyeRay,
    float3 eyeRayDu,
    float3 eyeRayDv,
    float2 currentUv,
    float safeThickness,
    out float hitConfidence,
    out float depthError,
    out float rejectReason,
    out float3 hitNormal)
{
    hitConfidence = 0.0;
    depthError = safeThickness * 2.0;
    rejectReason = 1.0;
    hitNormal = float3(0.0, 0.0, 1.0);
    if (candidate.hit < 0.5)
    {
        return;
    }

    float validationStrength = saturate(giHitValidationStrength);
    if (validationStrength <= 0.0001)
    {
        hitConfidence = 1.0;
        rejectReason = 0.0;
        hitNormal = decodeNormalXY(tex2Dlod(prepassTex, float4(candidate.uv, 0.0, 0.0)).xy);
        return;
    }

    float2 viewportOtherCorner = rtParams0.xy + rtParams0.zw;
    float2 viewportMin = min(rtParams0.xy, viewportOtherCorner);
    float2 viewportMax = max(rtParams0.xy, viewportOtherCorner);
    if (any(candidate.uv <= viewportMin) || any(candidate.uv >= viewportMax))
    {
        candidate.hit = 0.0;
        rejectReason = 8.0;
        return;
    }

    float pixelTravel = length((candidate.uv - currentUv) * max(targetSize, 1.0));
    float minimumWorldTravel = max(max(rayNormalBias, 0.0) * 0.5, 0.001);
    if (pixelTravel < max(giMinHitTravelPixels, 0.0)
        || candidate.travelDistance <= minimumWorldTravel)
    {
        candidate.hit = 0.0;
        rejectReason = 2.0;
        return;
    }

    float sceneNdcDepth = tex2Dlod(prepassDepthTex, float4(candidate.uv, 0.0, 0.0)).r;
    float sceneRealDepth = ndcToRealDepth(sceneNdcDepth, projParams.zw);
    float sceneEyeDepth = realToEyeLinearDepth(sceneRealDepth, projParams);
    if (sceneEyeDepth >= 0.9999)
    {
        candidate.hit = 0.0;
        rejectReason = 3.0;
        return;
    }

    float2 projectedUv;
    float rayEyeDepth;
    if (!beamrtProjectEyeVector(
        rayOrigin + rayDirection * candidate.travelDistance - eyePosWorld,
        currentEyeRay,
        eyeRayDu,
        eyeRayDv,
        currentUv,
        projectedUv,
        rayEyeDepth))
    {
        candidate.hit = 0.0;
        rejectReason = 5.0;
        return;
    }

    depthError = abs(rayEyeDepth - sceneEyeDepth) * projParams.y;
    if (depthError > safeThickness * 1.05)
    {
        candidate.hit = 0.0;
        rejectReason = 5.0;
        return;
    }

    hitNormal = decodeNormalXY(tex2Dlod(prepassTex, float4(candidate.uv, 0.0, 0.0)).xy);
    float hitFacing = dot(hitNormal, -normalize(rayDirection));
    if (hitFacing <= 0.0)
    {
        candidate.hit = 0.0;
        rejectReason = 4.0;
        return;
    }

    float depthConfidence = 1.0 - smoothstep(
        safeThickness * 0.20,
        safeThickness,
        depthError);
    float facingConfidence = smoothstep(0.0, 0.25, hitFacing);
    float edgeConfidence = beamrtScreenEdgeConfidence(candidate.uv);

    float2 texelUv = 1.0 / max(targetSize, 1.0);
    float minNormalAgreement = 1.0;
    float maxRelativeDepthGradient = 0.0;
    const float2 neighborOffsets[4] = {
        float2(1.0, 0.0), float2(-1.0, 0.0),
        float2(0.0, 1.0), float2(0.0, -1.0)
    };
    [unroll]
    for (int neighborIndex = 0; neighborIndex < 4; ++neighborIndex)
    {
        float2 neighborUv = candidate.uv + neighborOffsets[neighborIndex] * texelUv;
        if (any(neighborUv <= viewportMin) || any(neighborUv >= viewportMax))
        {
            continue;
        }
        float neighborNdcDepth = tex2Dlod(prepassDepthTex, float4(neighborUv, 0.0, 0.0)).r;
        float neighborRealDepth = ndcToRealDepth(neighborNdcDepth, projParams.zw);
        float neighborEyeDepth = realToEyeLinearDepth(neighborRealDepth, projParams);
        if (neighborEyeDepth >= 0.9999)
        {
            maxRelativeDepthGradient = 1.0;
            continue;
        }
        float3 neighborNormal = decodeNormalXY(
            tex2Dlod(prepassTex, float4(neighborUv, 0.0, 0.0)).xy);
        minNormalAgreement = min(minNormalAgreement, saturate(dot(hitNormal, neighborNormal)));
        maxRelativeDepthGradient = max(
            maxRelativeDepthGradient,
            abs(neighborEyeDepth - sceneEyeDepth) / max(sceneEyeDepth, 0.0001));
    }

    float normalContinuity = smoothstep(0.15, 0.75, minNormalAgreement);
    float depthContinuity = 1.0 - smoothstep(0.02, 0.15, maxRelativeDepthGradient);
    float continuityConfidence = min(normalContinuity, depthContinuity);
    float rawConfidence = min(
        min(depthConfidence, facingConfidence),
        min(edgeConfidence, continuityConfidence));

    float weakest = depthConfidence;
    rejectReason = 5.0;
    if (facingConfidence < weakest) { weakest = facingConfidence; rejectReason = 4.0; }
    if (edgeConfidence < weakest) { weakest = edgeConfidence; rejectReason = 6.0; }
    if (continuityConfidence < weakest) { rejectReason = 7.0; }
    if (rawConfidence >= 0.999) rejectReason = 0.0;

    hitConfidence = lerp(1.0, rawConfidence, validationStrength);
    // Weak screen hits are more dangerous than misses: an uncertain depth
    // crossing can look like an offset duplicate once temporal history reuses
    // it. Let sufficiently uncertain hits fall through to the surfel/world
    // representation instead of treating them as authoritative. Strength zero
    // returns before this block and preserves v0.063 acceptance exactly.
    float fallbackThreshold = lerp(0.02, 0.15, validationStrength);
    if (hitConfidence <= fallbackThreshold)
    {
        candidate.hit = 0.0;
    }
}

#ifdef BEAMRT_CANDIDATE_CONTINUATION
bool beamrtResolveCandidate(
    inout BeamRTRayHit candidate,
    float3 rayOrigin,
    float3 rayDirection,
    float3 currentEyeRay,
    float3 eyeRayDu,
    float3 eyeRayDv,
    float2 currentUv,
    float safeThickness,
    inout int rejectedCandidateCount,
    out float hitConfidence,
    out float hitDepthError,
    out float hitRejectReason,
    out float3 validatedHitNormal)
{
    beamrtValidateScreenHit(
        candidate, rayOrigin, rayDirection, currentEyeRay, eyeRayDu, eyeRayDv,
        currentUv, safeThickness, hitConfidence, hitDepthError, hitRejectReason,
        validatedHitNormal);

    if (candidate.hit >= 0.5)
    {
        return true; // accepted; caller returns the hit
    }

    if (giCandidateContinuation <= 0.5)
    {
        return true; // exact v0.064 stop-on-first-candidate behavior
    }

    int retryLimit = (int)clamp(floor(giCandidateRetryCount + 0.5), 0.0, 8.0);
    if (rejectedCandidateCount >= retryLimit || hitRejectReason >= 7.5)
    {
        return true; // retry budget exhausted or ray left usable viewport
    }

    rejectedCandidateCount += 1;
    candidate.hit = 0.0;
    return false; // recoverable rejection: continue traversal
}
#endif
#endif

BeamRTRayHit beamrtTraceRay(
    float3 rayOrigin,
    float3 rayDirection,
    float3 currentEyeRay,
    float3 eyeRayDu,
    float3 eyeRayDv,
    float2 currentUv
#ifdef BEAMRT_HIT_VALIDATION
    , out float hitConfidence
    , out float hitDepthError
    , out float hitRejectReason
    , out float3 validatedHitNormal
#endif
    )
{
    BeamRTRayHit result;
    result.hit = 0.0;
    result.stepIndex = -1.0;
    result.travelDistance = 0.0;
    result.uv = 0.0;
#ifdef BEAMRT_HIT_VALIDATION
    hitConfidence = 0.0;
    hitDepthError = max(rayThickness, 0.0001) * 2.0;
    hitRejectReason = 1.0;
    validatedHitNormal = float3(0.0, 0.0, 1.0);
#endif

    float2 viewportOtherCorner = rtParams0.xy + rtParams0.zw;
    float2 viewportMin = min(rtParams0.xy, viewportOtherCorner);
    float2 viewportMax = max(rtParams0.xy, viewportOtherCorner);
    float safeStepSize = max(rayStepSize, 0.0001);
    float safeThickness = max(rayThickness, 0.0001);
    float adaptiveReach = 1.0;
#ifdef BEAMRT_ADAPTIVE_RAY_BUDGET
    adaptiveReach = beamrtAdaptiveRayReach(rayDirection, currentEyeRay);
#endif
    float clampedMaxSteps = clamp(rayMaxSteps * adaptiveReach, 1.0, 512.0);
    float3 duCrossDv = cross(eyeRayDu, eyeRayDv);
    float determinant = dot(currentEyeRay, duCrossDv);
    if (abs(determinant) < 0.00000001)
    {
        return result;
    }

    float3 originEyeVector = rayOrigin - eyePosWorld;
    float inverseDeterminant = 1.0 / determinant;
    float depthIntercept = dot(originEyeVector, duCrossDv) * inverseDeterminant;
    float depthSlope = dot(rayDirection, duCrossDv) * inverseDeterminant;
    float duIntercept = dot(currentEyeRay, cross(originEyeVector, eyeRayDv)) * inverseDeterminant;
    float duSlope = dot(currentEyeRay, cross(rayDirection, eyeRayDv)) * inverseDeterminant;
    float dvIntercept = dot(currentEyeRay, cross(eyeRayDu, originEyeVector)) * inverseDeterminant;
    float dvSlope = dot(currentEyeRay, cross(eyeRayDu, rayDirection)) * inverseDeterminant;
#ifdef BEAMRT_SCREEN_DDA
    bool useScreenDDA = giMarcherMode > 0.5;
    float2 screenDeltaUv = 0.0;
    float screenMajorPixels = 0.0;
    float screenStride = max(giScreenStride, 0.5);
    if (useScreenDDA)
    {
        float maximumTravel = safeStepSize * clampedMaxSteps;
        float endpointDepth = depthIntercept + depthSlope * maximumTravel;
        if (endpointDepth <= 0.000001)
        {
            return result;
        }
        float2 endpointOffset = float2(
            duIntercept + duSlope * maximumTravel,
            dvIntercept + dvSlope * maximumTravel
        );
        float2 endpointUv = currentUv + endpointOffset / endpointDepth;
        screenDeltaUv = endpointUv - currentUv;
        float2 screenDeltaPixels = screenDeltaUv * max(targetSize, 1.0);
        screenMajorPixels = max(abs(screenDeltaPixels.x), abs(screenDeltaPixels.y));
        if (screenMajorPixels < 0.5)
        {
            return result;
        }
        clampedMaxSteps = min(clampedMaxSteps, ceil(screenMajorPixels / screenStride));
    }
#endif
#ifdef BEAMRT_REFINED_HITS
    bool previousValid = false;
    float previousDepthDelta = 0.0;
    float previousTravelDistance = 0.0;
#endif
#ifdef BEAMRT_CANDIDATE_CONTINUATION
    int rejectedCandidateCount = 0;
#endif

    [loop]
    for (int stepIndex = 0; stepIndex < 512; ++stepIndex)
    {
        if ((float)stepIndex >= clampedMaxSteps)
        {
            break;
        }

        float travelDistance;
        float rayEyeDepth;
        float2 rayUv;
#ifdef BEAMRT_SCREEN_DDA
        if (useScreenDDA)
        {
            float screenFraction = min(((float)stepIndex + 1.0) * screenStride
                / max(screenMajorPixels, 0.5), 1.0);
            rayUv = currentUv + screenDeltaUv * screenFraction;
            float2 projectedOffset = rayUv - currentUv;
            if (abs(screenDeltaUv.x * targetSize.x) >= abs(screenDeltaUv.y * targetSize.y))
            {
                float denominator = projectedOffset.x * depthSlope - duSlope;
                if (abs(denominator) < 0.00000001) break;
                travelDistance = (duIntercept - projectedOffset.x * depthIntercept) / denominator;
            }
            else
            {
                float denominator = projectedOffset.y * depthSlope - dvSlope;
                if (abs(denominator) < 0.00000001) break;
                travelDistance = (dvIntercept - projectedOffset.y * depthIntercept) / denominator;
            }
            rayEyeDepth = depthIntercept + depthSlope * travelDistance;
        }
        else
#endif
        {
            travelDistance = ((float)stepIndex + 1.0) * safeStepSize;
            rayEyeDepth = depthIntercept + depthSlope * travelDistance;
            float2 weightedOffset = float2(
                duIntercept + duSlope * travelDistance,
                dvIntercept + dvSlope * travelDistance
            );
            rayUv = currentUv + weightedOffset / max(rayEyeDepth, 0.000001);
        }
        if (travelDistance <= 0.0 || rayEyeDepth <= 0.000001)
        {
            break;
        }
        if (rayEyeDepth >= 0.9999 || any(rayUv <= viewportMin) || any(rayUv >= viewportMax))
        {
#ifdef BEAMRT_HIT_VALIDATION
            hitRejectReason = 8.0;
#endif
            break;
        }

        float sceneNdcDepth = tex2Dlod(prepassDepthTex, float4(rayUv, 0.0, 0.0)).r;
        float sceneRealDepth = ndcToRealDepth(sceneNdcDepth, projParams.zw);
        float sceneEyeDepth = realToEyeLinearDepth(sceneRealDepth, projParams);
        if (sceneEyeDepth >= 0.9999)
        {
#ifdef BEAMRT_REFINED_HITS
            previousValid = false;
#endif
#ifdef BEAMRT_HIT_VALIDATION
            hitRejectReason = 3.0;
#endif
            continue;
        }

        float depthDeltaWorld = (rayEyeDepth - sceneEyeDepth) * projParams.y;
#ifdef BEAMRT_REFINED_HITS
        // A valid front-to-behind sign crossing brackets a surface even when a
        // coarse world-space step skipped completely over the thickness band.
        // Refine only that bracket, preserving the old direct thickness test.
        if (giHitRefinementSteps >= 0.0
            && previousValid && previousDepthDelta < 0.0 && depthDeltaWorld >= 0.0)
        {
            float lowTravel = previousTravelDistance;
            float highTravel = travelDistance;
            float highDepthDelta = depthDeltaWorld;
            float2 refinedUv = rayUv;
            int refinementCount = (int)clamp(floor(giHitRefinementSteps + 0.5), 0.0, 6.0);
            [unroll]
            for (int refinementIndex = 0; refinementIndex < 6; ++refinementIndex)
            {
                if (refinementIndex >= refinementCount)
                {
                    break;
                }
                float midpointTravel = (lowTravel + highTravel) * 0.5;
                float midpointEyeDepth = depthIntercept + depthSlope * midpointTravel;
                float2 midpointWeightedOffset = float2(
                    duIntercept + duSlope * midpointTravel,
                    dvIntercept + dvSlope * midpointTravel
                );
                float2 midpointUv = currentUv + midpointWeightedOffset / max(midpointEyeDepth, 0.000001);
                float midpointNdcDepth = tex2Dlod(prepassDepthTex, float4(midpointUv, 0.0, 0.0)).r;
                float midpointRealDepth = ndcToRealDepth(midpointNdcDepth, projParams.zw);
                float midpointSceneDepth = realToEyeLinearDepth(midpointRealDepth, projParams);
                float midpointDelta = (midpointEyeDepth - midpointSceneDepth) * projParams.y;
                if (midpointSceneDepth < 0.9999 && midpointDelta >= 0.0)
                {
                    highTravel = midpointTravel;
                    highDepthDelta = midpointDelta;
                    refinedUv = midpointUv;
                }
                else
                {
                    lowTravel = midpointTravel;
                }
            }
            // Reject pure silhouette/depth-discontinuity jumps whose refined
            // behind sample never approaches the configured surface band.
            if (highDepthDelta <= safeThickness)
            {
                result.hit = 1.0;
                result.stepIndex = (float)stepIndex;
                result.travelDistance = highTravel;
                result.uv = refinedUv;
#ifdef BEAMRT_CANDIDATE_CONTINUATION
                if (giCandidateContinuation > 0.5)
                {
                    bool resolved = beamrtResolveCandidate(
                        result, rayOrigin, rayDirection, currentEyeRay, eyeRayDu, eyeRayDv,
                        currentUv, safeThickness, rejectedCandidateCount, hitConfidence,
                        hitDepthError, hitRejectReason, validatedHitNormal);
                    if (resolved) return result;
                    previousValid = false;
                    continue;
                }
#endif
                break;
            }
#ifdef BEAMRT_HIT_VALIDATION
            result.stepIndex = (float)stepIndex;
            result.travelDistance = highTravel;
            result.uv = refinedUv;
            hitDepthError = abs(highDepthDelta);
            hitRejectReason = 5.0;
#endif
        }
#endif
        if (depthDeltaWorld >= 0.0 && depthDeltaWorld <= safeThickness)
        {
            result.hit = 1.0;
            result.stepIndex = (float)stepIndex;
            result.travelDistance = travelDistance;
            result.uv = rayUv;
#ifdef BEAMRT_CANDIDATE_CONTINUATION
            if (giCandidateContinuation > 0.5)
            {
                bool resolved = beamrtResolveCandidate(
                    result, rayOrigin, rayDirection, currentEyeRay, eyeRayDu, eyeRayDv,
                    currentUv, safeThickness, rejectedCandidateCount, hitConfidence,
                    hitDepthError, hitRejectReason, validatedHitNormal);
                if (resolved) return result;
                previousValid = false;
                continue;
            }
#endif
            break;
        }
#ifdef BEAMRT_REFINED_HITS
        previousValid = true;
        previousDepthDelta = depthDeltaWorld;
        previousTravelDistance = travelDistance;
#endif
    }

#ifdef BEAMRT_HIT_VALIDATION
#ifdef BEAMRT_CANDIDATE_CONTINUATION
    if (giCandidateContinuation <= 0.5)
#endif
    {
        beamrtValidateScreenHit(
            result,
            rayOrigin,
            rayDirection,
            currentEyeRay,
            eyeRayDu,
            eyeRayDv,
            currentUv,
            safeThickness,
            hitConfidence,
            hitDepthError,
            hitRejectReason,
            validatedHitNormal);
    }
#endif

    return result;
}

float3 beamrtDiffuseDirection(
    float3 normal,
    float3 tangent,
    float3 bitangent,
    float3 cell,
    float3 baseFrameSeed,
    float sequenceRotation,
    float inversePathCount,
    float sampleIndex
#ifdef BEAMRT_TRUE_BLUE_NOISE
    , float2 blueSequence
    , float blueStrength
#endif
    )
{
    float3 frameSeed = baseFrameSeed + sampleIndex * float3(23.17, 41.03, 11.91);
    float jitter1 = beamrtHash13(cell + frameSeed + float3(0.0, 17.0, 31.0));
    float jitter2 = beamrtHash13(cell + frameSeed + float3(47.0, 11.0, 5.0));
    float legacyU1 = frac((sampleIndex + jitter1) * inversePathCount
        + sequenceRotation * 0.61803398875);
    float legacyU2 = frac(jitter2 + sampleIndex * 0.61803398875
        + sequenceRotation);
#ifdef BEAMRT_TRUE_BLUE_NOISE
    // The first channel selects a stratified cosine-radius sample and the
    // second rotates the azimuth. At strength one no white/hash value enters
    // the primary ray sequence. Fractional strength is intentionally kept as
    // an A/B crossfade; strength zero is bit-for-bit the legacy construction.
    float blueU1 = (sampleIndex + blueSequence.x) * inversePathCount;
    float blueU2 = frac(blueSequence.y + sampleIndex * 0.61803398875);
    float sequenceStrength = saturate(blueStrength);
    float u1 = lerp(legacyU1, blueU1, sequenceStrength);
    float u2 = lerp(legacyU2, blueU2, sequenceStrength);
#else
    float u1 = legacyU1;
    float u2 = legacyU2;
#endif
    float radius = sqrt(u1);
    float sinePhi;
    float cosinePhi;
    sincos(u2 * 6.28318530718, sinePhi, cosinePhi);
    float3 localDirection = float3(radius * cosinePhi, radius * sinePhi, sqrt(max(0.0, 1.0 - u1)));
    return normalize(tangent * localDirection.x + bitangent * localDirection.y + normal * localDirection.z);
}

void beamrtTraceLightingSample(
    float3 rayOrigin,
    float3 diffuseDirection,
    float3 receiverNormal,
    float roughSurfaceWeight,
    float3 currentEyeRay,
    float3 eyeRayDu,
    float3 eyeRayDv,
    float2 currentUv,
    bool allowScreenSpace,
    bool allowWorldSurfels,
    out float3 sampleRadiance,
    out float sampleConfidence)
{
    sampleRadiance = 0.0;
    sampleConfidence = 0.0;
    float estimator = saturate(giEstimatorMode);
    float receiverCosine = saturate(dot(receiverNormal, diffuseDirection));
    float receiverWeight = lerp(receiverCosine, 1.0, estimator);
    float locality = saturate(giLocalization);

    if (allowScreenSpace)
    {
#ifdef BEAMRT_HIT_VALIDATION
        float screenHitConfidence = 0.0;
        float screenHitDepthError = 0.0;
        float screenHitRejectReason = 1.0;
        float3 screenHitNormal = float3(0.0, 0.0, 1.0);
        BeamRTRayHit diffuseHit = beamrtTraceRay(
            rayOrigin,
            diffuseDirection,
            currentEyeRay,
            eyeRayDu,
            eyeRayDv,
            currentUv,
            screenHitConfidence,
            screenHitDepthError,
            screenHitRejectReason,
            screenHitNormal
        );
#else
        BeamRTRayHit diffuseHit = beamrtTraceRay(
            rayOrigin,
            diffuseDirection,
            currentEyeRay,
            eyeRayDu,
            eyeRayDv,
            currentUv
        );
#endif
        if (diffuseHit.hit >= 0.5)
        {
            float2 hitBackbufferUv = beamrtPrepassUvToBackbufferUv(diffuseHit.uv);
            float3 reflectedLinear;
            float3 emissiveLinear;
            beamrtSelectedSourceComponents(
                diffuseHit.uv, hitBackbufferUv, reflectedLinear, emissiveLinear);
            reflectedLinear = beamrtClampRadiance(reflectedLinear);
            emissiveLinear = beamrtClampRadiance(emissiveLinear);
#ifdef BEAMRT_HIT_VALIDATION
            float3 hitNormal = screenHitNormal;
#else
            float3 hitNormal = decodeNormalXY(tex2Dlod(prepassTex, float4(diffuseHit.uv, 0.0, 0.0)).xy);
#endif
            float emitterCosine = saturate(dot(hitNormal, -diffuseDirection));
            float emitterWeight = lerp(emitterCosine, smoothstep(0.0, 0.15, emitterCosine), estimator);
            float edgeConfidence = beamrtScreenEdgeConfidence(diffuseHit.uv);
            float screenReach = 1.0;
#ifdef BEAMRT_ADAPTIVE_RAY_BUDGET
            screenReach = beamrtAdaptiveRayReach(diffuseDirection, currentEyeRay);
#endif
            float distanceFade = saturate(1.0 - diffuseHit.travelDistance
                / max(rayStepSize * rayMaxSteps * screenReach, 0.001));
            float legacyDistanceWeight = lerp(0.35, 1.0, distanceFade);
            float localDistanceWeight = pow(distanceFade, lerp(1.0, 5.0, locality));
            float distanceWeight = lerp(legacyDistanceWeight, localDistanceWeight, locality);
            float sharedConfidence = receiverWeight * edgeConfidence
                * distanceWeight * roughSurfaceWeight;
#ifdef BEAMRT_HIT_VALIDATION
            sharedConfidence *= screenHitConfidence;
#endif
            float reflectedConfidence = sharedConfidence * emitterWeight;
            float emissiveConfidence = reflectedConfidence;
#ifdef BEAMRT_EMISSIVE_SEPARATION
            // A path that lands on Material_Emissive receives Le directly.
            // Keep hit-facing validation, but do not multiply emitted radiance
            // by the reflector cosine a second time. Strength zero is v0.064.
            emissiveConfidence = lerp(
                reflectedConfidence, sharedConfidence, saturate(giEmissiveSeparation));
#endif
            sampleRadiance = reflectedLinear * reflectedConfidence
                + emissiveLinear * emissiveConfidence;
            float emissivePresence = step(0.00001, dot(emissiveLinear, float3(0.2126, 0.7152, 0.0722)));
            sampleConfidence = max(
                reflectedConfidence,
                lerp(reflectedConfidence, emissiveConfidence, emissivePresence));
            return;
        }
    }

    if (allowWorldSurfels && worldGIStrength > 0.0)
    {
        float surfelDistance = 0.0;
        int surfelIndex = -1;
        float3 surfelNormal = float3(0.0, 0.0, 1.0);
        float surfelRadialRatio = 1.0;
        float worldReach = 1.0;
#ifdef BEAMRT_ADAPTIVE_RAY_BUDGET
        worldReach = beamrtAdaptiveRayReach(diffuseDirection, currentEyeRay);
#endif
        float worldReachDistance = max(surfelMaxDistance * worldReach, 0.001);
        if (beamrtTraceSurfels(rayOrigin, diffuseDirection, surfelDistance, surfelIndex, surfelNormal, surfelRadialRatio)
            && surfelDistance <= worldReachDistance)
        {
            float3 surfelPosition;
            float surfelRadius;
            float sourceId;
            beamrtGetSurfel(surfelIndex, surfelPosition, surfelRadius, surfelNormal, sourceId);
            float2 cacheUv = float2(((float)surfelIndex + 0.5) / 32.0, 0.5);
            float4 cachedRadiance = tex2Dlod(surfelRadianceTex, float4(cacheUv, 0.0, 0.0));
            float3 bounceLinear = cachedRadiance.rgb;
            float visibilityConfidence = (surfelCacheReset < 0.5 && cachedRadiance.a > 0.5) ? 1.0 : 0.0;

            if (visibilityConfidence <= 0.0)
            {
                beamrtSampleVisibleSurfelRadiance(
                    surfelPosition,
                    surfelNormal,
                    currentEyeRay,
                    eyeRayDu,
                    eyeRayDv,
                    currentUv,
                    bounceLinear,
                    visibilityConfidence
                );
            }

            if (visibilityConfidence > 0.0001)
            {
                bounceLinear = beamrtClampRadiance(bounceLinear);
                float emitterCosine = saturate(dot(surfelNormal, -diffuseDirection));
                float emitterWeight = lerp(emitterCosine, smoothstep(0.0, 0.15, emitterCosine), estimator);
                float distanceFade = saturate(1.0 - surfelDistance / worldReachDistance);
                float distanceWeight = lerp(
                    distanceFade,
                    pow(distanceFade, lerp(1.0, 5.0, locality)),
                    locality
                );
                float radialConfidence = pow(saturate(1.0 - surfelRadialRatio * surfelRadialRatio), 2.0);
                float radiusConfidence = saturate(2.0 / max(surfelRadius, 0.1));
                float leakGuard = lerp(1.0, radialConfidence * radiusConfidence, saturate(worldLeakSuppression));
                sampleConfidence = receiverWeight * emitterWeight * distanceWeight
                    * visibilityConfidence * roughSurfaceWeight * max(worldGIStrength, 0.0) * leakGuard;
                sampleRadiance = bounceLinear * sampleConfidence;
                return;
            }
        }
    }
}

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float4 packedPrepass = tex2D(prepassTex, IN.uv0);
    float4 decoded = decodeGBuffer(
        TEX_SAMPLER(prepassDepthTex),
        TEX_SAMPLER(prepassTex),
        IN.uv0,
        projParams
    );

    if (decoded.w >= 0.9999)
    {
        return 0.0;
    }

    float uvDx = ddx(IN.uv0.x);
    float uvDy = ddy(IN.uv0.y);
    if (abs(uvDx) < 0.00000001 || abs(uvDy) < 0.00000001)
    {
        return 0.0;
    }

    float3 worldPosition = eyePosWorld + IN.wsEyeRay * decoded.w;
    float3 eyeRayDu = ddx(IN.wsEyeRay) / uvDx;
    float3 eyeRayDv = ddy(IN.wsEyeRay) / uvDy;
    float3 rayOrigin = worldPosition + decoded.xyz * max(rayNormalBias, 0.0);
    float roughSurfaceWeight = lerp(0.35, 1.0, saturate(packedPrepass.b));
    bool allowScreenSpace = giSourceMode < 1.5;
    bool allowWorldSurfels = giSourceMode < 0.5 || giSourceMode > 1.5;
    float3 lightingSum = 0.0;
    float confidenceSum = 0.0;
    float hitCount = 0.0;
    int pathCount = (int)clamp(floor(giPathCount + 0.5), 1.0, 32.0);
    float inversePathCount = 1.0 / max((float)pathCount, 1.0);

    float safeCellSize = max(giCellSize, 0.005);
    float3 cell = floor(worldPosition / safeCellSize);
    float sequence = fmod(max(giFrameIndex, 0.0), 4096.0);
#ifdef BEAMRT_REFINED_HITS
    // Freeze the inspected direction so marcher A/B images are comparable.
    if (giTraceDebugMode > 0.5) sequence = 0.0;
#endif
    float3 baseFrameSeed = float3(sequence * 19.19, sequence * 7.73, sequence * 13.37);
    float sequenceRotation = frac(sequence * 0.754877666
        + beamrtHash13(cell + float3(3.1, 17.7, 41.9)));
#ifdef BEAMRT_BLUE_NOISE
    // BeamNG's own GTAO blue-noise asset is a 128x128 tile. Sampling it from
    // SV_Position keeps the sequence stable in pixel space, while the golden-
    // ratio frame shift supplies an independent temporal phase. Strength zero
    // is the exact pre-v0.063 sequence.
    float2 blueUv = (fmod(floor(IN.hpos.xy), 128.0) + 0.5) / 128.0;
    float2 blueNoise = tex2Dlod(blueNoiseTex, float4(blueUv, 0.0, 0.0)).rg;
#ifdef BEAMRT_TRUE_BLUE_NOISE
    // Match BeamNG GTAO's integer Weyl sequence. The uint multiply wraps in
    // 32-bit fixed point, avoiding float phase-locking with short frame/LUT
    // periods. X is the radial offset; Y is the azimuthal rotation.
    uint blueFrame = (uint)max(floor(giFrameIndex + 0.5), 0.0);
    float blueTemporalOffset = float(blueFrame * 2447445413u)
        * (1.0 / 4294967296.0);
    float blueTemporalRotation = float(blueFrame * 3242174893u)
        * (1.0 / 4294967296.0);
    float2 blueSequence = frac(blueNoise
        + float2(blueTemporalOffset, blueTemporalRotation));
    float blueStrength = saturate(giBlueNoiseStrength);
#else
    float blueTemporal = frac(sequence * 0.61803398875);
    float blueStrength = saturate(giBlueNoiseStrength);
    sequenceRotation = frac(sequenceRotation
        + (blueNoise.x + blueTemporal) * blueStrength);
    baseFrameSeed += float3(blueNoise.y, blueNoise.x, frac(blueNoise.x + blueNoise.y))
        * (97.0 * blueStrength);
#endif
#endif
    float3 helperAxis = abs(decoded.z) < 0.999 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
    float3 tangent = normalize(cross(helperAxis, decoded.xyz));
    float3 bitangent = cross(decoded.xyz, tangent);

#ifdef BEAMRT_REFINED_HITS
    if (giTraceDebugMode > 0.5)
    {
        float3 diagnosticDirection = beamrtDiffuseDirection(
            decoded.xyz, tangent, bitangent, cell, baseFrameSeed,
            sequenceRotation, inversePathCount, 0.0
#ifdef BEAMRT_TRUE_BLUE_NOISE
            , blueSequence, blueStrength
#endif
            );
#ifdef BEAMRT_HIT_VALIDATION
        float diagnosticConfidence = 0.0;
        float diagnosticDepthError = max(rayThickness, 0.0001) * 2.0;
        float diagnosticRejectReason = 1.0;
        float3 diagnosticHitNormal = float3(0.0, 0.0, 1.0);
        BeamRTRayHit diagnosticHit = beamrtTraceRay(
            rayOrigin, diagnosticDirection, IN.wsEyeRay,
            eyeRayDu, eyeRayDv, IN.uv0,
            diagnosticConfidence, diagnosticDepthError, diagnosticRejectReason,
            diagnosticHitNormal);

        // New v0.064 echo-isolation views remain meaningful even when the
        // candidate is rejected, so evaluate them before the generic miss.
        if (giTraceDebugMode >= 4.5 && giTraceDebugMode < 5.5)
        {
            return float4(diagnosticConfidence.xxx, 1.0);
        }
        if (giTraceDebugMode >= 5.5 && giTraceDebugMode < 6.5)
        {
            float errorHeat = saturate(diagnosticDepthError
                / max(rayThickness * 1.5, 0.0001));
            return float4(errorHeat, 1.0 - errorHeat, 0.05, 1.0);
        }
        if (giTraceDebugMode >= 6.5)
        {
            float reason = floor(diagnosticRejectReason + 0.5);
            if (reason < 0.5) return float4(0.05, 1.0, 0.12, 1.0); // accepted
            if (reason < 1.5) return float4(0.08, 0.08, 0.08, 1.0); // no crossing
            if (reason < 2.5) return float4(1.0, 0.05, 0.05, 1.0);  // self/near origin
            if (reason < 3.5) return float4(0.05, 0.25, 1.0, 1.0);  // background/hole
            if (reason < 4.5) return float4(1.0, 0.05, 0.85, 1.0);  // backface
            if (reason < 5.5) return float4(1.0, 0.45, 0.05, 1.0);  // depth error
            if (reason < 6.5) return float4(1.0, 0.95, 0.05, 1.0);  // screen edge
            if (reason < 7.5) return float4(0.05, 1.0, 1.0, 1.0);   // discontinuity
            return float4(0.55, 0.15, 1.0, 1.0);                    // outside viewport
        }
#else
        BeamRTRayHit diagnosticHit = beamrtTraceRay(
            rayOrigin, diagnosticDirection, IN.wsEyeRay,
            eyeRayDu, eyeRayDv, IN.uv0);
#endif
        if (diagnosticHit.hit < 0.5)
        {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
        if (giTraceDebugMode < 1.5)
        {
            return float4(0.05, 1.0, 0.12, 1.0);
        }
        if (giTraceDebugMode < 2.5)
        {
            float stepHeat = saturate((diagnosticHit.stepIndex + 1.0) / max(rayMaxSteps, 1.0));
            return float4(stepHeat, 1.0 - abs(stepHeat * 2.0 - 1.0), 1.0 - stepHeat, 1.0);
        }
        if (giTraceDebugMode < 3.5)
        {
            float travelHeat = saturate(diagnosticHit.travelDistance
                / max(rayStepSize * rayMaxSteps, 0.001));
            return float4(travelHeat.xxx, 1.0);
        }
#ifdef BEAMRT_HIT_VALIDATION
        return float4(abs(diagnosticHitNormal), 1.0);
#else
        float3 hitNormal = decodeNormalXY(
            tex2Dlod(prepassTex, float4(diagnosticHit.uv, 0.0, 0.0)).xy);
        return float4(abs(hitNormal), 1.0);
#endif
    }
#endif

    [loop]
    for (int sampleIndex = 0; sampleIndex < 32; ++sampleIndex)
    {
        if (sampleIndex >= pathCount)
        {
            break;
        }
        float3 diffuseDirection = beamrtDiffuseDirection(
            decoded.xyz,
            tangent,
            bitangent,
            cell,
            baseFrameSeed,
            sequenceRotation,
            inversePathCount,
            (float)sampleIndex
#ifdef BEAMRT_TRUE_BLUE_NOISE
            , blueSequence, blueStrength
#endif
            );
        float3 sampleRadiance;
        float sampleConfidence;
        beamrtTraceLightingSample(
            rayOrigin,
            diffuseDirection,
            decoded.xyz,
            roughSurfaceWeight,
            IN.wsEyeRay,
            eyeRayDu,
            eyeRayDv,
            IN.uv0,
            allowScreenSpace,
            allowWorldSurfels,
            sampleRadiance,
            sampleConfidence);
        if (sampleConfidence > 0.0001)
        {
            lightingSum += sampleRadiance;
            confidenceSum += sampleConfidence;
            hitCount += 1.0;
        }
    }

    float3 indirectLighting = lightingSum * inversePathCount;
    float coverage = hitCount * inversePathCount;
    float confidence = saturate(confidenceSum * inversePathCount);
    return float4(indirectLighting, max(coverage, confidence));
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
