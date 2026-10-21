#ifndef BEAMRT_COH_SSR_TEMPORAL_HLSL
#define BEAMRT_COH_SSR_TEMPORAL_HLSL

struct BrtcPrevCamera
{
    float3 invRow0;
    float3 invRow1;
    float3 invRow2;
    float3 eye;
    bool   valid;
};

BrtcPrevCamera BrtcLoadPreviousCameraFrom(Texture2D cameraTex, float4 projectionParams)
{
    BrtcPrevCamera cam;
    float4 r00 = cameraTex.Load(int3(0, 0, 0));
    float4 r10 = cameraTex.Load(int3(1, 0, 0));
    float4 r01 = cameraTex.Load(int3(0, 1, 0));
    float4 r11 = cameraTex.Load(int3(1, 1, 0));
    cam.invRow0 = r00.rgb;
    cam.invRow1 = r10.rgb;
    cam.invRow2 = r01.rgb;
    cam.eye = float3(r00.a, r10.a, r01.a);
    cam.valid = r11.a > 0.5;
#if defined(__SHADER_TARGET_MAJOR) && __SHADER_TARGET_MAJOR >= 6
    cam.invRow0 = WaveReadLaneFirst(cam.invRow0);
    cam.invRow1 = WaveReadLaneFirst(cam.invRow1);
    cam.invRow2 = WaveReadLaneFirst(cam.invRow2);
    cam.eye = WaveReadLaneFirst(cam.eye);
    cam.valid = WaveReadLaneFirst(cam.valid);
#endif
    return cam;
}

BrtcPrevCamera BrtcEmptyPreviousCamera()
{
    BrtcPrevCamera cam;
    cam.invRow0 = float3(1.0, 0.0, 0.0);
    cam.invRow1 = float3(0.0, 1.0, 0.0);
    cam.invRow2 = float3(0.0, 0.0, 1.0);
    cam.eye = float3(0.0, 0.0, 0.0);
    cam.valid = false;
    return cam;
}

void BrtcPrevCameraRays(BrtcPrevCamera cam, out float3 rayOrigin, out float3 rayDU, out float3 rayDV)
{
    float3 c0 = cross(cam.invRow1, cam.invRow2);
    float det = dot(cam.invRow0, c0);
    float invDet = abs(det) > 1e-30 ? 1.0 / det : 0.0;
    rayDU = c0 * invDet;
    rayDV = cross(cam.invRow2, cam.invRow0) * invDet;
    rayOrigin = cross(cam.invRow0, cam.invRow1) * invDet;
}

bool BrtcSolvePreviousUV(BrtcPrevCamera cam, float3 v3,
                        out float2 previousUV, out float previousDepth)
{
    float a = dot(cam.invRow0, v3);
    float b = dot(cam.invRow1, v3);
    float c = dot(cam.invRow2, v3);
    bool solved = c > 1e-6;
    previousDepth = solved ? c : 0.0;
    previousUV = solved ? float2(a, b) / c : float2(-1.0, -1.0);
    return solved;
}

bool BrtcProjectPreviousUVExact(BrtcPrevCamera cam, float3 worldPos,
                               out float2 previousUV, out float previousDepth)
{
    if (!BrtcSolvePreviousUV(cam, worldPos - cam.eye, previousUV, previousDepth))
        return false;
    return all(previousUV > BEAMRT_COH_UV_CLAMP_LO) && all(previousUV < BEAMRT_COH_UV_CLAMP_HI);
}

bool BrtcProjectPreviousUV(float3 worldPos, float2 currentUV, out float2 previousUV, out float previousDepth)
{
    if (uTemporalHistoryValid < 0.5)
    {
        previousUV = float2(-1.0, -1.0);
        previousDepth = 0.0;
        return false;
    }

    if (uTemporalReprojectionValid < 0.5)
    {
        previousUV = currentUV;
        previousDepth = 1.0;
        return true;
    }

    float3 toPoint = worldPos - uPrevEyePosWorld;
    previousDepth = dot(toPoint, uPrevCameraForward);
    if (previousDepth <= 1e-4 || uPrevTanHalfFovX <= 1e-4 || uPrevTanHalfFovY <= 1e-4)
    {
        previousUV = float2(-1.0, -1.0);
        return false;
    }

    float ndcX = dot(toPoint, uPrevCameraRight) / (previousDepth * uPrevTanHalfFovX);
    float ndcY = dot(toPoint, uPrevCameraUp) / (previousDepth * uPrevTanHalfFovY);
    previousUV = float2(0.5 + ndcX * 0.5, 0.5 - ndcY * 0.5);
    return all(previousUV > BEAMRT_COH_UV_CLAMP_LO) && all(previousUV < BEAMRT_COH_UV_CLAMP_HI);
}

float4 BrtcSampleCatmullRomAA(
    Texture2D historyTex, SamplerState historySampler, float2 uv)
{
    float2 texSize = gAuxSize;

    float2 samplePos = uv * texSize;
    float2 texPos1 = floor(samplePos - 0.5) + 0.5;
    float2 f = samplePos - texPos1;

    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);

    float2 w12 = w1 + w2;
    float2 offset12 = w2 / max(w12, float2(1e-5, 1e-5));

    float2 texPos0 = (texPos1 - 1.0) / texSize;
    float2 texPos3 = (texPos1 + 2.0) / texSize;
    float2 texPos12 = (texPos1 + offset12) / texSize;

    float4 result =
        historyTex.SampleLevel(historySampler, float2(texPos0.x, texPos0.y), 0) * (w0.x * w0.y) +
        historyTex.SampleLevel(historySampler, float2(texPos12.x, texPos0.y), 0) * (w12.x * w0.y) +
        historyTex.SampleLevel(historySampler, float2(texPos3.x, texPos0.y), 0) * (w3.x * w0.y) +
        historyTex.SampleLevel(historySampler, float2(texPos0.x, texPos12.y), 0) * (w0.x * w12.y) +
        historyTex.SampleLevel(historySampler, float2(texPos12.x, texPos12.y), 0) * (w12.x * w12.y) +
        historyTex.SampleLevel(historySampler, float2(texPos3.x, texPos12.y), 0) * (w3.x * w12.y) +
        historyTex.SampleLevel(historySampler, float2(texPos0.x, texPos3.y), 0) * (w0.x * w3.y) +
        historyTex.SampleLevel(historySampler, float2(texPos12.x, texPos3.y), 0) * (w12.x * w3.y) +
        historyTex.SampleLevel(historySampler, float2(texPos3.x, texPos3.y), 0) * (w3.x * w3.y);

    int2 maxI  = (int2)gAuxMaxCoord;
    int2 baseI = clamp(int2(floor(samplePos - 0.5)), int2(0, 0), maxI);
    int2 base1 = min(baseI + int2(1, 1), maxI);
    float4 t00 = historyTex.Load(int3(baseI.x, baseI.y, 0));
    float4 t10 = historyTex.Load(int3(base1.x, baseI.y, 0));
    float4 t01 = historyTex.Load(int3(baseI.x, base1.y, 0));
    float4 t11 = historyTex.Load(int3(base1.x, base1.y, 0));
    float4 lo = min(min(t00, t10), min(t01, t11));
    float4 hi = max(max(t00, t10), max(t01, t11));

    return clamp(result, lo, hi);
}

float4 BrtcSampleCatmullRomOptimized(
    Texture2D historyTex, SamplerState historySampler, float2 uv)
{
    float2 textureSize = gAuxSize;

    float2 samplePosition = uv * textureSize;
    float2 texelPosition1 = floor(samplePosition - 0.5) + 0.5;
    float2 f = samplePosition - texelPosition1;

    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 offset12 = w2 / max(w12, float2(1e-5, 1e-5));

    float2 texelPosition0 = (texelPosition1 - 1.0) / textureSize;
    float2 texelPosition3 = (texelPosition1 + 2.0) / textureSize;
    float2 texelPosition12 = (texelPosition1 + offset12) / textureSize;

    float centerWeight = w12.x * w12.y;
    float leftWeight = w0.x * w12.y;
    float rightWeight = w3.x * w12.y;
    float topWeight = w12.x * w0.y;
    float bottomWeight = w12.x * w3.y;
    float totalWeight = centerWeight + leftWeight + rightWeight +
                        topWeight + bottomWeight;

    float4 result =
        historyTex.SampleLevel(historySampler, texelPosition12, 0) *
            centerWeight +
        historyTex.SampleLevel(
            historySampler,
            float2(texelPosition0.x, texelPosition12.y), 0) *
            leftWeight +
        historyTex.SampleLevel(
            historySampler,
            float2(texelPosition3.x, texelPosition12.y), 0) *
            rightWeight +
        historyTex.SampleLevel(
            historySampler,
            float2(texelPosition12.x, texelPosition0.y), 0) *
            topWeight +
        historyTex.SampleLevel(
            historySampler,
            float2(texelPosition12.x, texelPosition3.y), 0) *
            bottomWeight;
    result /= max(totalWeight, 1e-4);
    return float4(max(result.rgb, 0.0), saturate(result.a));
}

float4 BrtcMixReflectionSignal(float4 a, float4 b, float w)
{
    float alpha = lerp(saturate(a.a), saturate(b.a), w);
    float3 energy = lerp(a.rgb * saturate(a.a), b.rgb * saturate(b.a), w);
    return float4(alpha > 1e-5 ? energy / alpha : float3(0.0, 0.0, 0.0), alpha);
}

float2 BrtcEncodeHistoryNormal(float3 n)
{
    n /= max(abs(n.x) + abs(n.y) + abs(n.z), 1e-6);
    float2 p = n.xy;
    if (n.z < 0.0) p = (1.0 - abs(p.yx)) * float2(p.x >= 0 ? 1 : -1, p.y >= 0 ? 1 : -1);
    return p;
}
float3 BrtcDecodeHistoryNormal(float2 p)
{
    float3 n = float3(p, 1.0 - abs(p.x) - abs(p.y));
    float t = saturate(-n.z);
    n.xy += float2(n.x >= 0 ? -t : t, n.y >= 0 ? -t : t);
    return normalize(n);
}
float2 BrtcCurrentUV(float2 uv)
{
    if (uReuseGuides > 0.5)
        return float2(min(uv.x, (gSourceSize.x - 0.5) / gSourceSize.x) * 0.5, uv.y);
    return uv;
}

float4 BrtcSampleCurrent(float2 uv)
{
    return tex2Dlod(sourceTex, float4(BrtcCurrentUV(uv), 0.0, 0.0));
}

float4 BrtcWriteReuseGuide(int2 texel)
{
    float2 sampleUV = (float2(texel) + 0.5) / gSourceSize;
    float2 guideUV = clamp(sampleUV + uTraceJitterUV, BEAMRT_COH_UV_CLAMP_LO, BEAMRT_COH_UV_CLAMP_HI);
    float4 d = LoadCombinedDepthPoint(guideUV);
    float q = floor(saturate(d.b) * 4.0 + 0.5);
    if (d.b > 0.5)
        return float4(d.r, 0.0, 0.0, 8.0 + max(q, 2.0));
    float3 n = DecodePrepassNormal(prepassTexTex.Load(BrtcTexelAt(guideUV, gPrepassSize, gPrepassMaxCoord)));
    return float4(d.r, n.x, n.y, n.z + 4.0 * min(q, 2.0));
}

float2 BrtcUnpackReuseGuide(float4 g, out float3 n)
{
    float w = g.w;
    bool water = w > 9.5;
    float q = water ? w - 8.0 : floor(w * 0.25 + 0.5);
    n = water ? float3(0.0, 0.0, 1.0) : float3(g.y, g.z, w - 4.0 * q);
    return float2(g.x, q * 0.25);
}

float4 BrtcReuseStochastic(float2 currentUV, float4 center, float4 projectionParams, float2 receiverGuideUV,
    out float hitCode)
{
    hitCode = center.a > 1e-5 ? BrtcExtractHitCode(center.rgb) : BEAMRT_COH_HIT_DISTANCE_INFINITE;
    float bestHitWeight = hitCode < 62.5 ? 2.0 * center.a : -1.0;
    float reuse = saturate(uStochasticReuse) * step(0.5, uStochasticSSR);
    if (reuse <= 0.0001) return center;
    float2 centerUV = (floor(currentUV * gSourceSize) + 0.5) / gSourceSize;
    float2 centerGuideUV = clamp(receiverGuideUV, BEAMRT_COH_UV_CLAMP_LO, BEAMRT_COH_UV_CLAMP_HI);
    float4 d = LoadCombinedDepthPoint(centerGuideUV);
    if (d.r <= 0.000001 || d.r >= 0.999999) return center;
    float4 centerPrepass = prepassTexTex.Load(BrtcTexelAt(centerGuideUV, gPrepassSize, gPrepassMaxCoord));
    float diagonalWeight = BrtcRoughStabilityWeight(LoadRoughness(centerPrepass), d.b) * 0.5;
    float3 n = d.b > 0.5 ? float3(0,0,1) : DecodePrepassNormal(centerPrepass);
    float3 centerRay = BrtcScreenRay(centerGuideUV);
    float3 centerPos = centerRay * d.r * projectionParams.y;
    float footprint = max(d.r * projectionParams.y * 2.0 * BrtcTanHalfFovY() / gSourceSize.y, 0.01);
    float4 sum = float4(center.rgb * center.a, center.a) * 2.0;
    float weightSum = 2.0;
    const float2 offsets[8] = {float2(-1,0), float2(1,0), float2(0,-1), float2(0,1),
        float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1)};
    float2 qs[8];
    float2 guideUVs[8];
    float4 depths[8];
    float4 prepasses[8];
    float4 colors[8];
    [unroll]
    for (int k = 0; k < 8; ++k)
    {
        qs[k]=0; guideUVs[k]=0; depths[k]=0; prepasses[k]=0; colors[k]=0;
        if (k >= 4 && diagonalWeight <= 0.0) continue;
        qs[k] = centerUV + offsets[k] / gSourceSize;
        guideUVs[k] = clamp(qs[k] + uTraceJitterUV, BEAMRT_COH_UV_CLAMP_LO, BEAMRT_COH_UV_CLAMP_HI);
        depths[k] = LoadCombinedDepthPoint(guideUVs[k]);
        prepasses[k] = prepassTexTex.Load(BrtcTexelAt(guideUVs[k], gPrepassSize, gPrepassMaxCoord));
        colors[k] = BrtcSampleCurrent(qs[k]);
    }
    [unroll]
    for (int i = 0; i < 8; ++i)
    {
        if (i >= 4 && diagonalWeight <= 0.0) continue;
        float2 q = qs[i];
        if (any(q <= BEAMRT_COH_UV_CLAMP_LO) || any(q >= BEAMRT_COH_UV_CLAMP_HI)) continue;
        float2 guideUV = guideUVs[i];
        float4 sd = depths[i];
        if (sd.r <= 0.000001 || sd.r >= 0.999999 || abs(sd.b - d.b) > 0.25) continue;
        float4 samplePrepass = prepasses[i];
        if (d.b < 0.5 && abs(LoadRoughness(samplePrepass) - LoadRoughness(centerPrepass)) > 0.15) continue;
        float3 sn = sd.b > 0.5 ? float3(0,0,1) : DecodePrepassNormal(samplePrepass);
        float nd = dot(n, sn);
        if (nd < 0.9) continue;
        float3 sampleRay = BrtcScreenRay(guideUV);
        float3 delta = sampleRay * sd.r * projectionParams.y - centerPos;
        float planeError = max(abs(dot(delta, n)), abs(dot(delta, sn)));
        float w = exp(-planeError / max(footprint * 0.2, 0.01)) * pow(saturate(nd), 32.0);
        if (i >= 4) w *= diagonalWeight;
        float4 c = colors[i];
        if (c.a < 0.0) continue;
        sum += float4(c.rgb * c.a, c.a) * w;
        weightSum += w;
        // Radiance filled by a validated neighbor must not keep a center MISS
        // seed. This is representative metadata, not a new ray visibility test.
        float code = BrtcExtractHitCode(c.rgb);
        if (code < 62.5 && w * c.a > max(bestHitWeight, 1e-5))
        {
            bestHitWeight = w * c.a;
            hitCode = code;
        }
    }
    sum /= weightSum;
    float4 spatialSignal = float4(sum.a > 1e-5 ? sum.rgb / sum.a : float3(0,0,0), sum.a);
    return BrtcMixReflectionSignal(center, spatialSignal, reuse);
}

float4 BrtcReuseStochastic(float2 currentUV, float4 center, float4 projectionParams, float2 receiverGuideUV)
{
    float unusedHit;
    return BrtcReuseStochastic(currentUV, center, projectionParams, receiverGuideUV, unusedHit);
}

float4 BrtcSampleRoughTrace(float2 contentUV, out float hitCode)
{
    hitCode = BEAMRT_COH_HIT_DISTANCE_INFINITE;
    float bestHitWeight = 1e-5;
    float2 position = (contentUV - uRoughTraceJitterUV) * gAuxSize - 0.5;
    int2 base = int2(floor(position));
    float2 f = frac(position);
    float4 accum = 0.0;
    float total = 0.0;
    [unroll]
    for (int i = 0; i < 4; ++i)
    {
        int2 o = int2(i & 1, i >> 1);
        float4 c = auxTexTex.Load(int3(clamp(base + o, int2(0, 0), (int2)gAuxMaxCoord), 0));
        float w = (o.x ? f.x : 1.0 - f.x) * (o.y ? f.y : 1.0 - f.y) * step(0.0, c.a);
        accum += float4(c.rgb * c.a, c.a) * w;
        total += w;
        float code = BrtcExtractHitCode(c.rgb);
        if (code < 62.5 && w * c.a > bestHitWeight)
        {
            bestHitWeight = w * c.a;
            hitCode = code;
        }
    }
    if (total <= 1e-5)
        return 0.0;
    accum /= total;
    return float4(accum.a > 1e-5 ? accum.rgb / accum.a : float3(0.0, 0.0, 0.0), accum.a);
}

float4 BrtcReconstructCurrent(float2 currentUV, float2 receiverUV,
    float4 receiverDepth, float3 n, float3 receiverRay, float3 rayDU, float3 rayDV,
    out float hitCode, out float rebuildCode)
{
    hitCode = BEAMRT_COH_HIT_DISTANCE_INFINITE;
    rebuildCode = BEAMRT_COH_HIT_DISTANCE_INFINITE;
    float bestRebuildWeight = -1.0;
    float2 position = currentUV * gSourceSize - 0.5;
    int2 base = int2(floor(position));
    float2 f = frac(position);

    int2 pixels[4];
    float4 values[4];
    float coverage = 0.0;
    [unroll]
    for (int k = 0; k < 4; ++k)
    {
        pixels[k] = clamp(base + int2(k & 1, k >> 1), int2(0, 0), int2(gSourceMaxCoord));
        values[k] = sourceTexTex.Load(int3(pixels[k], 0));
        coverage = max(coverage, values[k].a);
    }
    if (coverage <= 0.0)
        return 0.0;
    float bestWeight = -1.0;

    float2 guideUVs[4];
    float4 depths[4];
    float4 guides[4];
    [unroll]
    for (int g = 0; g < 4; ++g)
    {
        float2 sampleUV = (float2(pixels[g]) + 0.5) / gSourceSize;
        guideUVs[g] = clamp(sampleUV + uTraceJitterUV, BEAMRT_COH_UV_CLAMP_LO, BEAMRT_COH_UV_CLAMP_HI);
        [branch]
        if (uReuseGuides > 0.5)
        {
            float4 gd = sourceTexTex.Load(int3(pixels[g] + int2((int)gSourceSize.x, 0), 0));
            float3 gn;
            float2 dw = BrtcUnpackReuseGuide(gd, gn);
            depths[g] = float4(dw.x, 0.0, dw.y, 0.0);
            guides[g] = float4(gn, 0.0);
        }
        else
        {
            depths[g] = LoadCombinedDepthPoint(guideUVs[g]);
            guides[g] = prepassTexTex.Load(BrtcTexelAt(guideUVs[g], gPrepassSize, gPrepassMaxCoord));
        }
    }

    float3 receiverPosition = receiverRay * receiverDepth.r;
    float footprint = receiverDepth.r * max(length(rayDU) / gSourceSize.x,
                                            length(rayDV) / gSourceSize.y);
    float tolerance = max(max(footprint * 0.20, 0.01),
                          receiverDepth.r * projParams.y * 0.001);
    float4 accum = 0.0;
    float totalWeight = 0.0;
    [unroll]
    for (int i = 0; i < 4; ++i)
    {
        int2 offset = int2(i & 1, i >> 1);
        float4 depth = depths[i];
        if (depth.r <= 0.000001 || depth.r >= 0.999999 ||
            abs(depth.b - receiverDepth.b) > 0.25) continue;
        float3 sampleRay = receiverRay + rayDU * (guideUVs[i].x - receiverUV.x) +
                                        rayDV * (guideUVs[i].y - receiverUV.y);
        float3 delta = sampleRay * depth.r - receiverPosition;
        float planeError = abs(dot(delta, n));
        if (planeError > tolerance * 3.0) continue;
        float3 sn = depth.b > 0.5 ? float3(0, 0, 1)
            : ((uReuseGuides > 0.5) ? guides[i].xyz : DecodePrepassNormal(guides[i]));
        float agreement = dot(n, sn);
        if (agreement < 0.80) continue;
        planeError = max(planeError, abs(dot(delta, sn)));
        float2 axisWeight = float2(offset.x == 0 ? 1.0 - f.x : f.x,
                                   offset.y == 0 ? 1.0 - f.y : f.y);
        float weight = axisWeight.x * axisWeight.y *
            exp(-planeError / tolerance) * smoothstep(0.80, 0.98, agreement);
        float4 sampleValue = values[i];
        accum += float4(sampleValue.rgb * sampleValue.a, sampleValue.a) * weight;
        totalWeight += weight;
        float tapStrength = weight * sampleValue.a;
        float tapCode = BrtcExtractHitCode(sampleValue.rgb);
        if (tapStrength > bestWeight)
        {
            bestWeight = tapStrength;
            hitCode = tapCode;
        }
        if (tapCode < BEAMRT_COH_HIT_DISTANCE_INFINITE - 0.5 && tapStrength > bestRebuildWeight)
        {
            bestRebuildWeight = tapStrength;
            rebuildCode = tapCode;
        }
    }
    if (totalWeight <= 1e-5) return 0.0;
    accum /= totalWeight;
    return float4(accum.a > 1e-5 ? accum.rgb / accum.a : float3(0, 0, 0), accum.a);
}

float4 BrtcWriteGeometry(float2 uv)
{
    float4 d = LoadCombinedDepthPoint(uv);
    if (d.r <= 0.000001 || d.r >= 0.999999) return 0.0;
    float3 n = d.b > 0.5 ? float3(0,0,1) : DecodePrepassNormal(prepassTexTex.Load(BrtcTexelAt(uv, gPrepassSize, gPrepassMaxCoord)));
    return float4(d.r, BrtcEncodeHistoryNormal(n), d.b > 0.5 ? 2.0 : 1.0);
}
float BrtcValidateHistory(float2 uv, float3 worldPos, float3 n, float receiverClass,
    float expectedDepth, BrtcPrevCamera cam, out float4 edgeHistory)
{
    uint w, h; terrainTexTex.GetDimensions(w, h);
    float2 size = float2(w, h);
    float2 p = uv * size - 0.5;
    int2 base = int2(floor(p)); float2 f = frac(p);
    float3 camRayOrigin, camRayDU, camRayDV;
    BrtcPrevCameraRays(cam, camRayOrigin, camRayDU, camRayDV);
    float footprint = expectedDepth * max(length(camRayDU) / size.x, length(camRayDV) / size.y);
    float tolerance = max(0.02, expectedDepth * projParams.y * 0.0015) + footprint * 0.35;
    float sum = 0.0; float4 accum = 0.0;
    float validWeights[4] = {0,0,0,0};
    [unroll] for (int i = 0; i < 4; ++i)
    {
        int2 o = int2(i & 1, i >> 1);
        int2 q = base + o;
        if (any(q < 0) || any(q >= int2(w,h))) continue;
        float4 g = terrainTexTex.Load(int3(q,0));
        if (abs(g.a - receiverClass) > 0.25 || g.r <= 0.0) continue;
        float3 pn = BrtcDecodeHistoryNormal(g.gb);
        float agreement = dot(n, pn);
        if (agreement < 0.8) continue;
        float2 quv = (float2(q) + 0.5) / size;
        float3 previousRay = camRayOrigin + camRayDU * quv.x + camRayDV * quv.y;
        float3 previousPoint = cam.eye + previousRay * g.r;
        float3 delta = previousPoint - worldPos;
        float planeError = max(abs(dot(delta, n)), abs(dot(delta, pn)));
        if (planeError > tolerance) continue;
        float grazing = max(abs(dot(normalize(previousRay), pn)), 0.02);
        if (length(delta) > footprint * 3.0 / grazing + tolerance * 3.0) continue;
        float2 weights = float2(o.x ? f.x : 1-f.x, o.y ? f.y : 1-f.y);
        float weight = weights.x * weights.y;
        validWeights[i] = weight;
        sum += weight;
    }
    if (sum > 0.0 && sum < 0.999)
    {
        [unroll] for (int j = 0; j < 4; ++j)
        {
            if (validWeights[j] <= 0.0) continue;
            float2 quv = (float2(base + int2(j & 1, j >> 1)) + 0.5) / size;
            float4 c = tex2Dlod(auxTex, float4(quv,0,0));
            accum += float4(c.rgb * c.a, c.a) * validWeights[j];
        }
    }
    accum /= max(sum, 1e-6);
    edgeHistory = float4(accum.a > 1e-5 ? accum.rgb / accum.a : float3(0,0,0), accum.a);
    return saturate(sum);
}

#define BEAMRT_COH_MOTION_SAME_PIXEL 0
#define BEAMRT_COH_MOTION_CAMERA 1
#define BEAMRT_COH_MOTION_ENGINE 2
#define BEAMRT_COH_MOTION_VEHICLE 3
#define BEAMRT_COH_MOTION_DISOCCLUDED 4
#define BEAMRT_COH_MOTION_LUA_CAMERA 5

float3 BrtcMotionSourceColor(int source)
{
    float3 c = float3(0.35, 0.35, 0.35);
    if (source == BEAMRT_COH_MOTION_CAMERA) c = float3(0.15, 0.35, 1.0);
    if (source == BEAMRT_COH_MOTION_ENGINE) c = float3(0.15, 0.9, 0.25);
    if (source == BEAMRT_COH_MOTION_VEHICLE) c = float3(1.0, 0.6, 0.1);
    if (source == BEAMRT_COH_MOTION_DISOCCLUDED) c = float3(1.0, 0.1, 0.1);
    if (source == BEAMRT_COH_MOTION_LUA_CAMERA) c = float3(0.6, 0.2, 1.0);
    return c;
}

bool BrtcOnPlayerVehicle(float3 worldPos, out float3 local)
{
    float3 d = worldPos - uVehicleCenter.xyz;
    local = float3(dot(d, uVehicleAxisX.xyz), dot(d, uVehicleAxisY.xyz),
                   dot(d, uVehicleAxisZ.xyz));
    float3 limit = uVehicleHalf.xyz * 1.03 + 0.05;
    return all(abs(local) <= limit) && local.z > -uVehicleHalf.z + 0.06;
}

float3 BrtcPlayerVehiclePrevious(float3 local)
{
    return uVehiclePrevCenter.xyz + uVehiclePrevAxisX.xyz * local.x +
           uVehiclePrevAxisY.xyz * local.y + uVehiclePrevAxisZ.xyz * local.z;
}

bool BrtcSegmentHitsBoxT(float3 a, float3 b, float3 center,
                        float3 axisX, float3 axisY, float3 axisZ, float3 halfSize, out float enter, out float leave)
{
    float3 la = float3(dot(a - center, axisX), dot(a - center, axisY), dot(a - center, axisZ));
    float3 lb = float3(dot(b - center, axisX), dot(b - center, axisY), dot(b - center, axisZ));
    float3 d = lb - la;
    float3 safeD = float3(abs(d.x) > 1e-6 ? d.x : 1e-6,
                          abs(d.y) > 1e-6 ? d.y : 1e-6,
                          abs(d.z) > 1e-6 ? d.z : 1e-6);
    float3 t0 = (-halfSize - la) / safeD;
    float3 t1 = (halfSize - la) / safeD;
    float3 tNear = min(t0, t1);
    float3 tFar = max(t0, t1);
    enter = max(max(max(tNear.x, tNear.y), tNear.z), 0.0);
    leave = min(min(min(tFar.x, tFar.y), tFar.z), 1.0);
    return enter <= leave;
}

bool BrtcSegmentHitsBox(float3 a, float3 b, float3 center,
                       float3 axisX, float3 axisY, float3 axisZ, float3 halfSize)
{
    float3 la = float3(dot(a - center, axisX), dot(a - center, axisY), dot(a - center, axisZ));
    float3 lb = float3(dot(b - center, axisX), dot(b - center, axisY), dot(b - center, axisZ));
    float3 d = lb - la;
    float3 safeD = float3(abs(d.x) > 1e-6 ? d.x : 1e-6,
                          abs(d.y) > 1e-6 ? d.y : 1e-6,
                          abs(d.z) > 1e-6 ? d.z : 1e-6);
    float3 t0 = (-halfSize - la) / safeD;
    float3 t1 = (halfSize - la) / safeD;
    float3 tNear = min(t0, t1);
    float3 tFar = max(t0, t1);
    float enter = max(max(max(tNear.x, tNear.y), tNear.z), 0.0);
    float leave = min(min(min(tFar.x, tFar.y), tFar.z), 1.0);
    return enter <= leave;
}

float BrtcSegmentPointDistance(float3 a, float3 b, float3 p)
{
    float3 ab = b - a;
    float t = saturate(dot(p - a, ab) / max(dot(ab, ab), 1e-8));
    return length(a + ab * t - p);
}

bool BrtcPlayerVehicleUncovered(float3 previousEye, float3 worldPos, SSRProjectionBasis basis)
{
    float3 halfSize = uVehicleHalf.xyz * 1.03 + 0.05;
    if (BrtcSegmentPointDistance(previousEye, worldPos, uVehiclePrevCenter.xyz) > length(halfSize))
        return false;
    float enterT, leaveT;
    bool coveredBefore = BrtcSegmentHitsBoxT(previousEye, worldPos, uVehiclePrevCenter.xyz,
        uVehiclePrevAxisX.xyz, uVehiclePrevAxisY.xyz, uVehiclePrevAxisZ.xyz, halfSize, enterT, leaveT);
    bool coveredNow = BrtcSegmentHitsBox(eyePosWorld, worldPos, uVehicleCenter.xyz,
        uVehicleAxisX.xyz, uVehicleAxisY.xyz, uVehicleAxisZ.xyz, halfSize);
    bool uncovered = coveredBefore && !coveredNow;
    if (uncovered)
    {
        float3 midPrev = lerp(previousEye, worldPos, 0.5 * (enterT + leaveT));
        float3 d = midPrev - uVehiclePrevCenter.xyz;
        float3 local = float3(dot(d, uVehiclePrevAxisX.xyz), dot(d, uVehiclePrevAxisY.xyz), dot(d, uVehiclePrevAxisZ.xyz));
        float3 midNow = uVehicleCenter.xyz + uVehicleAxisX.xyz * local.x + uVehicleAxisY.xyz * local.y +
                        uVehicleAxisZ.xyz * local.z;
        float zMid, conf;
        float2 q = ProjectWorldToUVFast(basis, midNow, zMid, conf);
        uncovered = false;
        if (zMid > 1e-6 && all(q > 0.0) && all(q < 1.0))
        {
            float surface = LoadCombinedDepthPoint(q).r;
            float3 surfaceWorld = eyePosWorld + (midNow - eyePosWorld) * (surface / zMid);
            float3 unused;
            uncovered = surface <= zMid + 0.05 / max(projParams.y, 1.0) && BrtcOnPlayerVehicle(surfaceWorld, unused);
        }
    }
    return uncovered;
}

#if defined(BEAMRT_COH_SSR_NO_DEBUG)
#define BEAMRT_COH_TEMPORAL_DEBUG_VIEW 0
#else
#define BEAMRT_COH_TEMPORAL_DEBUG_VIEW ((int)uDebugView)
#endif

#include "beamrt_coherent_accumulate.hlsl"

float4 BrtcDenoiseLegacy(PFXVertToPix IN, float2 uv, float4 projectionParams)
{
    if (uReuseGuides > 0.5)
    {
        gSourceSize.x = floor(gSourceSize.x * 0.5);
        gSourceMaxCoord = gSourceSize - 1.0;
    }
    float3 currentRayDU = ddx(IN.wsEyeRay) / max(abs(ddx(uv.x)), 1e-8);
    float3 currentRayDV = ddy(IN.wsEyeRay) / max(abs(ddy(uv.y)), 1e-8);
    float4 receiverDepth = LoadCombinedDepthPoint(uv);
    float eyeDepth01 = saturate(receiverDepth.r);
    if (eyeDepth01 <= 0.000001 || eyeDepth01 >= 0.999999)
        return float4(0, 0, 0, 0);

    float2 currentUV = clamp(uv - uTraceJitterUV - uCameraJitterUV, BEAMRT_COH_UV_CLAMP_LO, BEAMRT_COH_UV_CLAMP_HI);
    bool waterReceiver = receiverDepth.b > 0.5;
    float4 receiverPrepass = prepassTexTex.Load(BrtcTexelAt(uv, gPrepassSize, gPrepassMaxCoord));
    float3 receiverNormal = waterReceiver ? float3(0, 0, 1) : DecodePrepassNormal(receiverPrepass);
    bool guidedReconstruction = uGeometryReconstruction > 0.5 &&
        any(gSourceSize < gDepthSize * 0.99);
    float currentHitCode = BEAMRT_COH_HIT_DISTANCE_INFINITE;
    float currentRebuildCode = BEAMRT_COH_HIT_DISTANCE_INFINITE;
    float4 current;
    if (guidedReconstruction)
        current = BrtcReconstructCurrent(currentUV, uv, receiverDepth, receiverNormal, IN.wsEyeRay,
                                        currentRayDU, currentRayDV, currentHitCode, currentRebuildCode);
    else
    {
        current = BrtcSampleCurrent(currentUV);
        currentHitCode = BrtcExtractHitCode(sourceTexTex.Load(BrtcTexelAt(currentUV, gSourceSize, gSourceMaxCoord)).rgb);
        currentRebuildCode = currentHitCode;
    }
    float4 rawCurrent = current;
    if (uReusePrefiltered < 0.5)
    {
        current = BrtcReuseStochastic(currentUV, current, projectionParams, uv, currentHitCode);
        currentRebuildCode = currentHitCode;
    }
    float strength = min(saturate(uTemporalStrength), 0.98);
    if (strength <= 0.0001 || uTemporalHistoryValid < 0.5)
        return (float)BEAMRT_COH_TEMPORAL_DEBUG_VIEW >= 44.0 ? float4(0,0,1,1)
            : float4(BrtcEmbedHitCode(current.rgb, currentRebuildCode), current.a);

    float3 worldPos = ReconstructWorldPosition(IN, eyeDepth01);
    float2 historyUV;
    float historyDepth;

    bool velocityActive = uVelocityValid > 0.5;
    BrtcPrevCamera prevCam = BrtcEmptyPreviousCamera();
    if (uCameraHistoryValid > 0.5)
    {
        if (velocityActive)
            prevCam = BrtcLoadPreviousCameraFrom(terrainTexTex, projectionParams);
        else
            prevCam = BrtcLoadPreviousCameraFrom(debugTexTex, projectionParams);
    }
    float2 staticUV = uv;
    float staticDepth = 0.0;
    bool staticSolved = prevCam.valid && BrtcSolvePreviousUV(prevCam, worldPos - prevCam.eye, staticUV, staticDepth);
    bool haveExact = staticSolved && all(staticUV > BEAMRT_COH_UV_CLAMP_LO) && all(staticUV < BEAMRT_COH_UV_CLAMP_HI);
    int motionSource = BEAMRT_COH_MOTION_SAME_PIXEL;
    float3 historyWorldPos = worldPos;
    if (velocityActive && !waterReceiver)
    {
        float2 velocityUV = uv + LoadDebugDataPoint(uv).xy;
        historyUV = velocityUV;
        historyDepth = staticDepth;
        motionSource = BEAMRT_COH_MOTION_ENGINE;
    }
    else if (haveExact)
    {
        historyUV = staticUV;
        historyDepth = staticDepth;
        motionSource = BEAMRT_COH_MOTION_CAMERA;
    }
    else
    {
        if (!BrtcProjectPreviousUV(worldPos, uv, historyUV, historyDepth))
            return current;
        motionSource = BEAMRT_COH_MOTION_LUA_CAMERA;
    }

    if (staticSolved && uVehicleHalf.w > 0.5)
    {
        float3 local;
        bool onVehicle = uMotionOptions.x > 0.5 && BrtcOnPlayerVehicle(worldPos, local);
        bool engineHole = motionSource != BEAMRT_COH_MOTION_ENGINE ||
            length((historyUV - staticUV) * gDepthSize) < 0.75;
        if (onVehicle && engineHole)
        {
            historyWorldPos = BrtcPlayerVehiclePrevious(local);
            if (!BrtcSolvePreviousUV(prevCam, historyWorldPos - prevCam.eye, historyUV, historyDepth))
                return current;
            motionSource = BEAMRT_COH_MOTION_VEHICLE;
        }
        else if (!onVehicle && uMotionOptions.y > 0.5 &&
                 BrtcPlayerVehicleUncovered(prevCam.eye, worldPos, BuildProjectionBasis(IN, uv, worldPos)))
        {
            motionSource = BEAMRT_COH_MOTION_DISOCCLUDED;
        }
    }
    if (BEAMRT_COH_TEMPORAL_DEBUG_VIEW == 47)
        return float4(BrtcMotionSourceColor(motionSource), 1.0);
    if (motionSource == BEAMRT_COH_MOTION_DISOCCLUDED)
        return current;
    if (!(all(historyUV > BEAMRT_COH_UV_CLAMP_LO) && all(historyUV < BEAMRT_COH_UV_CLAMP_HI)))
        return current;

    float receiverRoughnessEarly = waterReceiver ? uWaterSSRRoughness : LoadRoughness(receiverPrepass);
    float virtualWeight = 0.0;
    float2 virtualUV = historyUV;
    float virtualTranslationPixels = 0.0;
    bool movingReceiver = motionSource == BEAMRT_COH_MOTION_VEHICLE ||
        (motionSource == BEAMRT_COH_MOTION_ENGINE && staticSolved && length((historyUV - staticUV) * gDepthSize) > 0.75);
    if (uVirtualReprojection > 0.5 && prevCam.valid && !movingReceiver)
    {
        virtualWeight = 1.0 - smoothstep(uVirtualRoughStart, max(uVirtualRoughEnd, uVirtualRoughStart + 0.01),
                                         receiverRoughnessEarly);
        if (virtualWeight > 0.001)
        {
            float3 viewDir = normalize(worldPos - eyePosWorld);
            float hitMetres = BrtcDecodeHitDistanceCode(currentHitCode);
            float2 solvedUV;
            float solvedDepth;
            bool solved = (hitMetres >= 1e5)
                ? BrtcSolvePreviousUV(prevCam, viewDir, solvedUV, solvedDepth)
                : BrtcSolvePreviousUV(prevCam, worldPos + viewDir * hitMetres - prevCam.eye, solvedUV, solvedDepth);
            solvedUV=BrtcScaleReflectionTranslation(historyUV,solvedUV);
            if (solved && all(solvedUV > BEAMRT_COH_UV_CLAMP_LO) && all(solvedUV < BEAMRT_COH_UV_CLAMP_HI))
                virtualUV = solvedUV;
            else
                virtualWeight = 0.0;
        }
    }

    bool validateGeometry = uHistoryGeometryValid > 0.5 && haveExact && !velocityActive;
    float geometryConfidence = 1.0;
    float4 edgeHistory = 0.0;
    if (validateGeometry)
    {
        geometryConfidence = BrtcValidateHistory(historyUV, historyWorldPos, receiverNormal,
            waterReceiver ? 2.0 : 1.0, historyDepth, prevCam, edgeHistory);
    }
    if (BEAMRT_COH_TEMPORAL_DEBUG_VIEW == 44)
        return validateGeometry ? float4(1-geometryConfidence,geometryConfidence,0,1) : float4(0,0,1,1);
    if (validateGeometry && geometryConfidence < 0.05)
        return (float)BEAMRT_COH_TEMPORAL_DEBUG_VIEW >= 45.0 ? float4(0,0,0,1) : current;

    float2 historyUVInf = historyUV;
    if (haveExact)
    {
        float2 infUV;
        float infDepth;
        if (BrtcSolvePreviousUV(prevCam, IN.wsEyeRay, infUV, infDepth))
            historyUVInf = infUV;
    }
    else
    {
        float depthInf = dot(IN.wsEyeRay, uPrevCameraForward);
        if (uTemporalReprojectionValid > 0.5 && depthInf > 1e-6)
        {
            float ndcXInf = dot(IN.wsEyeRay, uPrevCameraRight) / (depthInf * max(uPrevTanHalfFovX, 1e-4));
            float ndcYInf = dot(IN.wsEyeRay, uPrevCameraUp) / (depthInf * max(uPrevTanHalfFovY, 1e-4));
            historyUVInf = float2(0.5 + ndcXInf * 0.5, 0.5 - ndcYInf * 0.5);
        }
    }
    float rotationPixels = length((historyUVInf - uv) * uResolution);
    float translationPixels = length((historyUV - historyUVInf) * uResolution);
    if (motionSource == BEAMRT_COH_MOTION_VEHICLE)
    {
        rotationPixels = 0.0;
        translationPixels = length((historyUV - uv) * uResolution);
    }
    if (virtualWeight > 0.0)
    {
        virtualTranslationPixels = length((virtualUV - historyUVInf) * uResolution) *
                                   lerp(1.0,saturate(uVirtualMotionScale),saturate(uVirtualParallaxScale));
        translationPixels = lerp(translationPixels, virtualTranslationPixels, virtualWeight);
    }
    float totalMotionPixels = rotationPixels + translationPixels;

    float2 fetchUV = (virtualWeight >= 0.999) ? virtualUV : historyUV;
    float2 subPixel = abs(frac(fetchUV * gAuxSize) - 0.5);
    bool phaseAligned = max(subPixel.x, subPixel.y) < 0.08;
    bool stableHistory = phaseAligned && totalMotionPixels < 0.35;

    bool compactHistory = uAdaptiveDenoising > 0.5 &&
        uStochasticSSR > 0.5 && uStochasticReuse >= 0.25;
    bool compactClamp = stableHistory || compactHistory;
    float4 history;
    if (validateGeometry && geometryConfidence < 0.999 && virtualWeight < 0.999)
        history = edgeHistory;
    else if (stableHistory)
        history = tex2Dlod(auxTex, float4(fetchUV, 0.0, 0.0));
    else if (compactHistory)
        history = BrtcSampleCatmullRomOptimized(TEX_SAMPLER(auxTex), fetchUV);
    else
        history = BrtcSampleCatmullRomAA(TEX_SAMPLER(auxTex), fetchUV);
    if (virtualWeight > 0.001 && virtualWeight < 0.999)
    {
        float4 virtualHistory = compactHistory
            ? BrtcSampleCatmullRomOptimized(TEX_SAMPLER(auxTex), virtualUV)
            : BrtcSampleCatmullRomAA(TEX_SAMPLER(auxTex), virtualUV);
        history = BrtcMixReflectionSignal(history, virtualHistory, virtualWeight);
    }
    if (history.a <= 0.0001)
        return current;

    float2 texel = 1.0 / max(uResolution, float2(1.0, 1.0));
    float3 colorSum = float3(0.0, 0.0, 0.0);
    float3 colorSqSum = float3(0.0, 0.0, 0.0);
    float alphaMin = 1e20;
    float alphaMax = -1e20;
    float neighborLumaSum = 0.0;
    float neighborLumaMax = 0.0;
    const float2 clampOffsets[13] = {
        float2( 0.0,  0.0), float2(-1.0,  0.0), float2(1.0,  0.0),
        float2( 0.0, -1.0), float2( 0.0,  1.0),
        float2(-1.0, -1.0), float2(1.0, -1.0),
        float2(-1.0,  1.0), float2(1.0,  1.0),
        float2(-2.0,  0.0), float2(2.0,  0.0),
        float2( 0.0, -2.0), float2(0.0,  2.0)
    };
    int clampSampleCount = compactClamp ? 5 : 13;

    float4 taps[13];
    taps[0] = rawCurrent;
    [unroll]
    for (int k = 1; k < 5; k++)
        taps[k] = BrtcSampleCurrent(clamp(currentUV + clampOffsets[k] * texel,
                                         BEAMRT_COH_UV_CLAMP_LO, BEAMRT_COH_UV_CLAMP_HI));
    [branch]
    if (!compactClamp)
    {
        [unroll]
        for (int k2 = 5; k2 < 13; k2++)
            taps[k2] = BrtcSampleCurrent(clamp(currentUV + clampOffsets[k2] * texel,
                                              BEAMRT_COH_UV_CLAMP_LO, BEAMRT_COH_UV_CLAMP_HI));
    }
    else
    {
        [unroll]
        for (int k3 = 5; k3 < 13; k3++)
            taps[k3] = 0.0;
    }

    [unroll]
    for (int i = 0; i < 13; i++)
    {
        if (i >= clampSampleCount)
            break;
        float4 c = taps[i];
        colorSum += c.rgb;
        colorSqSum += c.rgb * c.rgb;
        alphaMin = min(alphaMin, c.a);
        alphaMax = max(alphaMax, c.a);
        if (i > 0 && i < 9)
        {
            float neighborLuma = BrtcLuma(c.rgb);
            neighborLumaSum += neighborLuma;
            neighborLumaMax = max(neighborLumaMax, neighborLuma);
        }
    }

    float lumaNeighborCount = compactClamp ? 4.0 : 8.0;
    float localReference = max(neighborLumaSum / lumaNeighborCount, neighborLumaMax * 0.5);
    current.rgb = BrtcClampFirefly(current.rgb, localReference);
    alphaMin = min(alphaMin, current.a);
    alphaMax = max(alphaMax, current.a);

    bool transientMissProne = (uStochasticSSR > 0.5)
        || (abs(uTraceJitterUV.x) + abs(uTraceJitterUV.y) > 1e-9);
    if (transientMissProne && current.a < 0.01 && alphaMax < 0.025 && history.a > 0.01)
    {
        float holeMotionPixels = length((historyUV - uv) * uResolution);
        float holeMotionWeight = exp(-holeMotionPixels * max(uTemporalMotionRejection, 0.0) * 0.25);
        float holdWeight = saturate(strength * holeMotionWeight * 0.92);
        float4 held = BrtcMixReflectionSignal(current, history, holdWeight);
        held.a = saturate(held.a * 0.90);
        if (BEAMRT_COH_TEMPORAL_DEBUG_VIEW == 45) return float4(holdWeight.xxx,1);
        if (BEAMRT_COH_TEMPORAL_DEBUG_VIEW == 46) return float4(1,1,0,1);
        return held;
    }

    float invN = 1.0 / (float)clampSampleCount;
    float3 meanColor = colorSum * invN;
    float3 varColor = max(colorSqSum * invN - meanColor * meanColor, 0.0);
    float3 sigmaColor = sqrt(varColor);
    float clampPad = max(uTemporalClamp, 0.015);
    float gamma = lerp(1.25, 2.25, saturate(uStochasticSSR));

    float adaptStrength = saturate(uRoughnessAdaptiveDenoise);
    float roughFactor = 0.0;
    if (adaptStrength > 0.0001)
    {
        float receiverRoughness = waterReceiver ? uWaterSSRRoughness : LoadRoughness(receiverPrepass);
        float adaptRoughness;
        RoughnessMask(receiverRoughness, receiverNormal, adaptRoughness);
        roughFactor = smoothstep(0.10, 0.45, adaptRoughness);
        gamma *= lerp(1.0 - 0.20 * adaptStrength, 1.0 + 0.80 * adaptStrength, roughFactor);
    }
    float3 historyBeforeClip = history.rgb;
    history.rgb = clamp(history.rgb, meanColor - gamma * sigmaColor - clampPad,
                                     meanColor + gamma * sigmaColor + clampPad);
    float clipDistance = length(history.rgb - historyBeforeClip);
    float clipBoxHalfWidth = length(gamma * sigmaColor) + clampPad;
    float alphaHi = min(alphaMax + 0.05, 1.0);
    if (transientMissProne)
        alphaHi = max(alphaHi, history.a * 0.80);
    history.a = clamp(history.a, max(alphaMin - 0.05, 0.0), alphaHi);

    float validMotionScale = 1.0;
    if (validateGeometry)
    {
        float rough = waterReceiver ? uWaterSSRRoughness : LoadRoughness(receiverPrepass);
        validMotionScale = lerp(1.0, lerp(0.65,0.25,saturate(rough * 2.0)), geometryConfidence);
    }
    validMotionScale *= lerp(1.0 + 0.40 * adaptStrength, 1.0 - 0.70 * adaptStrength, roughFactor);
    float motionWeight = exp(-translationPixels * validMotionScale * max(uTemporalMotionRejection, 0.0) * 0.25)
                       * exp(-rotationPixels * max(uTemporalMotionRejectionRot, 0.0) * 0.25);
    float historyWeight = strength * motionWeight;

    float reactive = 1.0 - saturate(clipDistance / max(clipBoxHalfWidth, 0.02));
    float reactiveFloor = (uStochasticSSR > 0.5) ? 0.75 : 0.35;
    reactiveFloor = lerp(reactiveFloor, lerp(reactiveFloor, 0.95, adaptStrength), roughFactor);
    historyWeight *= lerp(reactiveFloor, 1.0, reactive);

    if (BEAMRT_COH_TEMPORAL_DEBUG_VIEW == 45) return float4(saturate(historyWeight).xxx,1);
    if (BEAMRT_COH_TEMPORAL_DEBUG_VIEW == 46) return float4(saturate(clipDistance / max(clipBoxHalfWidth,0.02)),0,0,1);
    float4 result = BrtcMixReflectionSignal(current, history, saturate(historyWeight));
    result.a = saturate(result.a);
    float outHitCode = currentRebuildCode;
    if (outHitCode >= BEAMRT_COH_HIT_DISTANCE_INFINITE - 0.5 && result.a > 0.0001)
        outHitCode = BrtcExtractHitCode(auxTexTex.Load(BrtcTexelAt(historyUV, gAuxSize, gAuxMaxCoord)).rgb);
    result.rgb = BrtcEmbedHitCode(result.rgb, outHitCode);
    return result;
}

float4 DenoiseSSR(PFXVertToPix IN, float2 uv, float4 projectionParams)
{
    float4 result = 0;
    if (uUnifiedTemporal > 0.5) result = BrtcAccumulateNative(IN, uv);
    else result = BrtcDenoiseLegacy(IN, uv, projectionParams);
    return result;
}

#endif
