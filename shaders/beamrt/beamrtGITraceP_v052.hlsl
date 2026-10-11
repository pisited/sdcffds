// Keep the complete v0.051 implementation compiled under private names so the
// unchanged surfel/cache/radiance helpers remain shared by this low-risk pass.
#define main beamrtLegacyMain_v051
#ifdef SHADER_STAGE_VS
    #define mainP beamrtLegacyMainP_v051
#else
    #define mainV beamrtLegacyMainV_v051
#endif
#define beamrtTraceRay beamrtTraceRay_v051
#define beamrtDiffuseDirection beamrtDiffuseDirection_v051
#define beamrtTraceLightingSample beamrtTraceLightingSample_v051
#include "beamrtGITraceP_v051.hlsl"
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

BeamRTRayHit beamrtTraceRay(
    float3 rayOrigin,
    float3 rayDirection,
    float3 currentEyeRay,
    float3 eyeRayDu,
    float3 eyeRayDv,
    float2 currentUv)
{
    BeamRTRayHit result;
    result.hit = 0.0;
    result.stepIndex = -1.0;
    result.travelDistance = 0.0;
    result.uv = 0.0;

    float2 viewportOtherCorner = rtParams0.xy + rtParams0.zw;
    float2 viewportMin = min(rtParams0.xy, viewportOtherCorner);
    float2 viewportMax = max(rtParams0.xy, viewportOtherCorner);
    float safeStepSize = max(rayStepSize, 0.0001);
    float safeThickness = max(rayThickness, 0.0001);
    float clampedMaxSteps = clamp(rayMaxSteps, 1.0, 512.0);

    // The projection of rayOrigin + rayDirection * t is affine before the
    // final perspective divide. Compute the basis and its intercept/slopes
    // once per path instead of rebuilding cross/dot products at every step.
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

    [loop]
    for (int stepIndex = 0; stepIndex < 512; ++stepIndex)
    {
        if ((float)stepIndex >= clampedMaxSteps)
        {
            break;
        }

        float travelDistance = ((float)stepIndex + 1.0) * safeStepSize;
        float rayEyeDepth = depthIntercept + depthSlope * travelDistance;
        if (rayEyeDepth <= 0.000001)
        {
            break;
        }

        float2 weightedOffset = float2(
            duIntercept + duSlope * travelDistance,
            dvIntercept + dvSlope * travelDistance
        );
        float2 rayUv = currentUv + weightedOffset / rayEyeDepth;
        if (rayEyeDepth >= 0.9999 || any(rayUv <= viewportMin) || any(rayUv >= viewportMax))
        {
            break;
        }

        float sceneNdcDepth = tex2Dlod(prepassDepthTex, float4(rayUv, 0.0, 0.0)).r;
        float sceneRealDepth = ndcToRealDepth(sceneNdcDepth, projParams.zw);
        float sceneEyeDepth = realToEyeLinearDepth(sceneRealDepth, projParams);
        if (sceneEyeDepth >= 0.9999)
        {
            continue;
        }

        float depthDeltaWorld = (rayEyeDepth - sceneEyeDepth) * projParams.y;
        if (depthDeltaWorld >= 0.0 && depthDeltaWorld <= safeThickness)
        {
            result.hit = 1.0;
            result.stepIndex = (float)stepIndex;
            result.travelDistance = travelDistance;
            result.uv = rayUv;
            break;
        }
    }

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
    float sampleIndex)
{
    float3 frameSeed = baseFrameSeed + sampleIndex * float3(23.17, 41.03, 11.91);
    float jitter1 = beamrtHash13(cell + frameSeed + float3(0.0, 17.0, 31.0));
    float jitter2 = beamrtHash13(cell + frameSeed + float3(47.0, 11.0, 5.0));
    float u1 = (sampleIndex + jitter1) * inversePathCount;
    float u2 = frac(jitter2 + sampleIndex * 0.61803398875 + sequenceRotation);
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
    // Deliberately unchanged from v0.051. The cosine-estimator correction is
    // excluded from this optimization milestone.
    float receiverCosine = saturate(dot(receiverNormal, diffuseDirection));

    if (allowScreenSpace)
    {
        BeamRTRayHit diffuseHit = beamrtTraceRay(
            rayOrigin,
            diffuseDirection,
            currentEyeRay,
            eyeRayDu,
            eyeRayDv,
            currentUv
        );
        if (diffuseHit.hit >= 0.5)
        {
            float2 hitBackbufferUv = beamrtPrepassUvToBackbufferUv(diffuseHit.uv);
            float3 bounceLinear = beamrtClampRadiance(
                beamrtDiffuseLikeRadiance(diffuseHit.uv, hitBackbufferUv)
            );
            float3 hitNormal = decodeNormalXY(tex2Dlod(prepassTex, float4(diffuseHit.uv, 0.0, 0.0)).xy);
            float emitterCosine = saturate(dot(hitNormal, -diffuseDirection));
            float edgeConfidence = beamrtScreenEdgeConfidence(diffuseHit.uv);
            float distanceFade = saturate(1.0 - diffuseHit.travelDistance / max(rayStepSize * rayMaxSteps, 0.001));
            sampleConfidence = receiverCosine * emitterCosine * edgeConfidence
                * lerp(0.35, 1.0, distanceFade) * roughSurfaceWeight;
            sampleRadiance = bounceLinear * sampleConfidence;
            return;
        }
    }

    if (allowWorldSurfels && worldGIStrength > 0.0)
    {
        float surfelDistance = 0.0;
        int surfelIndex = -1;
        float3 surfelNormal = float3(0.0, 0.0, 1.0);
        float surfelRadialRatio = 1.0;
        if (beamrtTraceSurfels(rayOrigin, diffuseDirection, surfelDistance, surfelIndex, surfelNormal, surfelRadialRatio))
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
                float distanceFade = saturate(1.0 - surfelDistance / max(surfelMaxDistance, 0.001));
                float radialConfidence = pow(saturate(1.0 - surfelRadialRatio * surfelRadialRatio), 2.0);
                float radiusConfidence = saturate(2.0 / max(surfelRadius, 0.1));
                float leakGuard = lerp(1.0, radialConfidence * radiusConfidence, saturate(worldLeakSuppression));
                sampleConfidence = receiverCosine * emitterCosine * distanceFade
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

    // Per-pixel invariants shared by every diffuse path.
    float safeCellSize = max(giCellSize, 0.005);
    float3 cell = floor(worldPosition / safeCellSize);
    float sequence = fmod(max(giFrameIndex, 0.0), 64.0);
    float3 baseFrameSeed = float3(sequence * 19.19, sequence * 7.73, sequence * 13.37);
    float sequenceRotation = sequence * 0.07106781186;
    float3 helperAxis = abs(decoded.z) < 0.999 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
    float3 tangent = normalize(cross(helperAxis, decoded.xyz));
    float3 bitangent = cross(decoded.xyz, tangent);

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
            (float)sampleIndex);
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
