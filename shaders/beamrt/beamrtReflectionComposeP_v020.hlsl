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
    if (reflectionStrength <= 0.0 || reflection.a < 1.5)
    {
        return baseEncoded;
    }

    float4 packedPrepass = tex2D(prepassTex, IN.uv2);
    float3 normal = decodeNormalXY(packedPrepass.xy);
    float roughness = max(packedPrepass.b, 0.02);
    float roughnessRange = max(reflectionMaxRoughness - 0.02, 0.001);
    float gloss = saturate((reflectionMaxRoughness - roughness) / roughnessRange);
#ifdef BEAMRT_VISIBLE_SSR
    // Preserve a useful mid-roughness response. Squaring this term made the
    // already-small dielectric Fresnel contribution nearly disappear.
    gloss = pow(gloss, 1.25);
#else
    gloss *= gloss;
#endif

    float3 toEye = normalize(-IN.wsEyeRay);
    float nDotV = saturate(dot(normal, toEye));
    float3 baseLinear = hdrDecode(baseEncoded.rgb);
    float3 reflectedLinear = max(reflection.rgb, 0.0);
#ifdef BEAMRT_MATERIAL_FRESNEL
    // RT1 contains BeamNG's material specular/F0. Use its actual Schlick
    // response instead of the old 22% minimum blend that made every smooth
    // dielectric look coated in chrome.
    float3 specularF0 = saturate(tex2D(materialSpecTex, IN.uv2).rgb);
    float grazingFactor = pow(1.0 - nDotV, 5.0);
    float3 fresnel = specularF0 + (1.0 - specularF0) * grazingFactor;
#ifdef BEAMRT_VISIBLE_SSR
    // A display-space visibility curve makes a 4% dielectric F0 perceptible
    // after roughness and hit-confidence attenuation without restoring the old
    // unconditional 22% minimum. Metals and grazing angles remain stronger.
    fresnel = 1.0 - exp(-fresnel * 3.0);
#endif
    float3 response = saturate(
        gloss * fresnel * clamp(reflectionStrength, 0.0, 2.0));
    float3 composed = lerp(baseLinear, reflectedLinear, response);
#else
    float fresnel = 0.04 + 0.96 * pow(1.0 - nDotV, 5.0);
    float response = gloss * lerp(0.22, 1.0, fresnel) * saturate(reflectionStrength);
    float3 composed = lerp(baseLinear, reflectedLinear, saturate(response));
#endif
    return float4(hdrEncode(composed), baseEncoded.a);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
