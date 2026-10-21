// Prepare the unchanged receiver reflectance, tint, F0 and roughness response
// while every source fits within BeamNG PostEffect's six texture inputs.
// Store linear response in RGB and scalar pre-gate reflectance in alpha.
#include "shaders/common/postFx/postFx.h.hlsl"
#ifdef BEAMRT_DELIT_RECEIVER
#include "beamrtReceiverColor.h.hlsl"
#endif

uniform_sampler2D(backBufferTex, 0);
uniform_sampler2D(prepassTex, 1);
uniform_sampler2D(receiverLightInfoTex, 2);
uniform_sampler2D(receiverMaterialSpecTex, 3);
uniform_sampler2D(prepassDepthTex, 4);

cbuffer perDraw : register(b0)
{
    uniform float giReceiverTint;
#ifdef BEAMRT_DELIT_RECEIVER
    uniform float giReceiverDeLight;
#endif
    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    // Depth shares the native prepass viewport transform with its normal target.
    float4 centerDecoded = decodeGBuffer(
        TEX_SAMPLER(prepassDepthTex),
        TEX_SAMPLER(prepassTex),
        IN.uv1,
        projParams
    );
    if (centerDecoded.w >= 0.9999)
    {
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    const float3 luminanceWeights = float3(0.2126, 0.7152, 0.0722);
    float3 baseLinear = hdrDecode(tex2D(backBufferTex, IN.uv0).rgb);
    float baseLuminance = dot(baseLinear, luminanceWeights);
    float3 receiverDirectLighting = max(tex2D(receiverLightInfoTex, IN.uv2).rgb, 0.0);
    float receiverDirectLuminance = dot(receiverDirectLighting, luminanceWeights);
    float receiverDisplayReflectance = saturate(baseLuminance / (baseLuminance + 0.25));
    float receiverDirectReflectance = saturate(
        baseLuminance / max(receiverDirectLuminance + 0.05, 0.05));
    float directEstimateConfidence = smoothstep(0.05, 0.50, receiverDirectLuminance);
    float approximateReflectance = lerp(
        receiverDisplayReflectance, receiverDirectReflectance, directEstimateConfidence);

    float receiverPeak = max(max(baseLinear.r, baseLinear.g), baseLinear.b);
    float3 receiverChroma = receiverPeak > 0.0001
        ? saturate(baseLinear / receiverPeak)
        : float3(1.0, 1.0, 1.0);
    float chromaConfidence = saturate(receiverPeak * 4.0);
    float3 receiverResponse = lerp(
        approximateReflectance.xxx,
        receiverChroma * approximateReflectance,
        saturate(giReceiverTint) * chromaConfidence);
#ifdef BEAMRT_DELIT_RECEIVER
    float3 delitResponse = approximateReflectance * lerp(
        float3(1.0, 1.0, 1.0),
        beamrtDelitReceiverChroma(baseLinear, receiverDirectLighting),
        saturate(giReceiverTint));
    receiverResponse = lerp(receiverResponse, delitResponse, saturate(giReceiverDeLight));
#endif

    float3 receiverSpecularF0 = saturate(tex2D(receiverMaterialSpecTex, IN.uv3).rgb);
    float receiverSpecularPeak = max(
        max(receiverSpecularF0.r, receiverSpecularF0.g), receiverSpecularF0.b);
    float metallicLikelihood = smoothstep(0.08, 0.24, receiverSpecularPeak);
    receiverResponse = max(
        receiverResponse * (1.0 - metallicLikelihood),
        float3(0.01, 0.01, 0.01));

    float receiverRoughness = saturate(tex2D(prepassTex, IN.uv1).b);
    float diffuseReceiverWeight = lerp(0.18, 1.0, pow(receiverRoughness, 0.75));
    return float4(receiverResponse * diffuseReceiverWeight, approximateReflectance);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
