#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(velocityTex, 0);
uniform_sampler2D(historyHitTex, 1);
cbuffer perDraw : register(b0)
{
    uniform float reflectionHistoryValid;
    uniform float reflectionHitAwareEnabled;
    uniform float2 reflectionReceiverSize;
    POSTFX_UNIFORMS
};
#include "shaders/common/postFx/postFx.hlsl"
#include "beamrtReflectionHitPacking.h.hlsl"
#include "beamrtReflectionReceiverHistory.h.hlsl"
#ifdef SHADER_STAGE_VS
#define mainV main
#else
#define mainP main
#endif

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    if (!beamrtReceiverLogicalSizeValid(reflectionReceiverSize)) return 0.0;
    int2 logicalSize = int2(reflectionReceiverSize);
    int2 outputPixel = int2(floor(IN.hpos.xy));
    if (any(outputPixel < 0) || outputPixel.x >= logicalSize.x
        || outputPixel.y >= logicalSize.y * 2) return 0.0;
    bool descriptorPlane = outputPixel.y >= logicalSize.y;
    int2 pixel = int2(outputPixel.x, descriptorPlane ? outputPixel.y - logicalSize.y : outputPixel.y);
    float2 receiverUV = (float2(pixel) + 0.5) / float2(logicalSize);
    uint historyWidth, historyHeight;
    historyHitTexTex.GetDimensions(historyWidth, historyHeight);
    bool previousLayoutValid = historyWidth == uint(logicalSize.x)
        && historyHeight == uint(logicalSize.y * 2);
    bool historyValid = reflectionHitAwareEnabled > 0.5
        && reflectionHistoryValid > 0.5 && previousLayoutValid;

    if (descriptorPlane)
    {
        if (!historyValid) return 0.0;
        // Keep the OLD grid here. Reprojection belongs to each independent
        // color-history tap, not this early snapshot/copy pass.
        float4 descriptor = historyHitTexTex.Load(int3(pixel + int2(0, logicalSize.y), 0));
        return beamrtReceiverDescriptorValid(descriptor) ? descriptor : 0.0;
    }

    float2 velocity = tex2D(velocityTex, viewportCoordToRenderTarget(receiverUV, rtParams0)).xy;
    if (!historyValid) return float4(velocity, 0.0, 0.0);
    float2 previousUV = receiverUV + velocity;
    if (any(previousUV < 0.0) || any(previousUV > 1.0)) return float4(velocity, 0.0, 0.0);
    int2 previousPixel = clamp(int2(previousUV * logicalSize), int2(0, 0), logicalSize - 1);
    float4 hit = historyHitTexTex.Load(int3(previousPixel, 0));
    bool valid = beamrtReceiverFinite4(hit)
        && hit.z > 0.0 && hit.z < projParams.y * 0.9999
        && all(hit.xy >= 0.0) && all(hit.xy <= 1.0);
    return float4(velocity, valid ? beamrtPackHitUV(hit.xy) : 0.0, valid ? hit.z : 0.0);
}

PFXVertToPix mainV(PFXVert IN) { return processPostFxVert(IN); }
