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

float4 mainP(PFXVertToPix IN) : SV_Target0
{
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
            float3 hitNormal = decodeNormalXY(tex2Dlod(prepassTex, float4(rayUv, 0.0, 0.0)).xy);
            float facingConfidence = saturate(dot(hitNormal, -rayDirection) * 4.0);
            float distanceConfidence = saturate(1.0 - travelDistance / maxDistance);
            float confidence = beamrtEdgeConfidence(rayUv) * distanceConfidence * facingConfidence;
            float2 backbufferUv = beamrtPrepassUvToBackbufferUv(rayUv);
            float3 reflected = hdrDecode(tex2Dlod(backBufferTex, float4(backbufferUv, 0.0, 0.0)).rgb);
            return float4(reflected * confidence, confidence > 0.001 ? 1.0 : 0.0);
        }
    }

    return 0.0;
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
