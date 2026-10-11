// v0.023 consumes the signed, confidence-premultiplied delta produced by the
// v0.021 trace.  It uses BeamNG's live RT1 specular/F0 with unmodified Schlick
// Fresnel and a squared roughness response.  No artificial dielectric boost is
// applied, and low-confidence hits can no longer darken the whole base pixel.
#define BEAMRT_MATERIAL_FRESNEL 1
#include "beamrtReflectionCompose.h.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float4 baseEncoded = tex2D(backBufferTex, IN.uv0);
    float4 reflection = tex2D(temporalReflectionTex, IN.uv1);
    if (reflectionStrength <= 0.0 || abs(reflection.a) <= 0.000001)
    {
        return baseEncoded;
    }

    float4 packedPrepass = tex2D(prepassTex, IN.uv2);
    float3 normal = decodeNormalXY(packedPrepass.xy);
    float roughness = max(packedPrepass.b, 0.02);
    float roughnessRange = max(reflectionMaxRoughness - 0.02, 0.001);
    float gloss = saturate((reflectionMaxRoughness - roughness) / roughnessRange);
    gloss *= gloss;
    if (gloss <= 0.0001)
    {
        return baseEncoded;
    }

    float3 toEye = normalize(-IN.wsEyeRay);
    float nDotV = saturate(dot(normal, toEye));
    float3 specularF0 = saturate(tex2D(materialSpecTex, IN.uv3).rgb);
    float grazingFactor = pow(1.0 - nDotV, 5.0);
    float3 fresnel = specularF0 + (1.0 - specularF0) * grazingFactor;
    float3 response = saturate(
        gloss * fresnel * clamp(reflectionStrength, 0.0, 2.0));

    float3 baseLinear = hdrDecode(baseEncoded.rgb);
    float3 composed = max(baseLinear + reflection.rgb * response, 0.0);
    return float4(hdrEncode(composed), baseEncoded.a);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
