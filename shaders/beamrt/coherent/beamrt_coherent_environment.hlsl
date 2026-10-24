#ifndef BEAMRT_COH_SSR_ENVIRONMENT_HLSL
#define BEAMRT_COH_SSR_ENVIRONMENT_HLSL

float4 BrtcBlendEnvironmentFill(float4 ssr, float expectedResponse, float3 environmentColor)
{
    if (expectedResponse <= 0.0001)
        return ssr;

    float existingAlpha = saturate(ssr.a);

    float fillAlpha = max(expectedResponse - existingAlpha, 0.0);
    if (fillAlpha <= 0.0001)
        return ssr;

    ssr.rgb = (ssr.rgb * existingAlpha + environmentColor * fillAlpha) /
              max(existingAlpha + fillAlpha, 0.0001);
    ssr.a = saturate(existingAlpha + fillAlpha);
    return ssr;
}

float BrtcEnvironmentDepthAt(float2 uv)
{
#if defined(BEAMRT_COH_SSR_PASS) && BEAMRT_COH_SSR_PASS == 3
    return LoadDebugDataPoint(uv).r;
#else
    return LoadCombinedDepthPoint(uv).r;
#endif
}

float3 BrtcScreenRayMapped(float2 uv, float2 screenCenter, float2 screenScale)
{
    float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0) * screenScale + screenCenter;
    return uCameraForward + uCameraRight * (ndc.x * uTanHalfFovXCur) + uCameraUp * (ndc.y * uTanHalfFovYCur);
}

float3 BrtcEnvironmentColor(float3 reflectDir, float lightExposure, float roughness,
    float2 screenCenter, float2 screenScale, out float screenWeight)
{
    float3 skyColor = BrtcEnvironmentReflection(reflectDir);
    if (uSkyLightTint > 0.0001)
    {
        float3 sunHue = BrtcSunHue();
        {
            float bias = saturate(uSkyLightTint) * saturate(lightExposure);
            float before = BrtcLuma(skyColor);
            float3 tinted = skyColor * lerp(float3(1.0, 1.0, 1.0), sunHue, bias);
            skyColor = tinted * (before / max(BrtcLuma(tinted), 1e-5));
        }
    }

    screenWeight = 0.0;
    float z = dot(reflectDir, uCameraForward);
    if (uSkyScreenSpace > 0.5 && uProjectionValid > 0.5 && z > 0.02)
    {
        float2 uvInf = BrtcScreenUVMapped(reflectDir, z, screenCenter, screenScale);
        float2 outside = max(max(-uvInf, uvInf - 1.0), 0.0);
        float offscreen = max(outside.x, outside.y);
        float calibrationWeight = 1.0 - smoothstep(0.0, 0.8, offscreen);
        if (calibrationWeight > 0.0)
        {
            float2 suv = clamp(uvInf, 0.002, 0.998);
            float depth01 = BrtcEnvironmentDepthAt(suv);
            float minDistance = max(uSkyScreenMinDistance, 1.0);
            float environmental = (depth01 >= 0.999999) ? 1.0
                : smoothstep(minDistance * 0.5, minDistance, depth01 * projParams.y);
            float2 calibrationUV = suv;
            float calibrationSource = environmental;
#if !defined(BEAMRT_COH_SSR_PASS) || BEAMRT_COH_SSR_PASS == 0
            if (environmental <= 0.0)
            {
                float probeDepth[4];
                [unroll]
                for (int k = 0; k < 4; ++k)
                    probeDepth[k] = BrtcEnvironmentDepthAt(float2(suv.x, lerp(suv.y, 0.02, (k + 1) * 0.25)));
                [unroll]
                for (int j = 3; j >= 0; --j)
                {
                    float probeEnvironmental = (probeDepth[j] >= 0.999999) ? 1.0
                        : smoothstep(minDistance * 0.5, minDistance, probeDepth[j] * projParams.y);
                    if (probeEnvironmental > 0.0)
                    {
                        calibrationUV = float2(suv.x, lerp(suv.y, 0.02, (j + 1) * 0.25));
                        calibrationSource = probeEnvironmental;
                    }
                }
            }
            if (environmental <= 0.0 && calibrationSource > 0.0)
            {
                float3 floodSky = tex2Dlod(sourceTex, float4(calibrationUV, 0.0, 0.0)).rgb;
#if !defined(BEAMRT_COH_SSR_PASS) || BEAMRT_COH_SSR_PASS == 0
                if (uFilteredColor > 0.5)
                    floodSky = tex2Dlod(auxTex, float4(calibrationUV, 0.0, 0.0)).rgb;
#endif
                float3 floodDir = normalize(BrtcScreenRayMapped(calibrationUV, screenCenter, screenScale));
                float3 floodRatio = clamp(floodSky * max(uSkyScreenBrightness, 0.0) /
                    max(BrtcEnvironmentReflection(floodDir), 1e-4), 0.2, 5.0);
                skyColor = lerp(skyColor, skyColor * floodRatio, calibrationWeight * calibrationSource);
            }
#endif
            if (environmental > 0.0)
            {
                float3 sharp = tex2Dlod(sourceTex, float4(suv, 0.0, 0.0)).rgb;
                float3 blurred = sharp;
#if !defined(BEAMRT_COH_SSR_PASS) || BEAMRT_COH_SSR_PASS == 0
                if (uFilteredColor > 0.5)
                    blurred = tex2Dlod(auxTex, float4(suv, 0.0, 0.0)).rgb;
#endif
                float brightness = max(uSkyScreenBrightness, 0.0);
                float3 edgeDir = normalize(BrtcScreenRayMapped(suv, screenCenter, screenScale));
                float3 edgeSH = BrtcEnvironmentReflection(edgeDir);
                float3 ratio = clamp(blurred * brightness / max(edgeSH, 1e-4), 0.2, 5.0);
                skyColor = lerp(skyColor, skyColor * ratio, calibrationWeight * environmental);
                screenWeight = (1.0 - smoothstep(0.0, 0.12, offscreen)) * environmental;
                float3 screenColor = lerp(sharp, blurred, smoothstep(0.08, 0.45, roughness)) * brightness;
                skyColor = lerp(skyColor, screenColor, screenWeight);
            }
        }
    }
    if (uLightInfoValid > 0.5)
        skyColor *= 1.0 + max(uSkySunBoost, 0.0) * saturate(lightExposure);
    return skyColor;
}

float BrtcEnvironmentOcclusion(float ao, float NoV, float roughness)
{
    ao = saturate(ao / clamp(uEngineAOOpenLevel, 0.5, 1.0));
    float specularAO = saturate(pow(saturate(NoV) + ao, exp2(-16.0 * roughness - 1.0)) - 1.0 + ao);
    return lerp(1.0, specularAO, saturate(uEngineAOOcclusion) * step(0.5, uEngineInputs.y));
}

float BrtcEnvironmentGate(float gate, float screenWeight)
{
    return lerp(gate, 1.0, saturate(screenWeight));
}

#endif
