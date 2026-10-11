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
    gloss *= gloss;

    float3 toEye = normalize(-IN.wsEyeRay);
    float nDotV = saturate(dot(normal, toEye));
    float fresnel = 0.04 + 0.96 * pow(1.0 - nDotV, 5.0);
    float response = gloss * lerp(0.22, 1.0, fresnel) * saturate(reflectionStrength);

    float3 baseLinear = hdrDecode(baseEncoded.rgb);
    float3 reflectedLinear = max(reflection.rgb, 0.0);
    float3 composed = lerp(baseLinear, reflectedLinear, saturate(response));
    return float4(hdrEncode(composed), baseEncoded.a);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
