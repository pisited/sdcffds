#ifndef BEAMRT_COH_SSR_SURFACE_INCLUDED
#define BEAMRT_COH_SSR_SURFACE_INCLUDED

float BrtcHash21(float2 p)
{
    float3 p3 = frac(float3(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

float BrtcValueNoise(float2 p)
{
    float2 i = floor(p);
    float2 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);

    float a = BrtcHash21(i);
    float b = BrtcHash21(i + float2(1.0, 0.0));
    float c = BrtcHash21(i + float2(0.0, 1.0));
    float d = BrtcHash21(i + float2(1.0, 1.0));

    return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

float BrtcFbm(float2 p, int octaves, float persistence, float lacunarity)
{
    float sum = 0.0;
    float amp = 1.0;
    float norm = 0.0;

    [loop]
    for (int i = 0; i < 6; i++)
    {
        if (i >= octaves)
            break;
        sum += amp * BrtcValueNoise(p);
        norm += amp;
        amp *= persistence;
        p = p * lacunarity + 19.19;
    }
    return sum / max(norm, 1e-4);
}

float3 BrtcEnvironmentReflection(float3 reflectDir)
{
    ColorSH9 sh;
    [unroll] for (int coefficient = 0; coefficient < 9; ++coefficient)
        sh.coefs[coefficient] = ambientSH9[coefficient].rgb;

    float bindingEnergy = 0.0;
    [unroll]
    for (int i = 0; i < 9; i++)
        bindingEnergy += abs(ambientSH9[i].r) + abs(ambientSH9[i].g) + abs(ambientSH9[i].b);
    if (bindingEnergy <= 0.0)
        return hdrEncode(float3(0.25, 0.27, 0.32) * max(uSkyReflectionBrightness, 0.0));

    float directionality = saturate(uSkyDirectionality);
    [unroll]
    for (int b = 1; b < 9; b++)
        sh.coefs[b] *= (b < 4) ? directionality : directionality * directionality;
    float3 color = max(0.0, evalSHIrradiance(sh, normalize(reflectDir)));
    color *= max(uSkyReflectionBrightness, 0.0);

    float lum = dot(color, float3(0.299, 0.587, 0.114));
    color = lerp(lum.xxx, color, max(uSkySaturation, 0.0));

    return hdrEncode(max(color, 0.0));
}

float2 BrtcWaterRippleSlope(float2 wp, float t)
{
    wp *= max(uWaterNoiseRippleScale, 1e-3);

    float2 slope = float2(0.0, 0.0);
    float amp = 1.0;
    float norm = 0.0;
    float freq = 1.0;
    float2 dir = normalize(float2(0.80, 0.60));

    const float ca = cos(2.399963);
    const float sa = sin(2.399963);

    [unroll]
    for (int i = 0; i < 4; i++)
    {
        float phase = BrtcValueNoise(wp * (freq * 0.15)) * 6.2831853;
        float x = dot(dir, wp) * freq + t * sqrt(freq) - phase;

        float s = sin(x) * 0.5 + 0.5;
        float dh = s * cos(x);

        slope += dir * (dh * amp * freq);
        norm += amp;

        amp *= 0.55;
        freq *= 1.9;
        dir = float2(dir.x * ca - dir.y * sa, dir.x * sa + dir.y * ca);
    }

    return slope / max(norm, 1e-4);
}

float3 BrtcTerrainPuddle(float3 worldPos)
{
    if (uTerrainMaskEnable < 0.5)
        return float3(1.0, 1.0, 1.0);

    float2 uv = (worldPos.xy - uTerrainOriginXY) / max(uTerrainWorldSize, 1.0);
    if (uTerrainFlipY > 0.5)
        uv.y = 1.0 - uv.y;

    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
        return float3(1.0, 1.0, 1.0);

    float mixW = tex2Dlod(terrainTex, float4(uv, 0.0, 0.0)).r;
    return float3(lerp(1.0, mixW, saturate(uTerrainMaskStrength)), 1.0, 1.0);
}

float BrtcPuddleMask(float3 worldPos, float3 normalWS, float matMix)
{
    float up = smoothstep(uPuddleUpDotStart, uPuddleUpDotEnd, normalWS.z);
    if (up <= 0.0)
        return 0.0;

    if (worldPos.z < uPuddleWaterCull - 0.05)
        return 0.0;

    float n = BrtcFbm(worldPos.xy * max(uPuddleScale, 1e-4), 4, 0.55, 2.0);

    float bandHi = lerp(uPuddleEdgeLo, max(uPuddleEdgeHi, uPuddleEdgeLo + 0.002), saturate(uPuddleEdgeSoftness));
    float island = smoothstep(uPuddleEdgeLo, max(bandHi, uPuddleEdgeLo + 0.001), n);

    float camDist = length(worldPos - eyePosWorld);
    float distFade = 1.0 - smoothstep(uPuddleFadeStart, max(uPuddleFadeEnd, uPuddleFadeStart + 0.001), camDist);

    return saturate(island * up * saturate(uPuddleStrength) * distFade * saturate(matMix));
}

float3 BrtcPuddleRippleNormal(float3 worldPos, float amount)
{
    const float h = 0.15;
    float2 p = worldPos.xy * max(uPuddleRippleScale, 1e-4);

    float t = uTime * uPuddleRippleSpeed * 60.0;
    float2 fa = t * float2(0.6, 0.8);
    float2 fb = t * float2(-1.0, 0.35);

    float r0 = 0.5 * (BrtcValueNoise(p + fa)                 + BrtcValueNoise(p * 1.7 + fb));
    float r1 = 0.5 * (BrtcValueNoise(p + float2(h, 0.0) + fa) + BrtcValueNoise((p + float2(h, 0.0)) * 1.7 + fb));
    float r2 = 0.5 * (BrtcValueNoise(p + float2(0.0, h) + fa) + BrtcValueNoise((p + float2(0.0, h)) * 1.7 + fb));

    float3 nrm = normalize(float3(-(r1 - r0) / h, -(r2 - r0) / h, 1.0));
    return normalize(lerp(float3(0.0, 0.0, 1.0), nrm, saturate(amount)));
}

float BrtcApplyPuddle(float3 worldPos, inout float3 normalWS, inout float roughness, out float outReflect, out float outDark)
{
    outReflect = 1.0;
    outDark = 1.0;
    if (uPuddleStrength <= 0.001)
        return 0.0;

    float3 terr = BrtcTerrainPuddle(worldPos);
    float mask = BrtcPuddleMask(worldPos, normalWS, terr.r);
    if (mask <= 0.0001)
        return 0.0;

    float3 rippleN = BrtcPuddleRippleNormal(worldPos, mask * saturate(uPuddleRippleStrength));

    normalWS = normalize(lerp(normalWS, rippleN, mask));
    roughness = lerp(roughness, max(uPuddleRoughness, 0.004), mask);
    outReflect = terr.g;
    outDark = terr.b;
    return mask;
}

#endif
