// BeamRT v0.059 material-aware source diagnostic. This shader deliberately
// writes linear intermediate values and is not connected to the live PTGI path.
#include "beamrtCleanRadiance_v059.h.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float sceneNdcDepth = tex2D(prepassDepthTex, IN.uv0).r;
    float sceneRealDepth = ndcToRealDepth(sceneNdcDepth, projParams.zw);
    float sceneEyeDepth = realToEyeLinearDepth(sceneRealDepth, projParams);
    float validSurface = sceneEyeDepth < 0.9999 ? 1.0 : 0.0;

    // BeamNG's Material Debug path returns material.baseColor, metallic, and
    // material.emissive directly. The ordinary material path uses the same
    // linear material values before hdrEncode(finalColor), so no guessed gamma
    // or HDR conditioning belongs in these intermediate calculations.
    float3 baseColor = max(tex2D(baseColorCacheTex, IN.uv1).rgb, 0.0);
    float metallic = saturate(tex2D(metallicCacheTex, IN.uv2).r);
    float3 directLighting = max(tex2D(lightInfoTex, IN.uv3).rgb, 0.0);
    float3 emissive = max(tex2D(emissiveCacheTex, IN.uv1).rgb, 0.0);

    float3 diffuseAlbedo = baseColor * (1.0 - metallic) * validSurface;
    float3 directDiffuseRadiance = diffuseAlbedo * directLighting;
    float3 maskedEmissive = emissive * validSurface;
    float3 cleanRadiance = directDiffuseRadiance + maskedEmissive;

    float3 outputValue = diffuseAlbedo;
    if (outputMode > 2.5)
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
