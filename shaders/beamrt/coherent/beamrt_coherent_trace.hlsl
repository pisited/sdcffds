#ifndef BEAMRT_COH_SSR_TRACE_HLSL
#define BEAMRT_COH_SSR_TRACE_HLSL

struct SSRHit
{
    bool  found;
    float2 uv;
    float t;
    float confidence;
    float hitDepth;
    float3 hitNormal;

    float iterations;
    float exitCode;

    float3 levelMix;
    float rejectedCandidates;
    float overhangEvidence;
};

#define BEAMRT_COH_EXIT_INVALID  0.0
#define BEAMRT_COH_EXIT_HIT      1.0
#define BEAMRT_COH_EXIT_SCREEN   2.0
#define BEAMRT_COH_EXIT_DISTANCE 3.0
#define BEAMRT_COH_EXIT_CAP      4.0
#define BEAMRT_COH_EXIT_REJECTED 5.0
#define BEAMRT_COH_EXIT_OCCLUDED 6.0

#define BEAMRT_COH_HIZ_TOP_LEVEL 4
static const float BEAMRT_COH_QUANT_FRACTION = 1.0 / 512.0;
static const float BEAMRT_COH_PROBE_TEXELS = 0.002;

float BrtcCellTexels(int level)
{
    return (float)(1u << (2u * (uint)max(level, 0)));
}

float2 BrtcHiZCellBounds(int2 cell, int level)
{
    float2 bounds;
    if (level <= 0)
    {
        float d = prepassDepthTexTex.Load(int3(clamp(cell, int2(0, 0), (int2)gDepthMaxCoord), 0)).r;
        bounds = float2(d, d);
    }
    else
    {
        int stride = (int)(1u << (2u * (uint)(level - 1)));
        int2 at = cell * stride + int2((level == 4) ? 1 : 0, 0);
        float4 packed = debugTexTex.Load(int3(clamp(at, int2(0, 0), (int2)gDebugMaxCoord), 0));
        bounds = (level == 1) ? packed.rg : ((level == 3) ? packed.aa : packed.bb);
    }
    return bounds;
}

int BrtcTraceIterationBudget()
{
    if (uReferenceTrace > 0.5) return MAX_SSR_STEPS;
    return (int)clamp(lerp(24.0, 128.0, saturate(uTraceQuality)), 12.0, (float)MAX_SSR_STEPS);
}

float BrtcScreenExitS(float2 p0, float2 duv)
{
    float sx = (duv.x > 1e-9) ? (1.0 - p0.x) / duv.x : ((duv.x < -1e-9) ? -p0.x / duv.x : 1e20);
    float sy = (duv.y > 1e-9) ? (1.0 - p0.y) / duv.y : ((duv.y < -1e-9) ? -p0.y / duv.y : 1e20);
    return min(sx, sy);
}

float BrtcRayWorldT(float zA, float zB, float zAtS, float s, float tEnd)
{
    float dz = zB - zA;
    float u = (abs(dz) > 1e-5) ? saturate((zAtS - zA) / dz) : saturate(s);
    return u * tEnd;
}

float BrtcWorldPerTexel(float eyeDepth01, float4 projectionParams)
{
    return eyeDepth01 * projectionParams.y *
           (2.0 * BrtcTanHalfFovY() / max(uThicknessResolutionY, 1.0));
}

float BrtcThicknessAt(float eyeDepth01, float4 projectionParams)
{
    return max(uThicknessTexels * BrtcWorldPerTexel(eyeDepth01, projectionParams), 0.0005);
}

SSRHit BrtcMarchOneRay(
    float3 origin, float3 reflectDir,
    SSRProjectionBasis projectionBasis, float4 projectionParams,
    float2 uv, float jitter, float glossyMarchBias,
    float traceDistance, float3 receiverNormal)
{
    SSRHit result;
    result.found = false;
    result.uv = uv;
    result.t = 0.0;
    result.confidence = 0.0;
    result.hitDepth = 1.0;
    result.hitNormal = float3(0.0, 0.0, 1.0);
    result.iterations = 0.0;
    result.exitCode = BEAMRT_COH_EXIT_INVALID;
    result.levelMix = float3(0.0, 0.0, 0.0);
    result.rejectedCandidates = 0.0;
    result.overhangEvidence = 0.0;

    if (traceDistance <= 0.001)
        return result;

    float z0 = BrtcEyeDepth01(origin, projectionParams);
    if (z0 <= 1e-5)
        return result;

    float dzdt = dot(reflectDir, uCameraForward) / max(projectionParams.y, 1e-4);
    const float zMin = 1e-4;
    float tEnd = traceDistance;
    if ((z0 + dzdt * tEnd) < zMin && dzdt < -1e-9)
        tEnd = max((zMin - z0) / dzdt, 0.0);
    if (tEnd <= 0.001)
        return result;

    float zA, zB, conf0, conf1;
    float2 p0 = ProjectWorldToUVFast(projectionBasis, origin, zA, conf0);
    float2 p1 = ProjectWorldToUVFast(projectionBasis, origin + reflectDir * tEnd, zB, conf1);
    if (zA <= 1e-6 || zB <= 1e-6)
        return result;

    float2 duv = p1 - p0;
    float iz0 = 1.0 / zA;
    float diz = (1.0 / zB) - iz0;

    float2 size0 = gDepthSize;
    float2 originPx = p0 * size0;
    float2 duvPx = duv * size0;
    float duvTexels = max(length(duvPx), 1e-4);
    float probeS = BEAMRT_COH_PROBE_TEXELS / duvTexels;
    float sExit = BrtcScreenExitS(p0, duv);
    float sEnd = min(sExit, 1.0);

    float farPlane = max(projectionParams.y, 1e-4);
    float nativeRatio = 2.0 * BrtcTanHalfFovY() / max(gDepthSize.y, 1.0);
    float slabCapRatio = 16.0 * nativeRatio;
    float slabMinRatio = 0.5 * nativeRatio;
    float thickRatio = slabCapRatio;
    float thickFloor = 0.0005 / farPlane;
    float frontFraction = max(BEAMRT_COH_QUANT_FRACTION, nativeRatio);

    float nativeFootprint = farPlane * 2.0 * BrtcTanHalfFovY() / size0.y;

    float s = min((1.0 + jitter) / duvTexels, 1.0);

    int maxIter = BrtcTraceIterationBudget();
    int maxLevel = clamp((int)(uHiZMaxLevel + 0.5), 0, BEAMRT_COH_HIZ_TOP_LEVEL);
    int level = 0;

    bool  hit = false;
    float hitS = 0.0;
    float hitConfidence = 0.0;
    float2 acceptedUV = uv;
    float acceptedDepth = 1.0;
    float3 acceptedNormal = float3(0.0, 0.0, 1.0);
    bool  capped = true;
    bool  occluded = false;

    int iterations = 0;
    float3 levelMix = float3(0.0, 0.0, 0.0);

    int2  prevLeafCell = int2(-8, -8);
    float prevLeafZ = 0.0;
    float prevLeafSlope = 0.0;
    bool  prevLeafFront = false;
    bool  firstLeaf = true;

    [loop]
    for (int i = 0; i < MAX_SSR_STEPS; i++)
    {
        if (i >= maxIter)
            break;
        if (s >= sEnd)
        {
            capped = false;
            break;
        }
        iterations = i + 1;

        if (level <= 1)      levelMix.x += 1.0;
        else if (level == 2) levelMix.y += 1.0;
        else                 levelMix.z += 1.0;

        float cellTexels = BrtcCellTexels(level);
        int2 cell = (int2)floor((originPx + duvPx * (s + probeS)) / cellTexels);
        float2 edge = (float2(cell) + step(0.0, duvPx)) * cellTexels;
        float bx = (abs(duvPx.x) > 1e-6) ? (edge.x - originPx.x) / duvPx.x : 1e20;
        float by = (abs(duvPx.y) > 1e-6) ? (edge.y - originPx.y) / duvPx.y : 1e20;
        float sB = min(min(bx, by), sEnd);
        if (sB <= s)
            sB = min(s + probeS, sEnd);

        int packedStride = (int)(1u << (2u * (uint)max(level - 1, 0)));
        float3 leafData = prepassDepthTexTex.Load(int3(clamp(cell, int2(0, 0), (int2)gDepthMaxCoord), 0)).rgb;
        float2 leaf = leafData.xz;
        int2 packedAt = cell * packedStride + int2((level == 4) ? 1 : 0, 0);
        float4 packed = debugTexTex.Load(int3(clamp(packedAt, int2(0, 0), (int2)gDebugMaxCoord), 0));
        float2 bounds = (level <= 0) ? leaf.xx
            : ((level == 1) ? packed.rg : ((level == 3) ? packed.aa : packed.bb));
        float zNow = 1.0 / max(iz0 + diz * s, 1e-9);
        float zLeave = 1.0 / max(iz0 + diz * sB, 1e-9);
        float zNear = min(zNow, zLeave);
        float zFar = max(zNow, zLeave);
        float limit = bounds.x * (1.0 - frontFraction);
        bool emptyCell = bounds.x >= 0.999999;

        if (!emptyCell)
        {
            if (level > 0)
            {
                bool skip = zFar < limit;
                if (!skip && level == 1 && bounds.y > 0.0)
                    skip = zNear > bounds.y + max(bounds.y * thickRatio, thickFloor);

                if (!skip)
                {
                    if (diz < 0.0 && zNow < limit)
                        s = clamp((1.0 / limit - iz0) / diz, s, sB);
                    level--;
                    continue;
                }
            }
            else
            {
                float leafSlab = clamp(leafData.y, bounds.x * slabMinRatio, bounds.x * slabCapRatio);
                float slabBack = bounds.x + max(leafSlab, thickFloor);
                int2 leafStep = abs(cell - prevLeafCell);
                bool pierced = zNear > slabBack && (firstLeaf ? (zA <= bounds.x)
                    : (prevLeafFront && max(leafStep.x, leafStep.y) <= 1
                       && abs(bounds.x - prevLeafZ) <= 2.0 * max(max(leafData.y, prevLeafSlope), bounds.x * nativeRatio) + thickFloor));
                firstLeaf = false;
                prevLeafCell = cell;
                prevLeafZ = bounds.x;
                prevLeafSlope = leafData.y;
                prevLeafFront = zNear <= slabBack || pierced;
                if ((zFar >= limit && zNear <= slabBack) || pierced)
                {
                    float sInside = max(sB - probeS, s);
                    float candidateS = (abs(diz) > 1e-12)
                        ? clamp((1.0 / bounds.x - iz0) / diz, s, sInside)
                        : s;
                    float2 candidateUV = clamp(p0 + duv * candidateS,
                        (float2(cell) + BEAMRT_COH_PROBE_TEXELS) / size0,
                        (float2(cell) + 1.0 - BEAMRT_COH_PROBE_TEXELS) / size0);

                    float candidateZ = 1.0 / max(iz0 + diz * candidateS, 1e-9);
                    float candidateT = BrtcRayWorldT(zA, zB, candidateZ, candidateS, tEnd);
                    float3 candidateFromEye = (origin + reflectDir * candidateT - eyePosWorld) * (bounds.x / candidateZ);
                    float candidatePlaneDist = dot(eyePosWorld + candidateFromEye - origin,
                        receiverNormal) + uNormalBias + uRayStartOffset * dot(reflectDir, receiverNormal);
                    bool receiverSurface = abs(candidatePlaneDist) <=
                        clamp(1.5 * bounds.x * nativeFootprint, 0.005, 0.25);
                    if (!receiverSurface)
                    {
                    float fitTolerance = max(2.0 * ((candidateZ >= bounds.x)
                        ? max(leafSlab, thickFloor) : bounds.x * frontFraction), zFar - zNear);
                    float candidateFit = pierced ? 1.0
                        : 1.0 - saturate(abs(candidateZ - bounds.x) / max(fitTolerance, 1e-9));
                    float2 edgePixels = min(candidateUV, 1.0 - candidateUV) * uResolution;
                    float candidateConfidence = max(saturate(min(edgePixels.x, edgePixels.y)), 0.18) *
                        candidateFit * lerp(1.0, candidateFit, glossyMarchBias * 0.65);
                    float3 candidateNormal = (leaf.y > 0.5) ? float3(0.0, 0.0, 1.0)
                        : DecodePrepassNormal(prepassTexTex.Load(BrtcTexelAt(candidateUV, gPrepassSize, gPrepassMaxCoord)));
                    bool frontFacing = dot(candidateNormal, -reflectDir) > 0.0001;
                    bool accept = frontFacing && candidateConfidence > 0.0005 && candidateT > 0.0001;
                    bool blocked = false;
#if BEAMRT_COH_SSR_OVERHANG
                    if (uOverhangFill > 0.5 && !frontFacing && reflectDir.z > 0.10
                        && receiverNormal.z > 0.65 && candidateNormal.z > 0.65
                        && candidateT > 0.5 && candidateConfidence > 0.05)
                    {
                        float3 receiverToCandidate = (eyePosWorld - origin) + candidateFromEye;
                        float raised = dot(receiverToCandidate, receiverNormal);
                        float opaque = 1.0 - step(0.5, leaf.y);
                        float evidence = smoothstep(0.5, 1.5, raised) * opaque * candidateConfidence *
                            smoothstep(0.65, 0.9, candidateNormal.z);
                        result.overhangEvidence = max(result.overhangEvidence, evidence);
                        blocked = evidence >= 0.5;
                    }
#endif
                    if (accept || blocked)
                    {
                        hit = accept;
                        occluded = blocked;
                        hitS = candidateS;
                        hitConfidence = candidateConfidence;
                        acceptedUV = candidateUV;
                        acceptedDepth = bounds.x;
                        acceptedNormal = candidateNormal;
                        capped = false;
                        break;
                    }
                    }
                    result.rejectedCandidates += 1.0;
                }
            }
        }

        int nextLevel = level;
        if (level < maxLevel)
        {
            if (diz > 0.0)
            {
                nextLevel = level + 1;
            }
            else
            {
                int2 parentNew = (int2)floor((originPx + duvPx * (sB + probeS)) / BrtcCellTexels(level + 1));
                int2 parentOld = (int2)floor(float2(cell) * 0.25);
                if (any(parentNew != parentOld))
                    nextLevel = level + 1;
            }
        }
        s = sB;
        level = nextLevel;
    }

    result.iterations = (float)iterations;
    result.levelMix = levelMix / max((float)iterations, 1.0);

    if (occluded)
    {
        float zOcc = 1.0 / max(iz0 + diz * hitS, 1e-9);
        result.uv = clamp(acceptedUV, BEAMRT_COH_UV_CLAMP_LO, BEAMRT_COH_UV_CLAMP_HI);
        result.t = BrtcRayWorldT(zA, zB, zOcc, hitS, tEnd);
        result.exitCode = BEAMRT_COH_EXIT_OCCLUDED;
        return result;
    }
    if (!hit)
    {
        result.exitCode = capped ? BEAMRT_COH_EXIT_CAP
                        : ((sExit < 1.0) ? BEAMRT_COH_EXIT_SCREEN : BEAMRT_COH_EXIT_DISTANCE);
        return result;
    }

    float zHit = 1.0 / max(iz0 + diz * hitS, 1e-9);
    float tHit = BrtcRayWorldT(zA, zB, zHit, hitS, tEnd);
    if (tHit <= 0.0001)
    {
        result.exitCode = BEAMRT_COH_EXIT_REJECTED;
        return result;
    }

    float2 hitUV = clamp(acceptedUV, BEAMRT_COH_UV_CLAMP_LO, BEAMRT_COH_UV_CLAMP_HI);

    float confidence = hitConfidence;

    if (confidence <= 0.0005)
    {
        result.exitCode = BEAMRT_COH_EXIT_REJECTED;
        return result;
    }

    result.found = true;
    result.uv = hitUV;
    result.t = tHit;
    result.confidence = confidence;
    result.hitDepth = acceptedDepth;
    result.hitNormal = acceptedNormal;
    result.exitCode = BEAMRT_COH_EXIT_HIT;
    return result;
}

float4 BrtcDebugCellFootprint(float2 uv)
{
    int level = clamp((int)(uHiZMaxLevel + 0.5), 1, BEAMRT_COH_HIZ_TOP_LEVEL);
    int2 cell = (int2)floor(uv * gDepthSize / BrtcCellTexels(level));
    float checker = (((cell.x + cell.y) & 1) != 0) ? 1.0 : 0.55;
    float brightness = pow(saturate(BrtcHiZCellBounds(cell, level).x), 0.25);
    float3 tint = float3(frac(cell.x * 0.61803399), frac(cell.y * 0.38196601), 1.0);
    return float4(lerp(0.35, 1.0, tint) * brightness * checker, 1.0);
}

float4 BrtcTraceReceiver(PFXVertToPix IN, float2 uv, float4 projectionParams)
{
    float4 combinedDepth = LoadCombinedDepthPoint(uv);
    float eyeDepth01 = saturate(combinedDepth.r);
    float realDepth = eyeDepth01 * projectionParams.y;
    bool invalidCombinedDepth = eyeDepth01 <= 0.000001 || eyeDepth01 >= 0.999999;

    if (invalidCombinedDepth)
        return float4(0.0, 0.0, 0.0, 0.0);

    if (uProjectionValid < 0.5)
        return float4(0.0, 0.0, 0.0, 0.0);

    float4 prepass = LoadPrepass(uv);
    float3 normalWS = DecodePrepassNormal(prepass);
    float roughness = LoadRoughness(prepass);

    if (uTraceClass > 0.5)
    {
        float gloss = BrtcAdaptiveGloss(roughness, normalWS, combinedDepth.b > 0.5);
        if ((uTraceClass < 1.5 && gloss <= 0.0) || (uTraceClass > 1.5 && gloss >= 1.0))
            return float4(0.0, 0.0, 0.0, BEAMRT_COH_NOT_TRACED);
    }

    float3 sceneWorldPos = ReconstructWorldPosition(IN, eyeDepth01);

    float pReflect, pDark;
    float puddleMask = BrtcApplyPuddle(sceneWorldPos, normalWS, roughness, pReflect, pDark);

    float3 viewToSurfacePre = normalize(sceneWorldPos - eyePosWorld);
    float3 reflectDirPre = normalize(reflect(viewToSurfacePre, normalWS));
    float effectiveRoughnessPre;
    float roughMaskPre = RoughnessMask(roughness, normalWS, effectiveRoughnessPre);
    float fresnelMaskPre = FresnelMask(viewToSurfacePre, normalWS);
    float facingMaskPre = FacingFade(reflectDirPre, normalWS);
    float preBaseMask = roughMaskPre * fresnelMaskPre * facingMaskPre;

    bool waterMayContribute = combinedDepth.b > 0.0001;

    if (preBaseMask <= 0.0001 && !waterMayContribute)
        return float4(0.0, 0.0, 0.0, 0.0);

    WaterSurfaceInfo waterInfo = EmptyWaterSurfaceInfo(eyeDepth01, sceneWorldPos);
    float waterMask = 0.0;

    if (waterMayContribute)
    {
        waterInfo = DecodeCombinedWaterSurface(IN, combinedDepth);
        waterMask = waterInfo.mask;
    }

    float3 worldPos = sceneWorldPos;
    float3 viewToSurface = viewToSurfacePre;
    float3 reflectDir = reflectDirPre;
    float effectiveRoughness = effectiveRoughnessPre;
    float roughMask = roughMaskPre;
    float fresnelMask = fresnelMaskPre;
    float facingMask = facingMaskPre;
    float baseMask = preBaseMask;

    if (waterMask > 0.0001)
    {
        worldPos = lerp(sceneWorldPos, waterInfo.worldPos, waterMask);
        normalWS = ApplyWaterNormal(normalWS, waterMask, worldPos);
        roughness = lerp(roughness, max(uWaterSSRRoughness, 0.004), waterMask);
        viewToSurface = normalize(worldPos - eyePosWorld);
        reflectDir = normalize(reflect(viewToSurface, normalWS));

        roughMask = RoughnessMask(roughness, normalWS, effectiveRoughness);
        fresnelMask = FresnelMask(viewToSurface, normalWS);
        facingMask = FacingFade(reflectDir, normalWS);
        baseMask = roughMask * fresnelMask * facingMask;

        float waterBoostMask = waterMask * saturate(uWaterSSRStrength) * waterInfo.angleMask * max(fresnelMask, 0.35) * max(facingMask, 0.45);
        baseMask = saturate(max(baseMask, waterBoostMask));
    }

    puddleMask *= 1.0 - saturate(waterMask);

    if (puddleMask > 0.001)
    {
        float puddleFresnel = BrtcPuddleFresnelMask(viewToSurface, normalWS);
        float puddleResponse = roughMask * saturate(uPuddleReflectivity) * pReflect *
                               puddleFresnel * facingMask;
        baseMask = saturate(lerp(baseMask, puddleResponse, saturate(puddleMask)));
    }

    if (baseMask <= 0.0001)
        return float4(0.0, 0.0, 0.0, 0.0);

    float2 jitterPixel = uv * uResolution;
    float jitter = InterleavedGradientNoise(jitterPixel + uFrame * 5.588238 * saturate(uJitterTemporalRate));
    if (uScreenJitter > 0.001)
        jitter = frac(jitter + (RayPhaseJitter(jitterPixel, uFrame, uScreenJitter) - 0.5));

    SSRProjectionBasis projectionBasis = BuildProjectionBasis(IN, uv, worldPos);

    float4 environmentFill = float4(0.0, 0.0, 0.0, 0.0);
    if (uSkyBeforeTemporal > 0.5 && max(uSkyReflectionFallback, uWaterSkyFallback) > 0.0001)
    {
        float3 skyDir = normalize(reflect(viewToSurface, normalWS));
        float screenEnvironment;
        float3 environmentColor = BrtcEnvironmentColor(skyDir, BrtcHiZ0Exposure(combinedDepth), effectiveRoughness,
            projectionBasis.screenCenter, float2(1.0, 1.0), screenEnvironment);
        float upwardRay = BrtcEnvironmentGate(smoothstep(0.02, 0.24, skyDir.z), screenEnvironment);
        float upwardSurface = BrtcEnvironmentGate(smoothstep(0.05, 0.45, normalWS.z), screenEnvironment);
        float skyStrength = saturate(uSkyReflectionFallback);
        float waterSkyStrength = saturate(uWaterSkyFallback);
        float ordinaryMask = (1.0 - saturate(waterMask)) * (1.0 - saturate(puddleMask));

        float glossySky = roughMask * fresnelMask * facingMask * upwardRay *
                          upwardSurface * ordinaryMask * skyStrength *
                          BrtcEnvironmentOcclusion(BrtcHiZ0AO(combinedDepth),
                              dot(normalWS, -viewToSurface), effectiveRoughness);
        float waterSky = saturate(waterMask) * saturate(uWaterSSRStrength) *
                         waterInfo.angleMask * max(fresnelMask, 0.35) *
                         max(facingMask, 0.45) * upwardRay * waterSkyStrength;
        environmentFill = float4(environmentColor, saturate(max(glossySky, waterSky)));
    }

    float glossyMarchBias = 1.0 - smoothstep(0.05, 0.32, effectiveRoughness);

    float traceDistance = lerp(uMaxDistance, max(uWaterFarTraceDistance, 1.0), saturate(waterMask));

    float3 V = normalize(-viewToSurface);
    float NoV = saturate(dot(normalWS, V));
    float2 pixelCoord = uv * uResolution;

    int rayCount = 1;
    if (uStochasticSSR > 0.5)
        rayCount = clamp((int)(uStochasticRayCount + 0.5), 1, BEAMRT_COH_MAX_STOCHASTIC_RAYS);

    float3 sampleColor[BEAMRT_COH_MAX_STOCHASTIC_RAYS];
    float  sampleAlpha[BEAMRT_COH_MAX_STOCHASTIC_RAYS];
    [unroll] for (int clearSample = 0; clearSample < BEAMRT_COH_MAX_STOCHASTIC_RAYS; ++clearSample)
    {
        sampleColor[clearSample] = 0;
        sampleAlpha[clearSample] = 0;
    }
    int    hitCount = 0;
    float hitDistanceSum = 0.0;
    float hitDistanceWeight = 0.0;
    float overhangCoverage = 0.0;

    SSRHit debugHit;
    debugHit.found = false;
    debugHit.uv = uv;
    debugHit.t = 0.0;
    debugHit.confidence = 0.0;
    debugHit.hitDepth = 1.0;
    debugHit.hitNormal = float3(0.0, 0.0, 1.0);
    debugHit.iterations = 0.0;
    debugHit.exitCode = 0.0;
    debugHit.levelMix = float3(0.0, 0.0, 0.0);
    debugHit.rejectedCandidates = 0.0;
    debugHit.overhangEvidence = 0.0;

    BEAMRT_COH_RAY_LOOP
    for (int r = 0; r < BEAMRT_COH_MAX_STOCHASTIC_RAYS; r++)
    {
        if (r >= rayCount)
            break;

        float3 rayDir = BrtcSampleReflectionRayIndexed(pixelCoord, normalWS, V, effectiveRoughness, (float)r, (float)rayCount);

        float rayMask = baseMask * FacingFade(rayDir, normalWS);
        if (rayMask <= 0.0001)
            continue;

        float rayJitter = frac(jitter + (float)r * 0.618033989);

        float3 origin = worldPos + normalWS * uNormalBias + rayDir * uRayStartOffset;
        SSRHit hit = BrtcMarchOneRay(origin, rayDir, projectionBasis, projectionParams,
                                    uv, rayJitter, glossyMarchBias,
                                    traceDistance, normalWS);
        if (r == 0)
            debugHit = hit;
        if (!hit.found)
        {
            if (uOverhangFill > 0.5 && hit.overhangEvidence > 0.0001)
            {
                float3 receiverColor = max(tex2Dlod(sourceTex, float4(uv, 0.0, 0.0)).rgb, 0.0);
                float3 topColor = (hit.exitCode == BEAMRT_COH_EXIT_OCCLUDED)
                    ? max(tex2Dlod(sourceTex, float4(hit.uv, 0.0, 0.0)).rgb, 0.0) : receiverColor;
                sampleColor[hitCount] = max(max(uOverhangBounce, 0.0) * sqrt(topColor * receiverColor),
                                            BrtcDisplayAuthored(max(uOverhangBrightness, 0.0).xxx));
                sampleAlpha[hitCount] = saturate(rayMask * hit.overhangEvidence *
                    lerp(1.0, max(uWaterSSRStrength, 0.0) * waterInfo.angleMask, waterMask));
                overhangCoverage += hit.overhangEvidence;
                hitCount++;
            }
            continue;
        }

        float3 hitNormal = hit.hitNormal;
        float backfaceMask = smoothstep(-0.2, max(uBackfaceFade, 0.001), dot(hitNormal, -rayDir));

        float edgeMask = EdgeFade(hit.uv);
        float distanceMask = DistanceFade(hit.t);
        float skyMask = 1.0 - smoothstep(uSkyFadeStart, uSkyFadeEnd, saturate(hit.hitDepth));

        float rayAlpha = rayMask * hit.confidence * backfaceMask * edgeMask * distanceMask * skyMask;
        rayAlpha = saturate(rayAlpha * lerp(1.0, max(uWaterSSRStrength, 0.0) * waterInfo.angleMask, waterMask));
        if (rayAlpha <= 0.0001)
            continue;

        sampleColor[hitCount] = BrtcSamplePrefilteredScene(hit.uv, effectiveRoughness, hit.t, NoV);
        sampleAlpha[hitCount] = rayAlpha;
        hitDistanceSum += hit.t * rayAlpha;
        hitDistanceWeight += rayAlpha;
        hitCount++;
    }

    float4 traceResult = float4(0.0, 0.0, 0.0, 0.0);
    if (hitCount > 0)
    {
        float sumLuma = 0.0;
        BEAMRT_COH_RAY_LOOP
        for (int a = 0; a < BEAMRT_COH_MAX_STOCHASTIC_RAYS; a++)
        {
            if (a >= hitCount) break;
            sumLuma += BrtcLuma(sampleColor[a]);
        }

        float3 sumColor = float3(0.0, 0.0, 0.0);
        float sumWeight = 0.0;
        float sumAlpha = 0.0;
        BEAMRT_COH_RAY_LOOP
        for (int b = 0; b < BEAMRT_COH_MAX_STOCHASTIC_RAYS; b++)
        {
            if (b >= hitCount) break;
            float sampleLuma = BrtcLuma(sampleColor[b]);
            float othersLuma = (hitCount > 1)
                ? (sumLuma - sampleLuma) / (float)max(hitCount - 1, 1)
                : sampleLuma;
            float w = BrtcFireflyWeight(sampleColor[b], othersLuma) * max(sampleAlpha[b], 1e-4);
            sumColor += sampleColor[b] * w;
            sumWeight += w;
            sumAlpha += sampleAlpha[b];
        }

        float3 avgColor = (sumWeight > 1e-4) ? sumColor / sumWeight : sampleColor[0];
        float avgAlpha = sumAlpha / (float)rayCount;
        traceResult = float4(avgColor, avgAlpha);
    }

    int dbgView = (int)uDebugView;
    if (dbgView >= 50 && dbgView <= 53)
    {
        if (dbgView == 52) return float4(BrtcStochasticSequence(pixelCoord, 0, 1), 0, 1);
        if (!debugHit.found) return float4(0, 0, 0, 1);
        if (dbgView == 50) return float4(debugHit.uv, 0, 1);
        if (dbgView == 51) return float4(saturate(log2(1.0 + debugHit.t) / 12.0).xxx, 1);
        return float4(debugHit.confidence.xxx, 1);
    }
    if (dbgView == 38)
        return float4((overhangCoverage / (float)rayCount).xxx, 1.0);
    if (dbgView == 31 || dbgView == 32 || dbgView == 43)
    {
        if (dbgView == 31)
        {
            float n = saturate(debugHit.iterations / max((float)BrtcTraceIterationBudget(), 1.0));
            return float4(n, 1.0 - n, 0.0, 1.0);
        }

        if (dbgView == 43)
        {
            return float4(debugHit.levelMix, 1.0);
        }

        int e = (int)(debugHit.exitCode + 0.5);
        float3 c = float3(0.0, 0.0, 0.0);
        if (e == 1)      c = float3(0.0, 1.0, 0.0);
        else if (e == 2) c = float3(1.0, 0.0, 0.0);
        else if (e == 3) c = float3(1.0, 0.0, 1.0);
        else if (e == 4) c = float3(0.0, 0.4, 1.0);
        else if (e == 5) c = float3(1.0, 1.0, 0.0);
        else if (e == 6) c = float3(0.0, 1.0, 1.0);
        return float4(c, 1.0);
    }

    float hitAlpha = traceResult.a;
    traceResult = BrtcBlendEnvironmentFill(traceResult, environmentFill.a, environmentFill.rgb);

    float hitMetres = (hitDistanceWeight > 1e-4 && (uUnifiedTemporal > 0.5 || hitAlpha >= 0.5 * traceResult.a))
        ? hitDistanceSum / hitDistanceWeight : 1e6;
    traceResult.rgb = BrtcEmbedHitCode(BrtcHdrCompress(traceResult.rgb), BrtcEncodeHitDistanceCode(hitMetres));
    return traceResult;
}

float4 TraceSSR(PFXVertToPix IN, float2 uv, float4 projectionParams)
{
    float3 du = ddx(IN.wsEyeRay) / max(abs(ddx(uv.x)), 1e-8);
    float3 dv = ddy(IN.wsEyeRay) / max(abs(ddy(uv.y)), 1e-8);
    float2 primaryUV = clamp(uv + uTraceJitterUV, BEAMRT_COH_UV_CLAMP_LO, BEAMRT_COH_UV_CLAMP_HI);
    float2 secondaryOffset = -uTraceJitterUV;
    bool stationary = all(abs(secondaryOffset * uResolution) < 0.05);
    if (stationary)secondaryOffset = float2(0.25,0.25)/uResolution;
    float2 secondaryUV = clamp(uv + secondaryOffset, BEAMRT_COH_UV_CLAMP_LO, BEAMRT_COH_UV_CLAMP_HI);
    int count = 1;
    if (uTraceFootprintAA > 0.5 && uUnifiedTemporal < 0.5 &&
        all(uResolution < gDepthSize * 0.51) && uDebugView == 0.0)
    {
        float4 d0 = LoadCombinedDepthPoint(primaryUV);
        float4 p0 = LoadPrepass(primaryUV);
        float rough0 = LoadRoughness(p0);
        if (rough0 < 0.12 && d0.r > 0.000001 && d0.r < 0.999999 && d0.b < 0.0001)
        {
            float4 d1 = LoadCombinedDepthPoint(secondaryUV);
            float4 p1 = LoadPrepass(secondaryUV);
            float3 n0 = DecodePrepassNormal(p0), n1 = DecodePrepassNormal(p1);
            float3 ray0 = IN.wsEyeRay + du * (primaryUV.x-uv.x) + dv * (primaryUV.y-uv.y);
            float3 ray1 = IN.wsEyeRay + du * (secondaryUV.x-uv.x) + dv * (secondaryUV.y-uv.y);
            float3 delta = (ray1*d1.r-ray0*d0.r)*projectionParams.y;
            float footprint = max(length(du/uResolution.x),length(dv/uResolution.y))*d0.r*projectionParams.y;
            float tolerance = max(0.01, footprint*0.1);
            if (d1.r > 0.000001 && d1.r < 0.999999 && d1.b < 0.0001 &&
                abs(LoadRoughness(p1)-rough0) < 0.04 && dot(n0,n1) > 0.95 &&
                max(abs(dot(delta,n0)),abs(dot(delta,n1))) < tolerance)
            {
                count = 2;
                if(stationary)
                {
                    float2 oppositeUV=clamp(uv-secondaryOffset,BEAMRT_COH_UV_CLAMP_LO,BEAMRT_COH_UV_CLAMP_HI);
                    float4 d2=LoadCombinedDepthPoint(oppositeUV);
                    float4 p2=LoadPrepass(oppositeUV);
                    float3 n2=DecodePrepassNormal(p2);
                    float3 ray2=IN.wsEyeRay+du*(oppositeUV.x-uv.x)+dv*(oppositeUV.y-uv.y);
                    float3 delta2=(ray2*d2.r-ray0*d0.r)*projectionParams.y;
                    if(d2.r>0.000001 && d2.r<0.999999 && d2.b<0.0001 &&
                       abs(LoadRoughness(p2)-rough0)<0.04 && dot(n0,n2)>0.95 &&
                       max(abs(dot(delta2,n0)),abs(dot(delta2,n2)))<tolerance)
                        count=3;
                    else count=1;
                }
            }
        }
    }
    float4 first = 0.0, second = 0.0, third = 0.0;
    [loop] for (int s=0;s<count;s++)
    {
        float2 sampleUV = s == 0 ? primaryUV : (s==1?secondaryUV:
            clamp(uv-secondaryOffset,BEAMRT_COH_UV_CLAMP_LO,BEAMRT_COH_UV_CLAMP_HI));
        PFXVertToPix sampleIN = IN;
        sampleIN.wsEyeRay += du*(sampleUV.x-uv.x)+dv*(sampleUV.y-uv.y);
        float4 sample = BrtcTraceReceiver(sampleIN,sampleUV,projectionParams);
        if(s==0)
        {
            first=sample;
            if(first.a<0.0 || (first.a>0.0001 && BrtcExtractHitCode(first.rgb)<62.5))return first;
        }
        else if(s==1)second=sample;else third=sample;
    }
    if(count==1 || first.a<0.0 || second.a<0.0 || (count==3 && third.a<0.0))return first;
    float secondFiniteWeight=BrtcExtractHitCode(second.rgb)<62.5?second.a:0.0;
    if(count==3)
    {
        float extraAlpha=second.a+third.a;
        float3 extraRGB=extraAlpha>1e-5?(second.rgb*second.a+third.rgb*third.a)/extraAlpha:0.0;
        float extraCode=BrtcExtractHitCode(second.rgb)<62.5?BrtcExtractHitCode(second.rgb):BrtcExtractHitCode(third.rgb);
        secondFiniteWeight=(secondFiniteWeight+(BrtcExtractHitCode(third.rgb)<62.5?third.a:0.0))*.5;
        second=float4(BrtcEmbedHitCode(extraRGB,extraCode),extraAlpha*.5);
    }
    float a = first.a*.75+second.a*.25;
    float3 rgb = a > 1e-5 ? (first.rgb*first.a*.75+second.rgb*second.a*.25)/a : 0.0;
    float c0=BrtcExtractHitCode(first.rgb), c1=BrtcExtractHitCode(second.rgb);
    float finiteWeight=(c0<62.5?first.a*.75:0.0)+secondFiniteWeight*.25;
    float code=c0<62.5?c0:c1;
    if(finiteWeight<=1e-5 || (uUnifiedTemporal<0.5 && finiteWeight<0.5*a))
        code=BEAMRT_COH_HIT_DISTANCE_INFINITE;
    return float4(BrtcEmbedHitCode(rgb,code),a);
}

#endif
