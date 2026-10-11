#include "beamrtGITrace.h.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

bool beamrtProjectEyeVector(
    float3 eyeVector,
    float3 currentEyeRay,
    float3 eyeRayDu,
    float3 eyeRayDv,
    float2 currentUv,
    out float2 projectedUv,
    out float projectedDepth)
{
    float3 duCrossDv = cross(eyeRayDu, eyeRayDv);
    float determinant = dot(currentEyeRay, duCrossDv);
    if (abs(determinant) < 0.00000001)
    {
        projectedUv = 0.0;
        projectedDepth = 0.0;
        return false;
    }

    projectedDepth = dot(eyeVector, duCrossDv) / determinant;
    float weightedDu = dot(currentEyeRay, cross(eyeVector, eyeRayDv)) / determinant;
    float weightedDv = dot(currentEyeRay, cross(eyeRayDu, eyeVector)) / determinant;
    if (projectedDepth <= 0.000001)
    {
        projectedUv = 0.0;
        return false;
    }

    projectedUv = currentUv + float2(weightedDu, weightedDv) / projectedDepth;
    return true;
}

struct BeamRTRayHit
{
    float hit;
    float stepIndex;
    float travelDistance;
    float2 uv;
};

void beamrtGetSurfel(int index, out float3 position, out float radius, out float3 normal, out float sourceId)
{
    float4 positionRadius = 0.0;
    float4 normalSource = float4(0.0, 0.0, 1.0, 0.0);
    if (index == 0) { positionRadius = surfelPositionRadius0; normalSource = surfelNormalSource0; }
    else if (index == 1) { positionRadius = surfelPositionRadius1; normalSource = surfelNormalSource1; }
    else if (index == 2) { positionRadius = surfelPositionRadius2; normalSource = surfelNormalSource2; }
    else if (index == 3) { positionRadius = surfelPositionRadius3; normalSource = surfelNormalSource3; }
    else if (index == 4) { positionRadius = surfelPositionRadius4; normalSource = surfelNormalSource4; }
    else if (index == 5) { positionRadius = surfelPositionRadius5; normalSource = surfelNormalSource5; }
    else if (index == 6) { positionRadius = surfelPositionRadius6; normalSource = surfelNormalSource6; }
    else if (index == 7) { positionRadius = surfelPositionRadius7; normalSource = surfelNormalSource7; }
    else if (index == 8) { positionRadius = surfelPositionRadius8; normalSource = surfelNormalSource8; }
    else if (index == 9) { positionRadius = surfelPositionRadius9; normalSource = surfelNormalSource9; }
    else if (index == 10) { positionRadius = surfelPositionRadius10; normalSource = surfelNormalSource10; }
    else if (index == 11) { positionRadius = surfelPositionRadius11; normalSource = surfelNormalSource11; }
    else if (index == 12) { positionRadius = surfelPositionRadius12; normalSource = surfelNormalSource12; }
    else if (index == 13) { positionRadius = surfelPositionRadius13; normalSource = surfelNormalSource13; }
    else if (index == 14) { positionRadius = surfelPositionRadius14; normalSource = surfelNormalSource14; }
    else if (index == 15) { positionRadius = surfelPositionRadius15; normalSource = surfelNormalSource15; }
    else if (index == 16) { positionRadius = surfelPositionRadius16; normalSource = surfelNormalSource16; }
    else if (index == 17) { positionRadius = surfelPositionRadius17; normalSource = surfelNormalSource17; }
    else if (index == 18) { positionRadius = surfelPositionRadius18; normalSource = surfelNormalSource18; }
    else if (index == 19) { positionRadius = surfelPositionRadius19; normalSource = surfelNormalSource19; }
    else if (index == 20) { positionRadius = surfelPositionRadius20; normalSource = surfelNormalSource20; }
    else if (index == 21) { positionRadius = surfelPositionRadius21; normalSource = surfelNormalSource21; }
    else if (index == 22) { positionRadius = surfelPositionRadius22; normalSource = surfelNormalSource22; }
    else if (index == 23) { positionRadius = surfelPositionRadius23; normalSource = surfelNormalSource23; }
    else if (index == 24) { positionRadius = surfelPositionRadius24; normalSource = surfelNormalSource24; }
    else if (index == 25) { positionRadius = surfelPositionRadius25; normalSource = surfelNormalSource25; }
    else if (index == 26) { positionRadius = surfelPositionRadius26; normalSource = surfelNormalSource26; }
    else if (index == 27) { positionRadius = surfelPositionRadius27; normalSource = surfelNormalSource27; }
    else if (index == 28) { positionRadius = surfelPositionRadius28; normalSource = surfelNormalSource28; }
    else if (index == 29) { positionRadius = surfelPositionRadius29; normalSource = surfelNormalSource29; }
    else if (index == 30) { positionRadius = surfelPositionRadius30; normalSource = surfelNormalSource30; }
    else if (index == 31) { positionRadius = surfelPositionRadius31; normalSource = surfelNormalSource31; }
    position = positionRadius.xyz;
    radius = positionRadius.w;
    normal = normalize(normalSource.xyz);
    sourceId = normalSource.w;
}

bool beamrtTraceSurfels(
    float3 origin,
    float3 direction,
    out float nearestDistance,
    out int nearestIndex,
    out float3 hitNormal,
    out float hitRadialRatio)
{
    nearestDistance = max(surfelMaxDistance, 0.001);
    nearestIndex = -1;
    hitNormal = float3(0.0, 0.0, 1.0);
    hitRadialRatio = 1.0;
    int count = (int)clamp(surfelCount, 0.0, 32.0);

    [loop]
    for (int index = 0; index < 32; ++index)
    {
        if (index >= count)
        {
            break;
        }

        float3 position;
        float radius;
        float3 normal;
        float sourceId;
        beamrtGetSurfel(index, position, radius, normal, sourceId);
        float denominator = dot(direction, normal);
        if (abs(denominator) < 0.0001)
        {
            continue;
        }

        float candidateDistance = dot(position - origin, normal) / denominator;
        if (candidateDistance <= 0.01 || candidateDistance >= nearestDistance)
        {
            continue;
        }

        float3 candidatePoint = origin + direction * candidateDistance;
        float3 radialOffset = candidatePoint - position;
        radialOffset -= normal * dot(radialOffset, normal);
        if (dot(radialOffset, radialOffset) <= radius * radius)
        {
            nearestDistance = candidateDistance;
            nearestIndex = index;
            hitNormal = normal;
            hitRadialRatio = length(radialOffset) / max(radius, 0.001);
        }
    }

    return nearestIndex >= 0;
}

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
    float clampedMaxSteps = clamp(rayMaxSteps, 1.0, 128.0);

    [loop]
    for (int stepIndex = 0; stepIndex < 128; ++stepIndex)
    {
        if ((float)stepIndex >= clampedMaxSteps)
        {
            break;
        }

        float travelDistance = ((float)stepIndex + 1.0) * safeStepSize;
        float3 rayPoint = rayOrigin + rayDirection * travelDistance;
        float2 rayUv;
        float rayEyeDepth;
        bool projected = beamrtProjectEyeVector(
            rayPoint - eyePosWorld,
            currentEyeRay,
            eyeRayDu,
            eyeRayDv,
            currentUv,
            rayUv,
            rayEyeDepth
        );

        if (!projected || rayEyeDepth >= 0.9999 || any(rayUv <= viewportMin) || any(rayUv >= viewportMax))
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

float beamrtHash13(float3 value)
{
    value = frac(value * 0.1031);
    value += dot(value, value.yzx + 33.33);
    return frac((value.x + value.y) * value.z);
}

float3 beamrtDiffuseDirection(float3 worldPosition, float3 normal, float sampleIndex)
{
    // Up to sixteen stratified cosine-weighted directions per pixel. The frame
    // term rotates the pattern so temporal accumulation continues to converge.
    float safeCellSize = max(giCellSize, 0.005);
    float3 cell = floor(worldPosition / safeCellSize);
    float sequence = fmod(max(giFrameIndex, 0.0), 64.0);
    float3 frameSeed = float3(sequence * 19.19, sequence * 7.73, sequence * 13.37)
        + sampleIndex * float3(23.17, 41.03, 11.91);
    float jitter1 = beamrtHash13(cell + frameSeed + float3(0.0, 17.0, 31.0));
    float jitter2 = beamrtHash13(cell + frameSeed + float3(47.0, 11.0, 5.0));
    float safePathCount = clamp(floor(giPathCount + 0.5), 1.0, 16.0);
    float u1 = (sampleIndex + jitter1) / safePathCount;
    float u2 = frac(jitter2 + sampleIndex * 0.61803398875 + sequence * 0.07106781186);
    float radius = sqrt(u1);
    float sinePhi;
    float cosinePhi;
    sincos(u2 * 6.28318530718, sinePhi, cosinePhi);

    float3 helperAxis = abs(normal.z) < 0.999 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
    float3 tangent = normalize(cross(helperAxis, normal));
    float3 bitangent = cross(normal, tangent);
    float3 localDirection = float3(radius * cosinePhi, radius * sinePhi, sqrt(max(0.0, 1.0 - u1)));
    return normalize(tangent * localDirection.x + bitangent * localDirection.y + normal * localDirection.z);
}

float2 beamrtPrepassUvToBackbufferUv(float2 prepassUv)
{
    float2 viewportUv = (prepassUv - rtParams0.xy) / rtParams0.zw;
    return viewportCoordToRenderTarget(viewportUv, rtParams2);
}

float beamrtScreenEdgeConfidence(float2 prepassUv)
{
    float2 viewportOtherCorner = rtParams0.xy + rtParams0.zw;
    float2 viewportMin = min(rtParams0.xy, viewportOtherCorner);
    float2 viewportMax = max(rtParams0.xy, viewportOtherCorner);
    float2 normalizedUv = (prepassUv - viewportMin) / max(viewportMax - viewportMin, 0.000001);
    float edgeDistance = min(min(normalizedUv.x, normalizedUv.y), min(1.0 - normalizedUv.x, 1.0 - normalizedUv.y));
    return saturate(edgeDistance / 0.08);
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
    radiance = hdrDecode(tex2Dlod(backBufferTex, float4(backbufferUv, 0.0, 0.0)).rgb);
    float depthConfidence = saturate(1.0 - depthDeltaWorld / tolerance);
    float normalConfidence = saturate((normalAgreement - 0.2) / 0.8);
    confidence = depthConfidence * normalConfidence * beamrtScreenEdgeConfidence(surfelUv);
    return confidence > 0.0001;
}

float3 beamrtClampRadiance(float3 radiance)
{
    radiance = max(radiance, 0.0);
    float peak = max(max(radiance.r, radiance.g), radiance.b);
    return radiance * min(1.0, max(giClamp, 0.0001) / max(peak, 0.0001));
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
            float3 bounceLinear = beamrtClampRadiance(hdrDecode(tex2Dlod(backBufferTex, float4(hitBackbufferUv, 0.0, 0.0)).rgb));
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
                // Large cache discs were behaving like colored fog volumes. Fade
                // their edges and reduce confidence as radius grows, while keeping
                // the old permissive behavior available at suppression = 0.
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

    return;
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
    int pathCount = (int)clamp(floor(giPathCount + 0.5), 1.0, 16.0);

    [loop]
    for (int sampleIndex = 0; sampleIndex < 16; ++sampleIndex)
    {
        if (sampleIndex >= pathCount)
        {
            break;
        }
        float3 diffuseDirection = beamrtDiffuseDirection(worldPosition, decoded.xyz, (float)sampleIndex);
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

    // Divide by the fixed path count, not hit count: unoccluded directions
    // contribute zero and naturally keep the bounce energy bounded.
    float inversePathCount = 1.0 / max((float)pathCount, 1.0);
    float3 indirectLighting = lightingSum * inversePathCount;
    float coverage = hitCount * inversePathCount;
    float confidence = saturate(confidenceSum * inversePathCount);
    return float4(indirectLighting, max(coverage, confidence));
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
