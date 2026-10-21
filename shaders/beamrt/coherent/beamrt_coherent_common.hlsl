#ifndef BEAMRT_COH_SSR_COMMON_HLSL
#define BEAMRT_COH_SSR_COMMON_HLSL

#define MAX_SSR_STEPS 256
#define MAX_BINARY_STEPS 8
#ifndef BEAMRT_COH_SSR_OVERHANG
#define BEAMRT_COH_SSR_OVERHANG 0
#endif
#ifdef BEAMRT_COH_SSR_ONE_RAY
#define BEAMRT_COH_MAX_STOCHASTIC_RAYS 1
#define BEAMRT_COH_RAY_LOOP [unroll]
#define uDebugView 0.0
#else
#define BEAMRT_COH_MAX_STOCHASTIC_RAYS 4
#define BEAMRT_COH_RAY_LOOP [loop]
#endif

static float2 gSourceSize      = float2(1.0, 1.0);
static float2 gSourceMaxCoord  = float2(0.0, 0.0);
static float2 gPrepassSize     = float2(1.0, 1.0);
static float2 gPrepassMaxCoord = float2(0.0, 0.0);
static float2 gDepthSize       = float2(1.0, 1.0);
static float2 gDepthMaxCoord   = float2(0.0, 0.0);
static float2 gAuxSize         = float2(1.0, 1.0);
static float2 gAuxMaxCoord     = float2(0.0, 0.0);
static float2 gDebugSize       = float2(1.0, 1.0);
static float2 gDebugMaxCoord   = float2(0.0, 0.0);

void BrtcCacheTextureSizes()
{
    uint w = 1;
    uint h = 1;

    sourceTexTex.GetDimensions(w, h);
    gSourceSize = max(float2((float)w, (float)h), float2(1.0, 1.0));
    gSourceMaxCoord = gSourceSize - 1.0;

    prepassTexTex.GetDimensions(w, h);
    gPrepassSize = max(float2((float)w, (float)h), float2(1.0, 1.0));
    gPrepassMaxCoord = gPrepassSize - 1.0;

    prepassDepthTexTex.GetDimensions(w, h);
    gDepthSize = max(float2((float)w, (float)h), float2(1.0, 1.0));
    gDepthMaxCoord = gDepthSize - 1.0;

    auxTexTex.GetDimensions(w, h);
    gAuxSize = max(float2((float)w, (float)h), float2(1.0, 1.0));
    gAuxMaxCoord = gAuxSize - 1.0;

    debugTexTex.GetDimensions(w, h);
    gDebugSize = max(float2((float)w, (float)h), float2(1.0, 1.0));
    gDebugMaxCoord = gDebugSize - 1.0;
}

int3 BrtcTexelAt(float2 uv, float2 size, float2 maxCoord)
{
    return int3((int2)clamp(floor(uv * size), float2(0.0, 0.0), maxCoord), 0);
}

static float2 gScreenScale  = float2(1.0, 1.0);
static float2 gScreenCenter = float2(0.0, 0.0);

void BrtcCacheScreenMapping(float3 eyeRay, float2 uv)
{
    float z = dot(eyeRay, uCameraForward);
    float2 tanHalf = max(float2(uTanHalfFovXCur, uTanHalfFovYCur), 1e-4);
    float2 ndcTrue = float2(dot(eyeRay, uCameraRight), dot(eyeRay, uCameraUp)) / (max(abs(z), 1e-6) * tanHalf);
    float2 ndcScreen = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    float2 dTrue = float2(ddx(ndcTrue.x), ddy(ndcTrue.y));
    float2 dScreen = float2(ddx(ndcScreen.x), ddy(ndcScreen.y));
    float2 scale = float2(abs(dScreen.x) > 1e-9 ? dTrue.x / dScreen.x : 1.0,
                          abs(dScreen.y) > 1e-9 ? dTrue.y / dScreen.y : 1.0);
    bool usable = uProjectionValid > 0.5 && uScreenMappingFromEngine > 0.5 && z > 1e-6
        && all(scale > 0.5) && all(scale < 2.0);
    float2 screenScale = usable ? scale : float2(1.0, 1.0);
    float2 screenCenter = usable ? ndcTrue - scale * ndcScreen : float2(0.0, 0.0);
#if defined(__SHADER_TARGET_MAJOR) && __SHADER_TARGET_MAJOR >= 6
    screenScale = WaveReadLaneFirst(screenScale);
    screenCenter = WaveReadLaneFirst(screenCenter);
#endif
    gScreenScale = screenScale;
    gScreenCenter = screenCenter;
}

float3 BrtcScreenRay(float2 uv)
{
    float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0) * gScreenScale + gScreenCenter;
    return uCameraForward + uCameraRight * (ndc.x * uTanHalfFovXCur) + uCameraUp * (ndc.y * uTanHalfFovYCur);
}

float2 BrtcScreenUVMapped(float3 v, float z, float2 screenCenter, float2 screenScale)
{
    float2 ndcTrue = float2(dot(v, uCameraRight) / (z * max(uTanHalfFovXCur, 1e-4)),
                            dot(v, uCameraUp) / (z * max(uTanHalfFovYCur, 1e-4)));
    float2 ndc = (ndcTrue - screenCenter) / screenScale;
    return float2(0.5 + ndc.x * 0.5, 0.5 - ndc.y * 0.5);
}

float2 BrtcScreenUV(float3 v, float z)
{
    return BrtcScreenUVMapped(v, z, gScreenCenter, gScreenScale);
}

float2 BrtcScreenCenterFromPoint(float3 worldPoint, float2 uv)
{
    float3 v = worldPoint - eyePosWorld;
    float z = dot(v, uCameraForward);
    float2 ndcTrue = float2(dot(v, uCameraRight) / (max(z, 1e-6) * max(uTanHalfFovXCur, 1e-4)),
                            dot(v, uCameraUp) / (max(z, 1e-6) * max(uTanHalfFovYCur, 1e-4)));
    bool usable = uProjectionValid > 0.5 && uScreenMappingFromEngine > 0.5 && z > 1e-6;
    return usable ? ndcTrue - float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0) : float2(0.0, 0.0);
}

float BrtcTanHalfFovY()
{
#if defined(BEAMRT_COH_SSR_PASS) && BEAMRT_COH_SSR_PASS == 0
    return max(uTanHalfFovYCur, 1e-4);
#else
    return max(uTanHalfFovYCur, 1e-4) * gScreenScale.y;
#endif
}

float Hash12(float2 p)
{
    float3 p3 = frac(float3(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

float InterleavedGradientNoise(float2 pixel)
{
    return frac(52.9829189 * frac(dot(pixel, float2(0.06711056, 0.00583715))));
}

// Per-pixel scramble, not an 8x8 ordered mask. This is decorrelated sampling,
// not a claim of blue-noise spectral quality or an automatic denoising fix.
uint BrtcSampleHash(uint v)
{
    v ^= v >> 16; v *= 0x7feb352du;
    v ^= v >> 15; v *= 0x846ca68bu;
    return v ^ (v >> 16);
}
float2 BrtcPixelScramble(float2 pixel)
{
    uint2 p = (uint2)max(floor(pixel), 0.0);
    uint h = BrtcSampleHash(p.x ^ BrtcSampleHash(p.y + 0x9e3779b9u));
    return (float2(h >> 8, BrtcSampleHash(h ^ 0x68bc21ebu) >> 8) + 0.5) / 16777216.0;
}

float BlueNoise8x8(float2 pixel)
{
    int2 p = ((int2)floor(pixel)) & 7;
    int idx = p.x + p.y * 8;
    static const float ranks[64] =
    {
        32,  8, 40, 16, 34, 10, 42, 18,
        48, 24, 56,  0, 50, 26, 58,  2,
        36, 12, 44, 20, 38, 14, 46, 22,
        52, 28, 60,  4, 54, 30, 62,  6,
        35, 11, 43, 19, 33,  9, 41, 17,
        51, 27, 59,  3, 49, 25, 57,  1,
        39, 15, 47, 23, 37, 13, 45, 21,
        55, 31, 63,  7, 53, 29, 61,  5
    };
    return (ranks[idx] + 0.5) * (1.0 / 64.0);
}

float StructuredJitter(float2 pixel, float frame, float amount)
{
    int2  pi   = (int2)floor(pixel);
    int   slot = (pi.x & 1) | ((pi.y & 1) << 1);

    static const float slotOffset[4] = { 0.0, 0.25, 0.5, 0.75 };

    float base  = uSamplingMode > 0.5 ? BrtcPixelScramble(pixel).x : BlueNoise8x8(pixel);
    float phase = slotOffset[slot];

    float rate = saturate(uJitterTemporalRate);
    if (rate > 0.001)
    {
        float drift = frac(frame * lerp(0.0, 0.083333, rate) * 0.61803398875);
        phase = frac(phase + drift);
    }

    float n = frac(base + phase);
    return 0.5 + (n - 0.5) * saturate(amount) * 0.58;
}

float RayPhaseJitter(float2 pixel, float frame, float amount)
{
    return StructuredJitter(pixel, frame, amount);
}

#define BEAMRT_COH_HIT_DISTANCE_MIN 0.05
#define BEAMRT_COH_HIT_DISTANCE_LOG2_STEP 0.24345
#define BEAMRT_COH_HIT_DISTANCE_INFINITE 63.0

float BrtcEncodeHitDistanceCode(float metres)
{
    float code = BEAMRT_COH_HIT_DISTANCE_INFINITE;
    if (metres > 0.0 && metres < 1e5)
        code = clamp(floor(log2(max(metres, BEAMRT_COH_HIT_DISTANCE_MIN) / BEAMRT_COH_HIT_DISTANCE_MIN) /
                           BEAMRT_COH_HIT_DISTANCE_LOG2_STEP + 0.5), 0.0, 62.0);
    return code;
}

float BrtcDecodeHitDistanceCode(float code)
{
    return code >= 62.5 ? 1e6 : BEAMRT_COH_HIT_DISTANCE_MIN * exp2(code * BEAMRT_COH_HIT_DISTANCE_LOG2_STEP);
}

float3 BrtcEmbedHitCode(float3 rgb, float code)
{
    uint c = (uint)code;
    uint3 h = f32tof16(max(rgb, 0.0));
    h = (h & 0xFFFCu) | uint3(c & 3u, (c >> 2) & 3u, (c >> 4) & 3u);
    return f16tof32(h);
}

float BrtcExtractHitCode(float3 rgb)
{
    uint3 h = f32tof16(max(rgb, 0.0));
    return (float)((h.x & 3u) | ((h.y & 3u) << 2) | ((h.z & 3u) << 4));
}

float BrtcPackExposureAO(float exposure, float ao)
{
    return floor(saturate(exposure) * 31.0 + 0.5) * 64.0 + floor(saturate(ao) * 63.0 + 0.5);
}

float BrtcHiZ0Exposure(float4 combinedDepth)
{
    return floor(max(combinedDepth.a, 0.0) / 64.0 + 1e-3) / 31.0;
}

float BrtcHiZ0AO(float4 combinedDepth)
{
    float packed = floor(max(combinedDepth.a, 0.0) + 0.5);
    return (packed - floor(packed / 64.0 + 1e-3) * 64.0) / 63.0;
}

float BrtcLuma(float3 c)
{
    return max(dot(max(c, 0.0), float3(0.2126, 0.7152, 0.0722)), 0.0);
}

float3 BrtcHdrCompress(float3 c)
{
    return (uHdrComposite > 0.5) ? c / (1.0 + BrtcLuma(c)) : c;
}

float3 BrtcHdrExpand(float3 c)
{
    return (uHdrComposite > 0.5) ? max(c, 0.0) / max(1.0 - BrtcLuma(c), 1e-3) : c;
}

float3 BrtcDisplayAuthored(float3 c)
{
    return (uHdrComposite > 0.5) ? c * 0.5 : c;
}

// Experimental reconstruction policy only: no new visibility or material gain.
// Keep mirror-like receivers and the engine water path out of this experiment.
float BrtcRoughStabilityWeight(float rough, float water)
{
    return (uRoughStability > 0.5 && uStochasticSSR > 0.5)
        ? (1.0 - step(0.5, water)) * smoothstep(0.12, 0.35, rough) : 0.0;
}

float BrtcFireflyWeight(float3 c, float referenceLuma)
{
    float strength = saturate(uFireflySuppression);
    if (strength <= 0.0001)
        return 1.0;

    float luma = BrtcLuma(c);
    float ceiling = max(referenceLuma * 4.0 + 0.25, 0.5);
    float clippedWeight = min(1.0, ceiling / max(luma, 1e-4));
    return lerp(1.0, clippedWeight, strength);
}

float3 BrtcClampFirefly(float3 c, float referenceLuma)
{
    return c * BrtcFireflyWeight(c, referenceLuma);
}

float2 BrtcStochasticSequence(float2 pixel, float sampleIndex, float rayCount)
{
    float sequenceFrame = fmod(floor(uFrame * max(uStochasticTemporalRate, 0.0) + 0.5), 4096.0);
    float n = sequenceFrame * max(rayCount, 1.0) + sampleIndex;
    float2 phase = uSamplingMode > 0.5 ? BrtcPixelScramble(pixel) :
        float2(BlueNoise8x8(pixel), InterleavedGradientNoise(pixel.yx + 17.0));
    float2 xi = frac(phase + n * float2(0.7548776662, 0.5698402910));
    return xi;
}

float3 BrtcSampleGGXVNDFLocal(float3 V, float alpha, float2 xi)
{
    V = normalize(float3(alpha * V.xy, max(V.z, 1e-4)));

    float phi = M_2PI_F * xi.x;
    float cosTheta = (1.0 - xi.y) * (1.0 + V.z) - V.z;
    float sinTheta = sqrt(saturate(1.0 - cosTheta * cosTheta));
    float3 reflected = float3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);

    float3 halfway = reflected + V;
    halfway = (dot(halfway, halfway) > 1e-7) ? normalize(halfway) : float3(0.0, 0.0, 1.0);
    return normalize(float3(alpha * halfway.xy, max(halfway.z, 1e-5)));
}

float3 BrtcSampleReflectionRayIndexed(float2 pixel, float3 N, float3 V, float roughness, float sampleIndex, float rayCount)
{
    float3 mirrorRay = normalize(reflect(-V, N));
    if (uStochasticSSR < 0.5)
        return mirrorRay;

    float3 up = (abs(N.z) < 0.999) ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
    float3 T = normalize(cross(up, N));
    float3 B = cross(N, T);
    float3 localV = normalize(float3(dot(V, T), dot(V, B), max(dot(V, N), 1e-4)));
    float alpha = max(roughness * roughness, 0.002);

    float smoothSurfaceBias = 1.0 - smoothstep(0.055, 0.30, roughness);
    float effectiveBias = max(saturate(uStochasticBias), smoothSurfaceBias);
    float samplingAlpha = max(alpha * lerp(1.0, 0.08, effectiveBias), 0.0005);
    float2 baseXi = BrtcStochasticSequence(pixel, sampleIndex, rayCount);

    float3 ray = mirrorRay;
    bool accepted = false;

    [unroll]
    for (int attempt = 0; attempt < 3; attempt++)
    {
        float2 xi = frac(baseXi + float2(0.618033989, 0.381966011) * (float)attempt);
        float3 localH = BrtcSampleGGXVNDFLocal(localV, samplingAlpha, xi);
        float3 H = normalize(T * localH.x + B * localH.y + N * localH.z);
        float3 candidate = normalize(reflect(-V, H));
        if (dot(candidate, N) > 1e-4)
        {
            ray = candidate;
            accepted = true;
            break;
        }
    }

    if (!accepted)
        ray = mirrorRay;

    return ray;
}

float3 BrtcSampleReflectionRay(float2 pixel, float3 N, float3 V, float roughness)
{
    return BrtcSampleReflectionRayIndexed(pixel, N, V, roughness, 0.0, 1.0);
}

float3 BrtcSamplePrefilteredScene(float2 uv, float roughness, float hitDistance, float NoV)
{
    float coneTangent = max(roughness * roughness, 0.001);
    coneTangent *= lerp(saturate(NoV * 2.0), 1.0, sqrt(saturate(roughness)));
    float footprint = 1.0 + hitDistance * coneTangent * max(uColorMipScale, 0.001);
    float mip = clamp(log2(footprint), 0.0, 4.0);

    float3 sharp = tex2Dlod(sourceTex, float4(uv, 0.0, 0.0)).rgb;
    float3 coarse = tex2Dlod(auxTex, float4(uv, 0.0, 0.0)).rgb;
    float3 result = sharp;
    if (uFilteredColor >= 0.5) result = lerp(sharp, coarse, mip * 0.25);
    return result;
}

float SmoothStepDistribution(float step01, float glossyBias)
{
    float quadratic = step01 * step01;
    float mixed = lerp(quadratic, step01, saturate(0.42 + glossyBias * 0.38));
    return mixed;
}

float4 LoadPrepass(float2 uv)
{
    return tex2Dlod(prepassTex, float4(uv, 0.0, 0.0));
}

float LoadRawDepth(float2 uv)
{
    return tex2Dlod(prepassDepthTex, float4(uv, 0.0, 0.0)).r;
}

float LoadRealDepth(float2 uv, float4 projectionParams)
{
    return ndcToRealDepth(LoadRawDepth(uv), projectionParams.zw);
}

float LoadEyeDepth01FromReal(float realDepth, float4 projectionParams)
{
    return realToEyeLinearDepth(realDepth, projectionParams);
}

float3 DecodePrepassNormal(float4 prepass)
{
    return normalize(decodeNormalXY(prepass.xy));
}

float LoadRoughness(float4 prepass)
{
    return max(0.02, prepass.z);
}

float4 LoadCombinedDepthPoint(float2 uv)
{
    return prepassDepthTexTex.Load(BrtcTexelAt(uv, gDepthSize, gDepthMaxCoord));
}

float4 LoadDebugDataPoint(float2 uv)
{
    return debugTexTex.Load(BrtcTexelAt(uv, gDebugSize, gDebugMaxCoord));
}

bool BrtcSunRadianceBound()
{
    return dot(sunDirection, sunDirection) > 0.25;
}

float BrtcSunPresence()
{
    float presence = 1.0;
    if (BrtcSunRadianceBound())
        presence = 1.0 - exp(-BrtcLuma(max(sunRadiance, 0.0)) * max(uLightExposureScale, 0.0001));
    return presence;
}

float3 BrtcSunHue()
{
    float3 hue = BrtcSunRadianceBound() ? max(sunRadiance, 0.0) : max(sunIrradiance, 0.0);
    float luma = BrtcLuma(hue);
    return luma > 1e-6 ? hue / luma : float3(1.0, 1.0, 1.0);
}

float BrtcLightExposure(float2 uv)
{
    float exposure = 1.0;
    float4 slot4 = LoadDebugDataPoint(uv);
    if (uEngineInputs.x > 0.5)
    {
        float visibility = saturate(slot4.r);
        if (uEngineInputs.z > 0.5)
        {
            uint contactWidth = 1;
            uint contactHeight = 1;
            terrainTexTex.GetDimensions(contactWidth, contactHeight);
            float2 contactSize = float2(contactWidth, contactHeight);
            visibility = min(visibility, saturate(
                terrainTexTex.Load(BrtcTexelAt(uv, contactSize, contactSize - 1.0)).r));
        }
        exposure = visibility * BrtcSunPresence();
    }
    else if (uLightInfoValid > 0.5)
    {
        exposure = 1.0 - exp(-BrtcLuma(max(slot4.rgb, 0.0)) * max(uLightExposureScale, 0.0001));
    }
    return exposure;
}

#endif
