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

#ifdef BEAMRT_SCENE_VISIBILITY_GI
#include "beamrtGISceneVisibility_v001.h.hlsl"
#endif

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

#ifndef BEAMRT_SIX_INPUT_BINDINGS
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
#endif

    if (giSecondBounceStrength > 0.0001 && giHistoryValid > 0.5)
    {
        float2 previousUv = prepassUv;
#ifdef BEAMRT_SECOND_BOUNCE_REPROJECTION
#ifdef BEAMRT_SIX_INPUT_BINDINGS
        previousUv += beamrtAuxVelocity(prepassUv);
#else
        previousUv += tex2Dlod(velocityTex, float4(prepassUv, 0.0, 0.0)).xy;
#endif
#endif
        bool previousUvValid = all(previousUv >= 0.0) && all(previousUv <= 1.0);
        float4 previousGI = previousUvValid
#ifdef BEAMRT_SIX_INPUT_BINDINGS
            ? beamrtAuxPreviousGI(previousUv)
#else
            ? tex2Dlod(previousGITex, float4(previousUv, 0.0, 0.0))
#endif
            : 0.0;
        float sceneNdcDepth = tex2Dlod(prepassDepthTex, float4(prepassUv, 0.0, 0.0)).r;
        float sceneRealDepth = ndcToRealDepth(sceneNdcDepth, projParams.zw);
        float sceneEyeDepth = realToEyeLinearDepth(sceneRealDepth, projParams);
#ifdef BEAMRT_SECOND_BOUNCE_DEPTH_MOMENTS
#ifdef BEAMRT_SIX_INPUT_BINDINGS
        // Packed alpha is moments depth, gated by the valid history length.
        // GI RGB already includes its support and must not be multiplied twice.
        float relativeDepthDelta = abs(previousGI.a - sceneEyeDepth) / max(sceneEyeDepth, 0.0001);
        float historyAgreement = previousGI.a > 0.0
            ? 1.0 - smoothstep(0.01, 0.04, relativeDepthDelta)
            : 0.0;
#else
        float4 previousMoments = previousUvValid
            ? tex2Dlod(historyMomentsTex, float4(previousUv, 0.0, 0.0))
            : 0.0;
        float relativeDepthDelta = abs(previousMoments.a - sceneEyeDepth) / max(sceneEyeDepth, 0.0001);
        float historyAgreement = (previousMoments.b > 0.5)
            ? 1.0 - smoothstep(0.01, 0.04, relativeDepthDelta)
            : 0.0;
#endif
#ifdef BEAMRT_SECOND_BOUNCE_REPROJECTION
        float velocityPixels = length((previousUv - prepassUv) * targetSize);
        historyAgreement *= 1.0 - smoothstep(32.0, 96.0, velocityPixels);
#endif
#if !defined(BEAMRT_PREMULTIPLIED_SECOND_BOUNCE) && !defined(BEAMRT_SIX_INPUT_BINDINGS)
        historyAgreement *= saturate(previousGI.a);
#endif
#else
        float relativeDepthDelta = abs(previousGI.a - sceneEyeDepth) / max(sceneEyeDepth, 0.0001);
        float historyAgreement = 1.0 - smoothstep(0.01, 0.04, relativeDepthDelta);
#endif
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

#ifdef BEAMRT_GEOMETRIC_SURFACE_GUARD
float3 beamrtGeometricSurfaceNormal(
    float2 surfaceUv,
    float surfaceEyeDepth,
    float3 surfaceWorldPosition,
    float3 currentEyeRay,
    float3 eyeRayDu,
    float3 eyeRayDv,
    float2 currentUv,
    float3 shadingNormal)
{
    // GI can run below native resolution. A targetSize texel then spans more
    // than one depth pixel and crosses curbs/silhouettes unnecessarily.
    uint depthWidth;
    uint depthHeight;
    prepassDepthTexTex.GetDimensions(depthWidth, depthHeight);
    float2 depthTexel = 1.0 / max(float2(depthWidth, depthHeight), 1.0);
    float2 viewportOtherCorner = rtParams0.xy + rtParams0.zw;
    float2 viewportMin = min(rtParams0.xy, viewportOtherCorner);
    float2 viewportMax = max(rtParams0.xy, viewportOtherCorner);
    const float2 neighborOffsets[4] = {
        float2(1.0, 0.0), float2(-1.0, 0.0),
        float2(0.0, 1.0), float2(0.0, -1.0)
    };
    // Form local differences before adding the large world-space camera
    // translation, preserving the native pixel's small tangent vectors.
    float3 surfaceEyeRay = currentEyeRay
        + eyeRayDu * (surfaceUv.x - currentUv.x)
        + eyeRayDv * (surfaceUv.y - currentUv.y);
    float3 surfaceEyeVector = surfaceEyeRay * surfaceEyeDepth;
    float3 tangentU = 0.0;
    float3 tangentV = 0.0;
    float bestDepthDeltaU = 1.0;
    float bestDepthDeltaV = 1.0;
    bool validU = false;
    bool validV = false;
    [unroll]
    for (int neighborIndex = 0; neighborIndex < 4; ++neighborIndex)
    {
        float2 neighborUv = surfaceUv + neighborOffsets[neighborIndex] * depthTexel;
        if (any(neighborUv < viewportMin) || any(neighborUv > viewportMax))
        {
            continue;
        }
        float neighborNdcDepth = tex2Dlod(prepassDepthTex, float4(neighborUv, 0.0, 0.0)).r;
        float neighborRealDepth = ndcToRealDepth(neighborNdcDepth, projParams.zw);
        float neighborEyeDepth = realToEyeLinearDepth(neighborRealDepth, projParams);
        float depthDelta = abs(neighborEyeDepth - surfaceEyeDepth);
        // Pick the side closer in depth. If both sides jump by over ten percent
        // in one native pixel, the visible plane is underdetermined here.
        if (neighborEyeDepth <= 0.0 || neighborEyeDepth >= 0.9999
            || depthDelta > max(surfaceEyeDepth * 0.10, 0.00001))
        {
            continue;
        }
        float3 neighborEyeRay = currentEyeRay
            + eyeRayDu * (neighborUv.x - currentUv.x)
            + eyeRayDv * (neighborUv.y - currentUv.y);
        float3 neighborDelta = neighborEyeRay * neighborEyeDepth - surfaceEyeVector;
        if (neighborIndex < 2 && depthDelta < bestDepthDeltaU)
        {
            tangentU = neighborDelta * neighborOffsets[neighborIndex].x;
            bestDepthDeltaU = depthDelta;
            validU = true;
        }
        else if (neighborIndex >= 2 && depthDelta < bestDepthDeltaV)
        {
            tangentV = neighborDelta * neighborOffsets[neighborIndex].y;
            bestDepthDeltaV = depthDelta;
            validV = true;
        }
    }
    float3 geometricNormal = cross(tangentU, tangentV);
    float normalLengthSquared = dot(geometricNormal, geometricNormal);
    float tangentLengthProduct = dot(tangentU, tangentU) * dot(tangentV, tangentV);
    if (!validU || !validV || normalLengthSquared <= max(tangentLengthProduct * 0.00000001, 0.0000000000000001))
    {
        return shadingNormal;
    }
    geometricNormal *= rsqrt(normalLengthSquared);
    // Depth reconstructs the visible face; orient it toward the camera without
    // borrowing the possibly perturbed material normal's orientation.
    if (dot(geometricNormal, surfaceWorldPosition - eyePosWorld) > 0.0)
    {
        geometricNormal = -geometricNormal;
    }
    return geometricNormal;
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
#ifndef BEAMRT_GEOMETRIC_SURFACE_GUARD
    if (validationStrength <= 0.0001)
    {
        hitConfidence = 1.0;
        rejectReason = 0.0;
        hitNormal = decodeNormalXY(tex2Dlod(prepassTex, float4(candidate.uv, 0.0, 0.0)).xy);
        return;
    }
#endif

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

#ifdef BEAMRT_GEOMETRIC_SURFACE_GUARD
    hitNormal = decodeNormalXY(tex2Dlod(prepassTex, float4(candidate.uv, 0.0, 0.0)).xy);
    float receiverNdcDepth = tex2Dlod(prepassDepthTex, float4(currentUv, 0.0, 0.0)).r;
    float receiverRealDepth = ndcToRealDepth(receiverNdcDepth, projParams.zw);
    float receiverEyeDepth = realToEyeLinearDepth(receiverRealDepth, projParams);
    float3 receiverShadingNormal = decodeNormalXY(tex2Dlod(prepassTex, float4(currentUv, 0.0, 0.0)).xy);
    float3 receiverWorldPosition = eyePosWorld + currentEyeRay * receiverEyeDepth;
    float3 receiverGeometricNormal = beamrtGeometricSurfaceNormal(
        currentUv, receiverEyeDepth, receiverWorldPosition,
        currentEyeRay, eyeRayDu, eyeRayDv, currentUv, receiverShadingNormal);
    float3 hitEyeRay = currentEyeRay
        + eyeRayDu * (candidate.uv.x - currentUv.x)
        + eyeRayDv * (candidate.uv.y - currentUv.y);
    float3 hitWorldPosition = eyePosWorld + hitEyeRay * sceneEyeDepth;
    float3 hitGeometricNormal = beamrtGeometricSurfaceNormal(
        candidate.uv, sceneEyeDepth, hitWorldPosition,
        currentEyeRay, eyeRayDu, eyeRayDv, currentUv, hitNormal);
    float receiverPlaneSeparation = dot(
        hitEyeRay * sceneEyeDepth - currentEyeRay * receiverEyeDepth,
        receiverGeometricNormal);
    if (receiverPlaneSeparation <= max(0.001, max(rayNormalBias, 0.0) * 0.25))
    {
        candidate.hit = 0.0;
        rejectReason = 2.0;
        return;
    }
    if (dot(hitGeometricNormal, -normalize(rayDirection)) <= 0.0)
    {
        candidate.hit = 0.0;
        rejectReason = 4.0;
        return;
    }
    if (validationStrength <= 0.0001)
    {
        hitConfidence = 1.0;
        rejectReason = 0.0;
        return;
    }
#endif

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

#ifdef BEAMRT_GEOMETRIC_SURFACE_GUARD
    uint depthWidth;
    uint depthHeight;
    prepassDepthTexTex.GetDimensions(depthWidth, depthHeight);
    float2 texelUv = 1.0 / max(float2(depthWidth, depthHeight), 1.0);
#else
    float2 texelUv = 1.0 / max(targetSize, 1.0);
#endif
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
#ifdef BEAMRT_GEOMETRIC_SURFACE_GUARD
    if (hitRejectReason >= 3.5 && hitRejectReason < 4.5)
    {
        // A crossed opaque face with no emitting front lobe blocks the path.
        // Do not continue beyond it and collect unrelated background light.
        return true;
    }
#endif

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

#if defined(BEAMRT_ACTUAL_DDA_PROGRESS) && defined(BEAMRT_SCREEN_DDA)
float beamrtActualDdaReachConfidence(
    float2 hitUv, float2 screenStartUv, float fullScreenBudgetPixels, bool useScreenDDA)
{
    if (!useScreenDDA) return 1.0;
    float2 hitTravelPixels = abs((hitUv - screenStartUv) * max(targetSize, 1.0));
    float progress = saturate(max(hitTravelPixels.x, hitTravelPixels.y)
        / max(fullScreenBudgetPixels, 0.5));
    return 1.0 - smoothstep(0.55, 1.0, progress);
}
#endif

#if defined(BEAMRT_WIDE_SCREEN_DDA) && defined(BEAMRT_SCREEN_DDA)
float beamrtWideDdaPixelDistance(float sampleNumber, float workSteps, float stride)
{
    // The near half stays at one stride; the far half grows by 0.35 strides
    // per sample. This covers 153 pixels in 48 samples at a one-pixel stride.
    float nearSteps = ceil(workSteps * 0.5);
    float farSteps = max(sampleNumber - nearSteps, 0.0);
    return stride * (min(sampleNumber, nearSteps) + farSteps
        + 0.35 * farSteps * (farSteps + 1.0) * 0.5);
}
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
#ifdef BEAMRT_ACTUAL_DDA_PROGRESS
    result.reachConfidence = 1.0;
#endif
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
#ifdef BEAMRT_DDA_VIEW_INVARIANT_REACH
    // A screen-pixel work budget must not collapse merely because the same
    // world-space ray points toward the camera. Keep the preset's overall
    // reach control, but reserve rear-ray shortening for the linear marcher.
    if (giMarcherMode > 0.5)
    {
        adaptiveReach = clamp(giRayReach, 0.05, 1.0);
    }
#endif
#endif
    float clampedMaxSteps = clamp(rayMaxSteps * adaptiveReach, 1.0, 512.0);
#ifdef BEAMRT_WIDE_SCREEN_DDA
    // Preserve the configured world endpoint independently of depth-sample
    // work. Narrow DDA retains its previous coupled world/screen limit.
    float maxWorldTravel = safeStepSize * clampedMaxSteps;
#endif
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
#ifdef BEAMRT_WIDE_SCREEN_DDA
    bool useWideScreenDDA = giMarcherMode > 1.5;
    float wideScreenProgress = 0.0;
#ifdef BEAMRT_BOUNDED_SCREEN_DDA
    if (useWideScreenDDA)
    {
        // Apply this before projection: degenerate/outside-view DDA fallbacks
        // must obey the same depth-sample count while retaining world reach.
        clampedMaxSteps = max(floor(min(
            clampedMaxSteps, max(giScreenBudgetSteps, 1.0))), 1.0);
    }
#endif
#endif
    float2 screenStartUv = currentUv;
    float2 screenDeltaUv = 0.0;
    float screenMajorPixels = 0.0;
    float screenStride = max(giScreenStride, 0.5);
#ifdef BEAMRT_ACTUAL_DDA_PROGRESS
    float fullScreenBudgetPixels = 0.0;
#endif
    if (useScreenDDA)
    {
#ifdef BEAMRT_SCREEN_DDA_REPAIR
        // Project the actual normal-biased ray origin. The old DDA began at
        // currentUv while its inverse projection solved the biased ray, so its
        // 2D march and 3D distance equation described different lines.
        if (depthIntercept <= 0.000001)
        {
            useScreenDDA = false;
        }
        else
        {
            screenStartUv = currentUv
                + float2(duIntercept, dvIntercept) / depthIntercept;
        }

        if (useScreenDDA
            && (any(screenStartUv <= viewportMin) || any(screenStartUv >= viewportMax)))
        {
            // A large bias at a silhouette can project outside the view. The
            // world-step path is safer than manufacturing a clipped start.
            useScreenDDA = false;
        }

        if (useScreenDDA)
        {
#ifdef BEAMRT_BOUNDED_SCREEN_DDA
            // Bound both world reach and screen work. Capping only the number
            // of screen samples still allowed a nearly camera-aligned ray to
            // span the full configured 30+ metres in very few pixels.
            clampedMaxSteps = min(
                clampedMaxSteps, max(giScreenBudgetSteps, 1.0));
#endif
#ifdef BEAMRT_ACTUAL_DDA_PROGRESS
            // Save the artificial work limit before a naturally shorter
            // projected segment reduces the number of available samples.
            fullScreenBudgetPixels = clampedMaxSteps * screenStride;
#ifdef BEAMRT_WIDE_SCREEN_DDA
            if (useWideScreenDDA)
            {
                fullScreenBudgetPixels = beamrtWideDdaPixelDistance(
                    clampedMaxSteps, clampedMaxSteps, screenStride);
            }
#endif
#endif
            float maximumTravel = safeStepSize * clampedMaxSteps;
#ifdef BEAMRT_WIDE_SCREEN_DDA
            if (useWideScreenDDA) maximumTravel = maxWorldTravel;
#endif
            float endpointDepth = depthIntercept + depthSlope * maximumTravel;

            // Preserve the useful segment of a ray aimed toward/behind the
            // camera. Previously one endpoint behind the eye discarded the
            // complete ray, including all of its visible near-field travel.
#ifdef BEAMRT_NATIVE_NEAR_CLIP
            // Eye-linear depth is camera-space metres divided by the far
            // plane, so the native near plane is x/y (not a fixed 0.0001).
            // The floor only protects division/projective math at zero.
            float minimumProjectedDepth = max(
                projParams.x / max(projParams.y, 0.0001), 0.00000001);
#else
            const float minimumProjectedDepth = 0.0001;
#endif
            if (endpointDepth <= minimumProjectedDepth)
            {
                if (depthSlope < -0.00000001)
                {
                    float cameraPlaneTravel = (depthIntercept - minimumProjectedDepth)
                        / -depthSlope;
                    maximumTravel = min(maximumTravel, cameraPlaneTravel);
                    endpointDepth = depthIntercept + depthSlope * maximumTravel;
                }
                else
                {
                    useScreenDDA = false;
                }
            }

            if (useScreenDDA && maximumTravel > 0.0
                && endpointDepth > minimumProjectedDepth * 0.5)
            {
                float2 endpointOffset = float2(
                    duIntercept + duSlope * maximumTravel,
                    dvIntercept + dvSlope * maximumTravel
                );
                float2 endpointUv = currentUv + endpointOffset / endpointDepth;
                float2 unclippedDeltaUv = endpointUv - screenStartUv;

                // Clip the projective line to the viewport before choosing a
                // stride. An endpoint close to the eye plane can otherwise be
                // thousands of pixels away and force the 512 iterations to
                // skip nearly the whole useful on-screen segment.
                float exitFraction = 1.0;
                if (unclippedDeltaUv.x > 0.00000001)
                {
                    exitFraction = min(exitFraction,
                        (viewportMax.x - screenStartUv.x) / unclippedDeltaUv.x);
                }
                else if (unclippedDeltaUv.x < -0.00000001)
                {
                    exitFraction = min(exitFraction,
                        (viewportMin.x - screenStartUv.x) / unclippedDeltaUv.x);
                }
                if (unclippedDeltaUv.y > 0.00000001)
                {
                    exitFraction = min(exitFraction,
                        (viewportMax.y - screenStartUv.y) / unclippedDeltaUv.y);
                }
                else if (unclippedDeltaUv.y < -0.00000001)
                {
                    exitFraction = min(exitFraction,
                        (viewportMin.y - screenStartUv.y) / unclippedDeltaUv.y);
                }
                exitFraction = saturate(exitFraction);
                screenDeltaUv = unclippedDeltaUv * exitFraction;

                float2 screenDeltaPixels = screenDeltaUv * max(targetSize, 1.0);
                screenMajorPixels = max(abs(screenDeltaPixels.x), abs(screenDeltaPixels.y));
                if (screenMajorPixels < 0.5)
                {
                    // DDA has no meaningful pixel traversal here. Preserve the
                    // ray by falling back to the linear world-space marcher.
                    useScreenDDA = false;
                }
                else
                {
#ifdef BEAMRT_BOUNDED_SCREEN_DDA
#ifdef BEAMRT_WIDE_SCREEN_DDA
                    if (useWideScreenDDA)
                    {
                        // Keep the sample schedule tied to its original work
                        // budget. A naturally short segment ends at its first
                        // clamped endpoint rather than resampling that pixel.
                        float widePixelBudget = beamrtWideDdaPixelDistance(
                            clampedMaxSteps, clampedMaxSteps, screenStride);
                        float coveredScreenPixels = min(screenMajorPixels, widePixelBudget);
                        screenDeltaUv *= coveredScreenPixels / max(screenMajorPixels, 0.5);
                        screenMajorPixels = coveredScreenPixels;
                    }
                    else
#endif
                    {
                        // This is deliberately a local, bounded screen trace. A
                        // plain depth buffer has no hierarchy, so walking a full
                        // diffuse ray at one-pixel stride can cost hundreds of
                        // samples per path. Conversely, distributing a small
                        // budget across that whole line skips most surfaces and
                        // turns distant image details into reflection-like hits.
                        // Cover the first N actual screen pixels instead. A miss
                        // remains eligible for the world/surfel fallback.
                        float availableScreenSteps = ceil(screenMajorPixels / screenStride);
                        clampedMaxSteps = clamp(min(
                            min(clampedMaxSteps, availableScreenSteps),
                            max(giScreenBudgetSteps, 1.0)), 1.0, 512.0);
                        float coveredScreenPixels = min(
                            screenMajorPixels, clampedMaxSteps * screenStride);
                        screenDeltaUv *= coveredScreenPixels / max(screenMajorPixels, 0.5);
                        screenMajorPixels = coveredScreenPixels;
                    }
#else
                    // Always cover the complete clipped segment, but never
                    // exceed the ray's configured world-step budget. The first
                    // v0.067 draft expanded a 36/160-step ray toward 512 pixel
                    // samples, causing a severe full-screen cost regression.
                    // The fraction below distributes this bounded sample count
                    // across the complete segment instead of truncating it.
                    clampedMaxSteps = clamp(min(
                        clampedMaxSteps,
                        ceil(screenMajorPixels / screenStride)), 1.0, 512.0);
#endif
                }
            }
            else
            {
                useScreenDDA = false;
            }
        }
#else
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
#endif
    }
#endif
#if defined(BEAMRT_REFINED_HITS) || defined(BEAMRT_REQUIRE_FRONT_CROSSING)
    bool previousValid = false;
    float previousDepthDelta = 0.0;
    float previousTravelDistance = 0.0;
#endif
#ifdef BEAMRT_REQUIRE_FRONT_CROSSING
    // Seed the bracket from the actual biased origin. Starting inside a depth
    // thickness band does not itself establish an intersection with a face.
    if (depthIntercept > 0.000001 && depthIntercept < 0.9999)
    {
        float2 originUv = currentUv
            + float2(duIntercept, dvIntercept) / depthIntercept;
        if (all(originUv > viewportMin) && all(originUv < viewportMax))
        {
            float originNdcDepth = tex2Dlod(prepassDepthTex, float4(originUv, 0.0, 0.0)).r;
            float originRealDepth = ndcToRealDepth(originNdcDepth, projParams.zw);
            float originSceneEyeDepth = realToEyeLinearDepth(originRealDepth, projParams);
            if (originSceneEyeDepth < 0.9999)
            {
                previousValid = true;
                previousDepthDelta = (depthIntercept - originSceneEyeDepth) * projParams.y;
            }
        }
    }
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
#if defined(BEAMRT_WIDE_SCREEN_DDA) && defined(BEAMRT_SCREEN_DDA)
        if (useWideScreenDDA && useScreenDDA && wideScreenProgress >= 1.0)
        {
            break;
        }
#endif

        float travelDistance;
        float rayEyeDepth;
        float2 rayUv;
#ifdef BEAMRT_SCREEN_DDA
        if (useScreenDDA)
        {
#ifdef BEAMRT_SCREEN_DDA_REPAIR
#ifdef BEAMRT_BOUNDED_SCREEN_DDA
            float screenFraction = min(
                ((float)stepIndex + 1.0) * screenStride
                / max(screenMajorPixels, 0.5), 1.0);
#ifdef BEAMRT_WIDE_SCREEN_DDA
            if (useWideScreenDDA)
            {
                screenFraction = min(beamrtWideDdaPixelDistance(
                    (float)stepIndex + 1.0, clampedMaxSteps, screenStride)
                    / max(screenMajorPixels, 0.5), 1.0);
                wideScreenProgress = screenFraction;
            }
#endif
#else
            float screenFraction = min(
                ((float)stepIndex + 1.0) / max(clampedMaxSteps, 1.0), 1.0);
#endif
            rayUv = screenStartUv + screenDeltaUv * screenFraction;
#else
            float screenFraction = min(((float)stepIndex + 1.0) * screenStride
                / max(screenMajorPixels, 0.5), 1.0);
            rayUv = currentUv + screenDeltaUv * screenFraction;
#endif
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
#if defined(BEAMRT_WIDE_SCREEN_DDA) && defined(BEAMRT_SCREEN_DDA)
            if (useWideScreenDDA)
            {
                travelDistance = (((float)stepIndex + 1.0) / max(clampedMaxSteps, 1.0))
                    * maxWorldTravel;
            }
#endif
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
#if defined(BEAMRT_REFINED_HITS) || defined(BEAMRT_REQUIRE_FRONT_CROSSING)
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
#if defined(BEAMRT_ACTUAL_DDA_PROGRESS) && defined(BEAMRT_SCREEN_DDA)
                result.reachConfidence = beamrtActualDdaReachConfidence(
                    refinedUv, screenStartUv, fullScreenBudgetPixels, useScreenDDA);
#endif
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
        if (depthDeltaWorld >= 0.0 && depthDeltaWorld <= safeThickness
#ifdef BEAMRT_REQUIRE_FRONT_CROSSING
            && previousValid && previousDepthDelta < 0.0
#endif
            )
        {
            result.hit = 1.0;
            result.stepIndex = (float)stepIndex;
            result.travelDistance = travelDistance;
            result.uv = rayUv;
#if defined(BEAMRT_ACTUAL_DDA_PROGRESS) && defined(BEAMRT_SCREEN_DDA)
            result.reachConfidence = beamrtActualDdaReachConfidence(
                rayUv, screenStartUv, fullScreenBudgetPixels, useScreenDDA);
#endif
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
#if defined(BEAMRT_REFINED_HITS) || defined(BEAMRT_REQUIRE_FRONT_CROSSING)
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

#if defined(BEAMRT_TRUE_BLUE_NOISE) && defined(BEAMRT_VALIDATED_SAMPLING)
float2 beamrtCenteredByteNoise(float2 value)
{
    // The auxiliary target is R16F. Recover the original UNORM8 byte before
    // decoding its bin center, avoiding exact zero/one texture endpoints.
    return (floor(saturate(value) * 255.0 + 0.5) + 0.5) / 256.0;
}

uint beamrtSamplingHash(uint value)
{
    value ^= value >> 16u;
    value *= 0x7feb352du;
    value ^= value >> 15u;
    value *= 0x846ca68bu;
    value ^= value >> 16u;
    return value;
}

float beamrtSamplingChoice(uint seed, float sampleIndex)
{
    // Separate pixel/frame/path key: never condition the strategy choice on
    // either direction coordinate or the legacy jitter. The centered 23-bit
    // conversion is representable in float32 and strictly inside (0,1).
    uint value = beamrtSamplingHash(seed
        ^ ((uint)sampleIndex * 0x68e31da4u) ^ 0x1b56c4e9u);
    return (float(value >> 9u) + 0.5) * (1.0 / 8388608.0);
}
#endif

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
#ifdef BEAMRT_VALIDATED_SAMPLING
    , uint samplingSeed
#endif
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
    // second rotates the azimuth. Strength one uses only this direction pair.
    float blueU1 = (sampleIndex + blueSequence.x) * inversePathCount;
    float blueU2 = frac(blueSequence.y + sampleIndex * 0.61803398875);
    float sequenceStrength = saturate(blueStrength);
#ifdef BEAMRT_VALIDATED_SAMPLING
    // Stratum addition may round to one even if the input was below one.
    // Clamp after ALL direction-coordinate arithmetic, not just byte decode.
    blueU1 = clamp(blueU1, 1.0 / 16777216.0, 1.0 - 1.0 / 16777216.0);
    blueU2 = clamp(blueU2, 1.0 / 16777216.0, 1.0 - 1.0 / 16777216.0);
    float u1 = legacyU1;
    float u2 = legacyU2;
    if (sequenceStrength >= 1.0)
    {
        u1 = blueU1;
        u2 = blueU2;
    }
    else if (sequenceStrength > 0.0
        && beamrtSamplingChoice(samplingSeed, sampleIndex) < sequenceStrength)
    {
        // A probabilistic mixture of two complete strategies preserves their
        // distributions. Coordinate lerp invents a third, biased distribution
        // and interpolates azimuth across the wrong side of its wrap seam.
        u1 = blueU1;
        u2 = blueU2;
    }
#else
    // Retain the historical construction for older shader wrappers.
    float u1 = lerp(legacyU1, blueU1, sequenceStrength);
    float u2 = lerp(legacyU2, blueU2, sequenceStrength);
#endif
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
#ifdef BEAMRT_DDA_VIEW_INVARIANT_REACH
            if (giMarcherMode > 0.5)
            {
                screenReach = clamp(giRayReach, 0.05, 1.0);
            }
#endif
#endif
            float distanceFade = saturate(1.0 - diffuseHit.travelDistance
                / max(rayStepSize * rayMaxSteps * screenReach, 0.001));
            float legacyDistanceWeight = lerp(0.35, 1.0, distanceFade);
            float localDistanceWeight = pow(distanceFade, lerp(1.0, 5.0, locality));
            float distanceWeight = lerp(legacyDistanceWeight, localDistanceWeight, locality);
            float ddaTerminalConfidence = 1.0;
#ifdef BEAMRT_ACTUAL_DDA_PROGRESS
            ddaTerminalConfidence = diffuseHit.reachConfidence;
#elif defined(BEAMRT_DDA_TERMINAL_FADE)
            if (giMarcherMode > 0.5)
            {
                // Bounded DDA deliberately ends after a fixed number of screen
                // pixels. Fade hits approaching that artificial endpoint so a
                // receiver needing one additional pixel does not jump directly
                // from full GI to a zero-valued miss.
                float ddaStepBudget = min(
                    clamp(rayMaxSteps * screenReach, 1.0, 512.0),
                    max(giScreenBudgetSteps, 1.0));
                float ddaProgress = saturate(
                    (diffuseHit.stepIndex + 1.0) / max(ddaStepBudget, 1.0));
                ddaTerminalConfidence = 1.0 - smoothstep(0.55, 1.0, ddaProgress);
            }
#endif
            float sharedConfidence = receiverWeight * edgeConfidence
                * distanceWeight * roughSurfaceWeight * ddaTerminalConfidence;
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
#if defined(BEAMRT_GEOMETRIC_SURFACE_GUARD) && defined(BEAMRT_HIT_VALIDATION)
        if (screenHitRejectReason >= 3.5 && screenHitRejectReason < 4.5)
        {
            // A blocked screen ray cannot acquire unoccluded world-cache light
            // merely because its visible face did not emit toward the ray.
            return;
        }
#endif
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
#ifdef BEAMRT_SIX_INPUT_BINDINGS
            float4 cachedRadiance = beamrtAuxSurfel(cacheUv);
#else
            float4 cachedRadiance = tex2Dlod(surfelRadianceTex, float4(cacheUv, 0.0, 0.0));
#endif
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
#ifdef BEAMRT_SCENE_VISIBILITY_GI
                // A verified opaque blocker between receiver and cached
                // world surfel forbids bounced light from crossing this path.
                // Unknown scene geometry never falsely certifies visibility.
                // This runs only in opt-in v082; existing GI shaders remain
                // byte-for-byte equivalent in their active instructions.
                if (sceneVisibilityEnabled > 0.5 &&
                    beamrtGIBlockedByKnownGeometry(rayOrigin, surfelPosition))
                {
                    sampleRadiance = 0.0;
                    sampleConfidence = 0.0;
                    return;
                }
#endif
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
#ifdef BEAMRT_GEOMETRIC_SURFACE_GUARD
    float3 receiverGeometricNormal = beamrtGeometricSurfaceNormal(
        IN.uv0, decoded.w, worldPosition,
        IN.wsEyeRay, eyeRayDu, eyeRayDv, IN.uv0, decoded.xyz);
    float3 rayOrigin = worldPosition + receiverGeometricNormal * max(rayNormalBias, 0.0);
#else
    float3 rayOrigin = worldPosition + decoded.xyz * max(rayNormalBias, 0.0);
#endif
    float receiverRoughness = saturate(packedPrepass.b);
#ifdef BEAMRT_RECEIVER_RESPONSE_AT_COMPOSE
    // Compose applies the receiver's material response after reconstruction.
    float roughSurfaceWeight = 1.0;
#elif defined(BEAMRT_CONSERVATIVE_RECEIVER_RESPONSE)
    // The pre-v0.073 floor allowed polished paint, wheel metal, and other
    // low-roughness receivers to accept over a third of full diffuse GI. That
    // made a few valid-but-unrepresentative screen hits read as reflections.
    float roughSurfaceWeight = lerp(0.10, 1.0, pow(receiverRoughness, 0.75));
#else
    float roughSurfaceWeight = lerp(0.35, 1.0, receiverRoughness);
#endif
    bool allowScreenSpace = giSourceMode < 1.5;
    bool allowWorldSurfels = giSourceMode < 0.5 || giSourceMode > 1.5;
    float3 lightingSum = 0.0;
    float confidenceSum = 0.0;
    float hitCount = 0.0;
    int pathCount = (int)clamp(floor(giPathCount + 0.5), 1.0, 32.0);
#ifdef BEAMRT_BOUNDED_SCREEN_DDA
    // Screen DDA is currently an intersection experiment, not a Hi-Z
    // accelerator. Keep accidental 16x128/full-resolution settings from
    // turning one experimental toggle into billions of depth reads.
    if (giMarcherMode > 0.5
#ifdef BEAMRT_SOURCE_AWARE_DDA_BUDGET
        && allowScreenSpace
#endif
        )
    {
        pathCount = min(pathCount,
            (int)clamp(floor(giScreenBudgetPaths + 0.5), 1.0, 32.0));
    }
#endif
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
    float2 bluePixel = fmod(floor(IN.hpos.xy), 128.0);
    float2 blueUv = (bluePixel + 0.5) / 128.0;
#ifdef BEAMRT_SIX_INPUT_BINDINGS
    float2 blueNoise = beamrtAuxNativeNoise(blueUv);
#else
    float2 blueNoise = tex2Dlod(blueNoiseTex, float4(blueUv, 0.0, 0.0)).rg;
#endif
#ifdef BEAMRT_VALIDATED_SAMPLING
    blueNoise = beamrtCenteredByteNoise(blueNoise);
#endif
#ifdef BEAMRT_TRUE_BLUE_NOISE
    // Match BeamNG GTAO's integer Weyl sequence. The uint multiply wraps in
    // 32-bit fixed point, avoiding float phase-locking with short frame/LUT
    // periods. X is the radial offset; Y is the azimuthal rotation.
    // sequence is explicitly frozen to zero above while a diagnostic is
    // active. Using the raw frame index here made the supposedly fixed ray
    // direction change every frame and caused the observed flashing.
    uint blueFrame = (uint)max(floor(sequence + 0.5), 0.0);
#ifdef BEAMRT_VALIDATED_SAMPLING
    uint2 samplingPixel = (uint2)floor(IN.hpos.xy);
    uint samplingSeed = samplingPixel.x * 0x9e3779b9u
        ^ samplingPixel.y * 0x85ebca6bu
        ^ blueFrame * 0xc2b2ae35u ^ 0xb5297a4du;
#endif
    float blueTemporalOffset = float(blueFrame * 2447445413u)
        * (1.0 / 4294967296.0);
    float blueTemporalRotation = float(blueFrame * 3242174893u)
        * (1.0 / 4294967296.0);
    float2 blueSequence = frac(blueNoise
        + float2(blueTemporalOffset, blueTemporalRotation));
#ifdef BEAMRT_STBN_ATLAS
    if (giBlueNoiseMode > 0.5)
    {
        // Experimental scalar atlas: 64 128x128 RG frames in an 8x8 layout.
        // Raw-channel spectra do not establish directional STBN quality.
        uint stbnFrame = blueFrame & 63u;
        float2 stbnTile = float2(stbnFrame & 7u, stbnFrame >> 3u);
#ifdef BEAMRT_PRESERVE_ATLAS_VALUES
        // Keep each 64-frame block's original values and temporal ordering.
        // A toroidal lookup translation is a spatial permutation, preserving
        // tile histograms and within-block spectra after direction transforms.
        // Cycle zero is unchanged; later cycles visit different atlas pixels.
        // This extends coverage without promising unique byte-valued pairs.
        uint stbnLookupCycle = blueFrame >> 6u;
        uint2 stbnCycleOffset = uint2((stbnLookupCycle * 37u) & 127u,
            (stbnLookupCycle * 73u) & 127u);
        bluePixel = float2(((uint2)bluePixel + stbnCycleOffset) & 127u);
#endif
        float2 stbnUv = (bluePixel + stbnTile * 128.0 + 0.5) / 1024.0;
#ifdef BEAMRT_SIX_INPUT_BINDINGS
        blueSequence = beamrtAuxSTBN(stbnUv);
#else
        blueSequence = tex2Dlod(stbnNoiseTex, float4(stbnUv, 0.0, 0.0)).rg;
#endif
#ifdef BEAMRT_VALIDATED_SAMPLING
        blueSequence = beamrtCenteredByteNoise(blueSequence);
#ifndef BEAMRT_PRESERVE_ATLAS_VALUES
        // The atlas has only 64 slices. A new wrapped phase per cycle avoids
        // repeating identical primary directions while the counter advances.
        // This extends coverage, not a claim of jointly optimized vector STBN.
        uint stbnCycle = blueFrame >> 6u;
        float2 stbnCyclePhase = float2(float(stbnCycle * 2447445413u),
            float(stbnCycle * 3242174893u)) * (1.0 / 4294967296.0);
        blueSequence = frac(blueSequence + stbnCyclePhase);
#endif
#endif
    }
#endif
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
#ifdef BEAMRT_CONTINUOUS_HEMISPHERE_BASIS
    float3 tangent;
    float3 bitangent;
    beamrtBuildHemisphereBasis(decoded.xyz, tangent, bitangent);
#else
    float3 helperAxis = abs(decoded.z) < 0.999 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
    float3 tangent = normalize(cross(helperAxis, decoded.xyz));
    float3 bitangent = cross(decoded.xyz, tangent);
#endif

#ifdef BEAMRT_REFINED_HITS
    if (giTraceDebugMode > 0.5)
    {
#ifdef BEAMRT_STABLE_DIAGNOSTIC_RAY
        // A diagnostic tied to SV_Position changes direction whenever a
        // surface moves to another pixel. That made camera motion look like a
        // projection failure. Use one deterministic world-oriented
        // hemisphere direction so the view now isolates intersection and
        // screen-visibility behavior.
        float3 diagnosticDirection = normalize(
            tangent * 0.45 + bitangent * 0.20 + decoded.xyz * 0.87);
#else
        float3 diagnosticDirection = beamrtDiffuseDirection(
            decoded.xyz, tangent, bitangent, cell, baseFrameSeed,
            sequenceRotation, inversePathCount, 0.0
#ifdef BEAMRT_TRUE_BLUE_NOISE
            , blueSequence, blueStrength
#ifdef BEAMRT_VALIDATED_SAMPLING
            , samplingSeed
#endif
#endif
            );
#endif
#ifdef BEAMRT_DIAGNOSTIC_DIRECTION_VIEWS
        if (giTraceDebugMode >= 7.5 && giTraceDebugMode < 8.5)
        {
            // World direction encoded as RGB. A rigid world surface should
            // retain this color while the camera moves. If HITS changes while
            // this remains stable, the loss is screen-depth coverage rather
            // than a changing ray.
            return float4(diagnosticDirection * 0.5 + 0.5, 1.0);
        }
        if (giTraceDebugMode >= 8.5)
        {
            float viewAlignment = dot(
                normalize(diagnosticDirection), normalize(IN.wsEyeRay));
            float rear = saturate(-viewAlignment);
            float forward = saturate(viewAlignment);
            float transverse = 1.0 - saturate(abs(viewAlignment));
            return float4(rear, forward, transverse, 1.0);
        }
#endif
#ifdef BEAMRT_HIT_VALIDATION
        float diagnosticConfidence = 0.0;
        float diagnosticDepthError = max(rayThickness, 0.0001) * 2.0;
        float diagnosticRejectReason = 1.0;
        float3 diagnosticHitNormal = float3(0.0, 0.0, 1.0);
#if defined(BEAMRT_DIAGNOSTIC_GEOMETRY_GUARD) && defined(BEAMRT_GEOMETRIC_SURFACE_GUARD)
        if (dot(diagnosticDirection, receiverGeometricNormal) <= 0.0)
        {
            // The beauty path contributes zero for this receiver direction.
            // Direction/alignment views above remain available for inspection.
            if (giTraceDebugMode >= 6.5 && giTraceDebugMode < 7.5)
                return float4(1.0, 0.05, 0.85, 1.0); // geometric backface
            return float4(0.0, 0.0, 0.0, 1.0);
        }
#endif
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
#ifdef BEAMRT_VALIDATED_SAMPLING
            , samplingSeed
#endif
#endif
            );
#ifdef BEAMRT_GEOMETRIC_SURFACE_GUARD
        // Normal maps may tilt a shading-hemisphere sample below the actual
        // receiver. Such a path contributes zero; keep the original PDF/count.
        if (dot(diffuseDirection, receiverGeometricNormal) <= 0.0)
        {
            continue;
        }
#endif
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
#ifdef BEAMRT_CONTINUOUS_HIT_SUPPORT
    // RGB is already confidence-premultiplied. Preserve the same continuous
    // support instead of replacing it with binary per-path hit coverage.
    return float4(indirectLighting, confidence);
#else
    return float4(indirectLighting, max(coverage, confidence));
#endif
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
