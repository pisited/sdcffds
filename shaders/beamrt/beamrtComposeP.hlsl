#include "beamrtCompose.h.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float4 baseEncoded = tex2D(backBufferTex, IN.uv0);
    if (giStrength <= 0.0)
    {
        return baseEncoded;
    }

    float3 baseLinear = hdrDecode(baseEncoded.rgb);
    float3 accumulatedGI = max(tex2D(temporalGITex, IN.uv1).rgb, 0.0);
    return float4(hdrEncode(baseLinear + accumulatedGI * giStrength), baseEncoded.a);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
