#ifndef BEAMRT_COH_SSR_PYRAMID_HLSL
#define BEAMRT_COH_SSR_PYRAMID_HLSL

float LoadOpaqueRawDepthPoint(float2 uv)
{
    return prepassDepthTexTex.Load(BrtcTexelAt(uv, gDepthSize, gDepthMaxCoord)).r;
}

float4 BuildCombinedDepth(PFXVertToPix IN, float2 uv, float4 projectionParams)
{
    float opaqueRawDepth = LoadOpaqueRawDepthPoint(uv);
    float opaqueRealDepth = ndcToRealDepth(opaqueRawDepth, projectionParams.zw);
    float opaqueEyeDepth01 = LoadEyeDepth01FromReal(opaqueRealDepth, projectionParams);
    bool invalidOpaque = IsInvalidDepth(opaqueRawDepth, opaqueRealDepth, opaqueEyeDepth01);
    if (invalidOpaque)
        opaqueEyeDepth01 = 1.0;

    float waterMask = 0.0;
    float waterEyeDepth01 = 1.0;

    if (uWaterSSR > 0.5 && uWaterShaderData > 0.5 && uWaterShaderDataAvailable > 0.5)
    {
        float3 opaqueWorldPos = ReconstructWorldPosition(IN, opaqueEyeDepth01);
        WaterSurfaceInfo water = GetWaterSurfaceInfo(IN, uv, opaqueEyeDepth01, opaqueWorldPos);
        waterMask = saturate(water.mask) * step(water.eyeDepth01, opaqueEyeDepth01 + 1e-5);
        waterEyeDepth01 = saturate(water.eyeDepth01);
    }

    float combinedEyeDepth01 = (waterMask >= 0.5)
        ? min(opaqueEyeDepth01, waterEyeDepth01)
        : opaqueEyeDepth01;

    bool waterSurface = waterMask >= 0.5;
    float lightExposure = waterSurface ? BrtcSunPresence() : BrtcLightExposure(uv);
    float engineAO = 1.0;
    if (uEngineInputs.y > 0.5 && !waterSurface)
        engineAO = saturate(prepassTexTex.Load(BrtcTexelAt(uv, gPrepassSize, gPrepassMaxCoord)).r);
    float slope = 0.0;
    if (!invalidOpaque && waterMask < 0.5)
    {
        float2 texel = 1.0 / max(gDepthSize, float2(1.0, 1.0));
        float4 nd;
        nd.x = LoadOpaqueRawDepthPoint(uv - float2(texel.x, 0.0));
        nd.y = LoadOpaqueRawDepthPoint(uv + float2(texel.x, 0.0));
        nd.z = LoadOpaqueRawDepthPoint(uv - float2(0.0, texel.y));
        nd.w = LoadOpaqueRawDepthPoint(uv + float2(0.0, texel.y));
        float4 ne;
        [unroll]
        for (int k = 0; k < 4; ++k)
            ne[k] = LoadEyeDepth01FromReal(ndcToRealDepth(nd[k], projectionParams.zw), projectionParams);
        float4 diff = abs(ne - opaqueEyeDepth01);
        slope = max(min(diff.x, diff.y), min(diff.z, diff.w));
    }
    return float4(combinedEyeDepth01, slope, waterMask, BrtcPackExposureAO(lightExposure, engineAO));
}

float4 BrtcWriteCameraHistory(PFXVertToPix IN, float4 projectionParams)
{
    int2 pixel = clamp(int2(IN.hpos.xy), int2(0, 0), int2(1, 1));

    float3 ray = IN.wsEyeRay;
    float3 rayDU = ddx(ray) * 2.0;
    float3 rayDV = ddy(ray) * 2.0;
    float2 texelUV = (float2(pixel) + 0.5) * 0.5;
    float3 rayOrigin = ray - rayDU * texelUV.x - rayDV * texelUV.y;
    float3 bc = cross(rayDV, rayOrigin);
    float det = dot(rayDU, bc);
    bool invertible = abs(det) > 1e-20;
    float invDet = invertible ? 1.0 / det : 0.0;

    float3 row = bc * invDet;
    float alpha = eyePosWorld.x;
    if (pixel.x == 1 && pixel.y == 0)
    {
        row = cross(rayOrigin, rayDU) * invDet;
        alpha = eyePosWorld.y;
    }
    else if (pixel.x == 0 && pixel.y == 1)
    {
        row = cross(rayDU, rayDV) * invDet;
        alpha = eyePosWorld.z;
    }
    else if (pixel.x == 1 && pixel.y == 1)
    {
        row = float3(0.0, 0.0, 0.0);
        alpha = invertible ? 1.0 : 0.0;
    }
    return float4(row, alpha);
}

float4 DownsampleHiZ(PFXVertToPix IN, bool fromCombined)
{
    int2 sourceMax = (int2)gSourceMaxCoord;

    int2 sourceBase = int2(IN.hpos.xy) * 2;
    int2 span = int2((sourceBase.x + 2 == sourceMax.x) ? 3 : 2,
                     (sourceBase.y + 2 == sourceMax.y) ? 3 : 2);

    float minDepth = 1e20;
    float maxDepth = -1e20;
    float anyWater = 0.0;
    float exposureSum = 0.0;
    float taps = 0.0;
    [unroll]
    for (int y = 0; y < 3; y++)
    {
        [unroll]
        for (int x = 0; x < 3; x++)
        {
            if (x >= span.x || y >= span.y)
                continue;
            float4 d = sourceTexTex.Load(int3(min(sourceBase + int2(x, y), sourceMax), 0));
            minDepth = min(minDepth, d.r);
            maxDepth = max(maxDepth, fromCombined ? ((d.r < 0.999999) ? d.r : 0.0) : d.g);
            anyWater = max(anyWater, d.b);
            exposureSum += d.a;
            taps += 1.0;
        }
    }
    return float4(minDepth, maxDepth, anyWater, exposureSum / max(taps, 1.0));
}

float4 PackHiZLevels(PFXVertToPix IN)
{
    int2 p = int2(IN.hpos.xy);
    float2 level1 = sourceTexTex.Load(int3(min(p, (int2)gSourceMaxCoord), 0)).rg;
    float level2 = prepassTexTex.Load(int3(min(p >> 2, (int2)gPrepassMaxCoord), 0)).r;
    float level3 = prepassDepthTexTex.Load(int3(min(p >> 4, (int2)gDepthMaxCoord), 0)).r;
    if ((p.x & 63) == 1 && (p.y & 63) == 0)
    {
        int2 base = (p >> 6) << 2;
        level2 = 1e20;
        [unroll]
        for (int y = 0; y < 4; y++)
        {
            [unroll]
            for (int x = 0; x < 4; x++)
                level2 = min(level2, prepassDepthTexTex.Load(int3(min(base + int2(x, y), (int2)gDepthMaxCoord), 0)).r);
        }
    }
    return float4(level1, level2, level3);
}

float4 DownsampleSceneColor(float2 uv)
{
    return tex2Dlod(sourceTex, float4(clamp(uv, BEAMRT_COH_UV_CLAMP_LO, BEAMRT_COH_UV_CLAMP_HI), 0.0, 0.0));
}

#endif
