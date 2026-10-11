// v0.021 stores a signed, confidence-premultiplied reflection delta rather
// than a confidence-darkened replacement color.  The composer can therefore
// fade uncertain hits back to BeamNG's original pixel without removing base
// lighting. Candidates must cross the depth surface, are refined by binary
// search, and the first physical crossing owns the result so a weak foreground
// surface can never be skipped in favor of occluded geometry behind it.
#include "beamrtReflectionTrace.h.hlsl"

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

float2 beamrtPrepassUvToBackbufferUv(float2 prepassUv)
{
    float2 viewportUv = (prepassUv - rtParams0.xy) / rtParams0.zw;
    return viewportCoordToRenderTarget(viewportUv, rtParams2);
}

float beamrtEdgeConfidence(float2 uv)
{
    float2 otherCorner = rtParams0.xy + rtParams0.zw;
    float2 viewportMin = min(rtParams0.xy, otherCorner);
    float2 viewportMax = max(rtParams0.xy, otherCorner);
    float2 normalizedUv = (uv - viewportMin) / max(viewportMax - viewportMin, 0.000001);
    float edgeDistance = min(min(normalizedUv.x, normalizedUv.y), min(1.0 - normalizedUv.x, 1.0 - normalizedUv.y));
    return smoothstep(0.0, 0.08, edgeDistance);
}

float beamrtSceneEyeDepth(float2 uv)
{
    float sceneNdcDepth = tex2Dlod(prepassDepthTex, float4(uv, 0.0, 0.0)).r;
    float sceneRealDepth = ndcToRealDepth(sceneNdcDepth, projParams.zw);
    return realToEyeLinearDepth(sceneRealDepth, projParams);
}

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float3 receiverLinear = hdrDecode(tex2D(backBufferTex, IN.uv2).rgb);
    float4 packedPrepass = tex2D(prepassTex, IN.uv0);
    float4 decoded = decodeGBuffer(
        TEX_SAMPLER(prepassDepthTex),
        TEX_SAMPLER(prepassTex),
        IN.uv0,
        projParams
    );
    float roughness = max(packedPrepass.b, 0.02);
    if (decoded.w >= 0.9999 || roughness >= max(reflectionMaxRoughness, 0.021))
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
    float3 viewTravel = normalize(worldPosition - eyePosWorld);
    float3 rayDirection = normalize(reflect(viewTravel, decoded.xyz));
    if (dot(rayDirection, decoded.xyz) <= 0.001)
    {
        return 0.0;
    }

    float3 rayOrigin = worldPosition + decoded.xyz * max(reflectionNormalBias, 0.0);
    float safeStep = max(reflectionStepSize, 0.02);
    float safeThickness = max(reflectionThickness, 0.02);
    float maxDistance = max(reflectionMaxDistance, safeStep);
    int maxSteps = (int)clamp(reflectionMaxSteps, 1.0, 96.0);
    float2 otherCorner = rtParams0.xy + rtParams0.zw;
    float2 viewportMin = min(rtParams0.xy, otherCorner);
    float2 viewportMax = max(rtParams0.xy, otherCorner);
    float2 uvTexel = max(float2(abs(uvDx), abs(uvDy)), 0.000001);

    bool hasFrontSample = false;
    float frontTravel = 0.0;
    float3 bestDelta = 0.0;
    float bestConfidence = 0.0;

    [loop]
    for (int stepIndex = 0; stepIndex < 96; ++stepIndex)
    {
        if (stepIndex >= maxSteps)
        {
            break;
        }

        float travelDistance = ((float)stepIndex + 1.0) * safeStep;
        if (travelDistance > maxDistance)
        {
            break;
        }

        float3 rayPoint = rayOrigin + rayDirection * travelDistance;
        float2 rayUv;
        float rayEyeDepth;
        if (!beamrtProjectEyeVector(
            rayPoint - eyePosWorld,
            IN.wsEyeRay,
            eyeRayDu,
            eyeRayDv,
            IN.uv0,
            rayUv,
            rayEyeDepth))
        {
            break;
        }
        if (rayEyeDepth >= 0.9999 || any(rayUv <= viewportMin) || any(rayUv >= viewportMax))
        {
            break;
        }

        float sceneEyeDepth = beamrtSceneEyeDepth(rayUv);
        if (sceneEyeDepth >= 0.9999)
        {
            hasFrontSample = false;
            continue;
        }

        float depthDeltaWorld = (rayEyeDepth - sceneEyeDepth) * projParams.y;
        if (depthDeltaWorld < 0.0)
        {
            hasFrontSample = true;
            frontTravel = travelDistance;
            continue;
        }

        // A valid screen-space intersection crosses from in front of the depth
        // surface to behind it.  Do not accept the old first-positive slab test,
        // which frequently selected the receiver or unrelated rear geometry.
        float maximumBracket = max(safeThickness * 4.0, safeStep * 3.0);
        if (!hasFrontSample)
        {
            hasFrontSample = false;
            continue;
        }
        if (depthDeltaWorld > maximumBracket)
        {
            // A large jump is normally an opaque silhouette/disocclusion. It
            // is not a license to look through that foreground boundary.
            break;
        }

        float lowTravel = frontTravel;
        float highTravel = travelDistance;
        float2 refinedUv = rayUv;
        float refinedRayEyeDepth = rayEyeDepth;
        float refinedSceneEyeDepth = sceneEyeDepth;

        [unroll]
        for (int refineIndex = 0; refineIndex < 5; ++refineIndex)
        {
            float middleTravel = (lowTravel + highTravel) * 0.5;
            float3 middlePoint = rayOrigin + rayDirection * middleTravel;
            float2 middleUv;
            float middleRayEyeDepth;
            if (!beamrtProjectEyeVector(
                middlePoint - eyePosWorld,
                IN.wsEyeRay,
                eyeRayDu,
                eyeRayDv,
                IN.uv0,
                middleUv,
                middleRayEyeDepth)
                || any(middleUv <= viewportMin)
                || any(middleUv >= viewportMax))
            {
                lowTravel = middleTravel;
                continue;
            }

            float middleSceneEyeDepth = beamrtSceneEyeDepth(middleUv);
            if (middleSceneEyeDepth >= 0.9999)
            {
                lowTravel = middleTravel;
                continue;
            }

            float middleDelta = (middleRayEyeDepth - middleSceneEyeDepth) * projParams.y;
            if (middleDelta >= 0.0)
            {
                highTravel = middleTravel;
                refinedUv = middleUv;
                refinedRayEyeDepth = middleRayEyeDepth;
                refinedSceneEyeDepth = middleSceneEyeDepth;
            }
            else
            {
                lowTravel = middleTravel;
            }
        }

        float refinedDelta = (refinedRayEyeDepth - refinedSceneEyeDepth) * projParams.y;
        float2 travelPixels2 = (refinedUv - IN.uv0) / uvTexel;
        float travelConfidence = smoothstep(1.0, 2.5, length(travelPixels2));
        if (refinedDelta < -0.001 || travelConfidence <= 0.001)
        {
            hasFrontSample = false;
            continue;
        }
        if (refinedDelta > safeThickness)
        {
            // A depth discontinuity is still an occluder. Do not march through
            // it and accidentally select unrelated geometry behind it.
            break;
        }

        float3 hitNormal = decodeNormalXY(tex2Dlod(prepassTex, float4(refinedUv, 0.0, 0.0)).xy);
        float facingDot = dot(hitNormal, -rayDirection);
        if (facingDot <= 0.02)
        {
            break;
        }

        // Depth agreement around the hit suppresses silhouettes and thin rear
        // surfaces without making them a hard binary rejection.
        float continuity = 0.0;
        float2 continuityOffsets[4] = {
            float2(uvTexel.x, 0.0), float2(-uvTexel.x, 0.0),
            float2(0.0, uvTexel.y), float2(0.0, -uvTexel.y)
        };
        [unroll]
        for (int continuityIndex = 0; continuityIndex < 4; ++continuityIndex)
        {
            float2 neighborUv = clamp(refinedUv + continuityOffsets[continuityIndex], viewportMin, viewportMax);
            float neighborDepth = beamrtSceneEyeDepth(neighborUv);
            if (neighborDepth < 0.9999)
            {
                float neighborDelta = abs(neighborDepth - refinedSceneEyeDepth) * projParams.y;
                continuity += 1.0 - smoothstep(0.05, max(0.35, safeThickness * 2.0), neighborDelta);
            }
        }
        continuity *= 0.25;

        float facingConfidence = smoothstep(0.02, 0.35, facingDot);
        float distanceConfidence = sqrt(saturate(1.0 - highTravel / maxDistance));
        float continuityConfidence = lerp(0.30, 1.0, continuity);
        float confidence = beamrtEdgeConfidence(refinedUv)
            * distanceConfidence * facingConfidence * travelConfidence * continuityConfidence;
        float2 backbufferUv = beamrtPrepassUvToBackbufferUv(refinedUv);
        float3 reflectedLinear = hdrDecode(tex2Dlod(backBufferTex, float4(backbufferUv, 0.0, 0.0)).rgb);
        bestDelta = (reflectedLinear - receiverLinear) * confidence;
        bestConfidence = confidence;
        break;
    }

    return float4(bestDelta, bestConfidence);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
