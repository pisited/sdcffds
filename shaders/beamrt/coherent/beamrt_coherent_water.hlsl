#ifndef BEAMRT_COH_SSR_WATER_HLSL
#define BEAMRT_COH_SSR_WATER_HLSL

// This is an optional artistic grade, not a sampled stock water material color.
// Zero must be an exact bypass, including on water pixels at grazing angles.
float3 BrtcApplyAddedWaterTint(float3 color, float waterMask, float angleMask)
{
    if (uWaterColorStrength <= 0.0 || waterMask <= 0.001) return color;
    float tint = saturate(waterMask) * saturate(uWaterColorStrength) *
                 (0.25 + 0.75 * (1.0 - saturate(angleMask)));
    return lerp(color, BrtcDisplayAuthored(uWaterDeepColor.rgb), tint);
}

struct WaterSurfaceInfo
{
    float mask;
    float planeMask;
    float bakedMask;
    float angleMask;
    float eyeDepth01;
    float3 worldPos;
    float3 geometricNormal;
};

WaterSurfaceInfo EmptyWaterSurfaceInfo(float sceneEyeDepth01, float3 sceneWorldPos)
{
    WaterSurfaceInfo water;
    water.mask = 0.0;
    water.planeMask = 0.0;
    water.bakedMask = 0.0;
    water.angleMask = 1.0;
    water.eyeDepth01 = sceneEyeDepth01;
    water.worldPos = sceneWorldPos;
    water.geometricNormal = float3(0.0, 0.0, 1.0);
    return water;
}

float4 GetWaterPlaneConst(int i)
{
    if (i == 0) return uWaterPlane0;
    if (i == 1) return uWaterPlane1;
    if (i == 2) return uWaterPlane2;
    if (i == 3) return uWaterPlane3;
    return float4(0.0, 0.0, 0.0, 0.0);
}

float HorizontalWaterPlaneMask(float height, float sceneEyeDepth01, float3 sceneWorldPos, out float t, out float3 hitWorldPos, out float hitEyeDepth01)
{
    float startSide = eyePosWorld.z - height;
    float endSide = sceneWorldPos.z - height;
    float denom = endSide - startSide;
    t = (-startSide) / (abs(denom) > 1e-6 ? denom : 1e-6);

    float inSegment = step(0.0, t) * step(t, 1.0);
    float eyeAbove = smoothstep(0.001, max(uWaterPlaneFadeMeters, 0.001), startSide);
    float sceneBelow = smoothstep(0.001, max(uWaterPlaneFadeMeters, 0.001), -endSide);
    float mask = saturate(inSegment * eyeAbove * sceneBelow);

    hitEyeDepth01 = sceneEyeDepth01 * saturate(t);
    hitWorldPos = lerp(eyePosWorld, sceneWorldPos, saturate(t));
    hitWorldPos.z = height;
    return mask;
}

bool SampleWaterSurfaceHeight(float2 worldXY, out float surfaceHeight)
{
    surfaceHeight = 0.0;
    if (uRiverMaskEnable <= 0.5 || uRiverWorldSize <= 0.001)
        return false;

    float2 mapUV = (worldXY - uRiverOriginXY) / uRiverWorldSize;
    if (any(mapUV < float2(0.0, 0.0)) || any(mapUV >= float2(1.0, 1.0)))
        return false;
    if (uRiverFlipY > 0.5)
        mapUV.y = 1.0 - mapUV.y;

    float encoded = auxTexTex.Load(BrtcTexelAt(mapUV, gAuxSize, gAuxMaxCoord)).r;
    float code = floor(saturate(encoded) * 65535.0 + 0.5);
    if (code < 0.5)
        return false;

    float normalizedHeight = saturate((code - 1.0) / 65534.0);
    surfaceHeight = uRiverHeightMin + normalizedHeight * max(uRiverHeightRange, 0.001);
    return true;
}

bool ResolveBakedWaterSeed(float seedT, float sceneEyeDepth01, float3 sceneWorldPos,
                      out float mask, out float hitT,
                      out float hitEyeDepth01, out float3 hitWorldPos)
{
    mask = 0.0;
    hitT = 1.0;
    hitEyeDepth01 = sceneEyeDepth01;
    hitWorldPos = sceneWorldPos;

    float rayZ = sceneWorldPos.z - eyePosWorld.z;
    if (abs(rayZ) <= 1e-6)
        return false;

    float t = seedT;
    float surfaceHeight = 0.0;
    [unroll]
    for (int iteration = 0; iteration < 3; iteration++)
    {
        if (t < 0.0 || t > 1.0)
            return false;
        float3 queryWorldPos = lerp(eyePosWorld, sceneWorldPos, saturate(t));
        if (!SampleWaterSurfaceHeight(queryWorldPos.xy, surfaceHeight))
            return false;
        t = (surfaceHeight - eyePosWorld.z) / rayZ;
    }

    if (t < 0.0 || t > 1.0)
        return false;

    float3 acceptedWorldPos = lerp(eyePosWorld, sceneWorldPos, t);
    float acceptedHeight = 0.0;
    if (!SampleWaterSurfaceHeight(acceptedWorldPos.xy, acceptedHeight))
        return false;
    float residualTolerance = max(0.05, uRiverHeightRange * (4.0 / 65534.0));
    if (abs(acceptedHeight - surfaceHeight) > residualTolerance)
        return false;

    float inSegment = step(0.0, t) * step(t, 1.0);
    float startSide = eyePosWorld.z - surfaceHeight;
    float endSide = sceneWorldPos.z - surfaceHeight;
    float fade = max(uWaterPlaneFadeMeters, 0.001);
    float eyeSeparated = smoothstep(0.0, fade, abs(startSide));
    float sceneSeparated = smoothstep(0.0, fade, abs(endSide));
    mask = saturate(inSegment * eyeSeparated * sceneSeparated);
    if (mask <= 0.0001)
        return false;

    hitT = saturate(t);
    hitEyeDepth01 = sceneEyeDepth01 * hitT;
    hitWorldPos = lerp(eyePosWorld, sceneWorldPos, hitT);
    hitWorldPos.z = surfaceHeight;
    return true;
}

void BrtcKeepNearerBakedSeed(float seedT, float sceneEyeDepth01, float3 sceneWorldPos,
                            inout float bestMask, inout float bestT,
                            inout float bestEyeDepth01, inout float3 bestWorldPos)
{
    float mask, t, eyeDepth01;
    float3 worldPos;
    if (ResolveBakedWaterSeed(seedT, sceneEyeDepth01, sceneWorldPos, mask, t, eyeDepth01, worldPos)
        && t < bestT)
    {
        bestMask = mask;
        bestT = t;
        bestEyeDepth01 = eyeDepth01;
        bestWorldPos = worldPos;
    }
}

float BakedWaterMask(float sceneEyeDepth01, float3 sceneWorldPos,
                     out float hitT, out float hitEyeDepth01, out float3 hitWorldPos)
{
    hitT = 2.0;
    hitEyeDepth01 = sceneEyeDepth01;
    hitWorldPos = sceneWorldPos;
    float mask = 0.0;

    float rayZ = sceneWorldPos.z - eyePosWorld.z;
    if (uRiverMaskEnable > 0.5 && abs(rayZ) > 1e-6)
    {
        BrtcKeepNearerBakedSeed(1.0, sceneEyeDepth01, sceneWorldPos, mask, hitT, hitEyeDepth01, hitWorldPos);
        BrtcKeepNearerBakedSeed((uRiverReferenceHeight - eyePosWorld.z) / rayZ,
                               sceneEyeDepth01, sceneWorldPos, mask, hitT, hitEyeDepth01, hitWorldPos);
        BrtcKeepNearerBakedSeed((uRiverHeightMin - eyePosWorld.z) / rayZ,
                               sceneEyeDepth01, sceneWorldPos, mask, hitT, hitEyeDepth01, hitWorldPos);
        BrtcKeepNearerBakedSeed((uRiverHeightMin + uRiverHeightRange - eyePosWorld.z) / rayZ,
                               sceneEyeDepth01, sceneWorldPos, mask, hitT, hitEyeDepth01, hitWorldPos);
    }

    if (mask <= 0.0)
    {
        hitT = 1.0;
        hitEyeDepth01 = sceneEyeDepth01;
        hitWorldPos = sceneWorldPos;
    }
    return mask;
}

float WaterAngleMask(float3 viewToSurfaceDir, float3 normalWS)
{
    float3 surfaceToEye = normalize(-viewToSurfaceDir);
    float cosI = saturate(dot(normalWS, surfaceToEye));
    const float eta = 1.333;
    float cosT = sqrt(saturate(1.0 - (1.0 - cosI * cosI) / (eta * eta)));
    float rs = (cosI - eta * cosT) / max(cosI + eta * cosT, 1e-6);
    float rp = (eta * cosI - cosT) / max(eta * cosI + cosT, 1e-6);
    return saturate(0.5 * (rs * rs + rp * rp));
}

WaterSurfaceInfo GetWaterSurfaceInfo(PFXVertToPix IN, float2 uv, float sceneEyeDepth01, float3 sceneWorldPos)
{
    WaterSurfaceInfo water = EmptyWaterSurfaceInfo(sceneEyeDepth01, sceneWorldPos);

    if (uWaterSSR <= 0.5)
        return water;

    const float minCoverage = 0.0001;
    float best = 0.0;
    float bestEye = 1e20;

    [loop]
    for (int i = 0; i < BEAMRT_COH_WATER_MAX_PLANES; i++)
    {
        if (i >= (int)uWaterPlaneCount)
            break;

        float4 plane = GetWaterPlaneConst(i);
        float3 pHit;
        float pEye;
        float pt;
        float m = HorizontalWaterPlaneMask(plane.x, sceneEyeDepth01, sceneWorldPos, pt, pHit, pEye) * plane.y;
        water.planeMask = max(water.planeMask, m);
        if (m > minCoverage && pEye < bestEye)
        {
            best = m;
            bestEye = pEye;
            water.eyeDepth01 = pEye;
            water.worldPos = pHit;
        }
    }

    float3 bakedHit;
    float bakedEye;
    float bakedT;
    float bakedM = BakedWaterMask(sceneEyeDepth01, sceneWorldPos,
                                  bakedT, bakedEye, bakedHit);
    water.bakedMask = bakedM;
    if (bakedM > minCoverage && bakedEye < bestEye)
    {
        best = bakedM;
        bestEye = bakedEye;
        water.eyeDepth01 = bakedEye;
        water.worldPos = bakedHit;
    }

    water.mask = saturate(best);
    if (water.mask > 0.0001)
    {
        float3 eyeRayDir = normalize(sceneWorldPos - eyePosWorld);
        water.worldPos += eyeRayDir * uWaterSurfaceDepthBias;
        water.angleMask = WaterAngleMask(normalize(water.worldPos - eyePosWorld), float3(0.0, 0.0, 1.0));
    }

    return water;
}

WaterSurfaceInfo DecodeCombinedWaterSurface(PFXVertToPix IN, float4 combinedDepth)
{
    float eyeDepth01 = saturate(combinedDepth.r);
    float waterMask = step(0.5, saturate(combinedDepth.b)) * step(eyeDepth01, 0.99999);
    float3 worldPos = eyePosWorld + IN.wsEyeRay * eyeDepth01;
    WaterSurfaceInfo water = EmptyWaterSurfaceInfo(eyeDepth01, worldPos);

    water.mask = waterMask;
    water.eyeDepth01 = eyeDepth01;
    water.worldPos = worldPos;
    water.geometricNormal = float3(0.0, 0.0, 1.0);

    if (waterMask > 0.0001)
    {
        float3 eyeRayDir = normalize(worldPos - eyePosWorld);
        water.worldPos += eyeRayDir * uWaterSurfaceDepthBias;
        water.angleMask = WaterAngleMask(eyeRayDir, water.geometricNormal);
    }

    return water;
}

float3 ReconstructWaveNormal(float3 waterWorldPos, float distanceFade, float camDist)
{
    float2 wp = waterWorldPos.xy * max(uWaterWaveScale, 0.0001);
    float t = uTime * max(uWaterRippleSpeed, 0.0) * 0.6;

    float2 slope = float2(0.0, 0.0);
    float4 waves[3] = { uWaterWave0, uWaterWave1, uWaterWave2 };
    [unroll]
    for (int i = 0; i < 3; i++)
    {
        float2 dir  = waves[i].xy;
        float  freq = waves[i].z;
        float  amp  = waves[i].w;
        float  phase = dir.x * wp.x + dir.y * wp.y + t * freq;
        slope += dir * (cos(phase) * amp);
    }
    slope *= uWaterOverallMag;

    if (uWaterNoiseRipple > 0.001)
    {
        float engineRipple = max(uWaterRippleMag.x + uWaterRippleMag.y + uWaterRippleMag.z, 0.0);
        slope += BrtcWaterRippleSlope(wp, t) * (uWaterNoiseRipple * 0.5 * saturate(engineRipple * 8.0));
    }

    slope *= distanceFade;
    slope *= uWaterWaveStrength;

    return normalize(float3(-slope.x, -slope.y, 1.0));
}

float3 ApplyWaterNormal(float3 normalWS, float waterMask, float3 waterWorldPos)
{
    float3 flatNormal = float3(0.0, 0.0, 1.0);

    float camDist = length(waterWorldPos - eyePosWorld);
    float fadeDist = max(uWaterWaveDistanceFade, 1.0);
    float distanceFade = saturate(1.0 - camDist / fadeDist);
    distanceFade = distanceFade * distanceFade * (3.0 - 2.0 * distanceFade);

    if (distanceFade > 0.002)
        flatNormal = ReconstructWaveNormal(waterWorldPos, distanceFade, camDist);

    flatNormal = normalize(lerp(float3(0.0, 0.0, 1.0), flatNormal, saturate(waterMask)));

    return normalize(lerp(normalWS, flatNormal, saturate(waterMask * uWaterSSRFlatNormal)));
}

#endif
