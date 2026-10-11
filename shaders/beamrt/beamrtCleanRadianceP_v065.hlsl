// BeamRT v0.065 material/emitter diagnostics. The live clean source remains
// direct diffuse + native material emissive so v0.059 behavior is preserved.
#include "beamrtCleanRadiance_v065.h.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float beamrtLuminance(float3 c)
{
    return dot(max(c, 0.0), float3(0.2126, 0.7152, 0.0722));
}

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float sceneNdcDepth = tex2D(prepassDepthTex, IN.uv0).r;
    float sceneRealDepth = ndcToRealDepth(sceneNdcDepth, projParams.zw);
    float sceneEyeDepth = realToEyeLinearDepth(sceneRealDepth, projParams);
    float validSurface = sceneEyeDepth < 0.9999 ? 1.0 : 0.0;

    float3 baseColor = max(tex2D(baseColorCacheTex, IN.uv1).rgb, 0.0);
    float metallic = saturate(tex2D(metallicCacheTex, IN.uv2).r);
    float3 directLighting = max(tex2D(lightInfoTex, IN.uv3).rgb, 0.0);
    float3 emissive = max(tex2D(emissiveCacheTex, IN.uv1).rgb, 0.0);

    float3 diffuseAlbedo = baseColor * (1.0 - metallic) * validSurface;
    float3 directDiffuseRadiance = diffuseAlbedo * directLighting;
    float3 maskedEmissive = emissive * validSurface;
    float3 cleanRadiance = directDiffuseRadiance + maskedEmissive;

    float3 outputValue = diffuseAlbedo;
    if (outputMode > 3.5)
    {
        // Red = native material emission dominates outgoing radiance.
        // Green = direct-lit diffuse reflection dominates. Yellow = both.
        // This intentionally normalizes away absolute brightness so a tiny
        // fluorescent emitter can be distinguished from a large lit surface.
        float emissiveLum = beamrtLuminance(maskedEmissive);
        float diffuseLum = beamrtLuminance(directDiffuseRadiance);
        float totalLum = max(emissiveLum + diffuseLum, 0.000001);
        outputValue = float3(emissiveLum / totalLum, diffuseLum / totalLum, 0.0) * validSurface;
    }
    else if (outputMode > 2.5)
    {
        outputValue = cleanRadiance;
    }
    else if (outputMode > 1.5)
    {
        outputValue = maskedEmissive;
    }
    else if (outputMode > 0.5)
    {
        outputValue = directDiffuseRadiance;
    }

    return float4(outputValue, validSurface);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
