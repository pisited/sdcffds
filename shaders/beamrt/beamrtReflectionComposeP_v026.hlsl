// v0.026 conservatively augments the native beauty with weighted SSR radiance.
// The native environment-specular lobe is not independently available: retain
// it on misses, preserve all base lighting, and do not call this replacement.
// A future lobe-replacement path needs a matched same-frame native spec buffer.
#define BEAMRT_MATERIAL_FRESNEL 1
#include "beamrtReflectionCompose.h.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float4 mainP(PFXVertToPix IN) : SV_Target0
{
        //magenta thung
     return float4(
     hdrEncode(float3(10.0, 0.0, 10.0)),
    1.0
);

#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
    int diagnosticMode = (int)clamp(reflectionDebugMode, 0.0, 9.0);
    bool diagnosticContribution = diagnosticMode == 6;
    if (diagnosticMode > 0 && !diagnosticContribution)
    {
        // Lua binds raw CurrentReflection for every diagnostic. The state/UV
        // and raw-colour RGB already contains the intended display values.
        return tex2D(temporalReflectionTex, IN.uv1);
    }
    float4 baseEncoded = 0.0;
    if (!diagnosticContribution)
        baseEncoded = tex2D(backBufferTex, IN.uv0);
#else
    float4 baseEncoded = tex2D(backBufferTex, IN.uv0);
#endif
    float4 reflection = tex2D(temporalReflectionTex, IN.uv1);
    if (reflectionStrength <= 0.0 || abs(reflection.a) <= 0.000001)
    {
#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
        if (diagnosticContribution)
            return float4(0.0, 0.0, 0.0, 1.0);
#endif
        return baseEncoded;
    }

    float3 response;
#ifdef BEAMRT_REFLECTION_GGX
    if (reflectionSamplingMode > 0.5)
    {
        // GGX trace already supplies Fresnel * BRDF*NdotL/pdf. Multiplying a
        // second Fresnel or the legacy gloss cutoff would double-weight it.
        response = clamp(reflectionStrength, 0.0, 2.0).xxx;
    }
    else
#endif
    {
    float4 packedPrepass = tex2D(prepassTex, IN.uv2);
    float3 normal = decodeNormalXY(packedPrepass.xy);
    float roughness = max(packedPrepass.b, 0.02);
    float roughnessRange = max(reflectionMaxRoughness - 0.02, 0.001);
    float gloss = saturate((reflectionMaxRoughness - roughness) / roughnessRange);
    gloss *= gloss;
    if (gloss <= 0.0001)
    {
#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
        if (diagnosticContribution)
            return float4(0.0, 0.0, 0.0, 1.0);
#endif
        return baseEncoded;
    }

    float3 toEye = normalize(-IN.wsEyeRay);
    float nDotV = saturate(dot(normal, toEye));
    float3 specularF0 = saturate(tex2D(materialSpecTex, IN.uv3).rgb);
    float grazingFactor = pow(1.0 - nDotV, 5.0);
    float3 fresnel = specularF0 + (1.0 - specularF0) * grazingFactor;
    response = saturate(
        gloss * fresnel * clamp(reflectionStrength, 0.0, 2.0));
    }

#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
    if (diagnosticContribution)
    {
        // This is the existing confidence-premultiplied receiver SSR term,
        // before base addition, with the original receiver UV2/UV3 material.
        // Use normal HDR encoding and add no diagnostic exposure/gain.
        return float4(hdrEncode(max(reflection.rgb, 0.0) * response), 1.0);
    }
#endif
    float3 baseLinear = hdrDecode(baseEncoded.rgb);
    float3 composed = max(baseLinear + max(reflection.rgb, 0.0) * response, 0.0);
    return float4(hdrEncode(composed), baseEncoded.a);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
