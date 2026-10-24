#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(currentReflectionTex, 0);
uniform_sampler2D(prepassDepthTex, 1);
uniform_sampler2D(hitInputsTex, 2);
uniform_sampler2D(temporalReflectionTex, 3);
uniform_sampler2D(prepassTex, 4);
uniform_sampler2D(materialSpecTex, 5);
cbuffer perDraw : register(b0)
{
    uniform float reflectionHistoryValid;
    uniform float reflectionCameraMotion;
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
    // Uniform invalid-size rejection precedes all pixel-varying branches.
    if (!beamrtReceiverLogicalSizeValid(reflectionReceiverSize)) return 0.0;
    int2 logicalSize = int2(reflectionReceiverSize);
    int2 outputPixel = int2(floor(IN.hpos.xy));
    int2 pixel = int2(outputPixel.x,
        outputPixel.y >= logicalSize.y ? outputPixel.y - logicalSize.y : outputPixel.y);
    float2 receiverUV = (float2(pixel) + 0.5) / float2(logicalSize);

    // This output is twice the view height, so its interpolated eye ray spans
    // the view over TWO planes. Recover the ray for the logical receiver.
    // Derivatives are evaluated uniformly before plane and hit/miss branches.
    float2 originalUV = (IN.uv0 - rtParams0.xy) / rtParams0.zw;
    float3 originalEyeDx = ddx(IN.wsEyeRay), originalEyeDy = ddy(IN.wsEyeRay);
    float2 originalStep = float2(ddx(originalUV.x), ddy(originalUV.y));
    bool rayStepsValid = abs(originalStep.x) > 0.00000001 && abs(originalStep.y) > 0.00000001;
    float2 safeStep = float2(rayStepsValid ? originalStep.x : 1.0,
        rayStepsValid ? originalStep.y : 1.0);
    float2 rayOffset = (receiverUV - originalUV) / safeStep;
    float3 receiverEyeRay = IN.wsEyeRay + originalEyeDx * rayOffset.x + originalEyeDy * rayOffset.y;
    float2 uvStep = 1.0 / float2(logicalSize);
    float3 eyeDx = originalEyeDx * (uvStep.x / safeStep.x);
    float3 eyeDy = originalEyeDy * (uvStep.y / safeStep.y);

    if (reflectionHitAwareEnabled <= 0.5 || any(outputPixel < 0)
        || outputPixel.x >= logicalSize.x || outputPixel.y >= logicalSize.y * 2) return 0.0;
    float2 receiverDepthUV = viewportCoordToRenderTarget(receiverUV, rtParams1);
    float receiverDepth = ndcToRealDepth(tex2D(prepassDepthTex, receiverDepthUV).r, projParams.zw);
    if (outputPixel.y >= logicalSize.y)
    {
        // Prepass MRTs share the same transform; PostFX supplies only four
        // rtParams, so material slots 4/5 intentionally use the depth mapping.
        float4 prepass = tex2D(prepassTex, receiverDepthUV);
        float3 specular = tex2D(materialSpecTex, receiverDepthUV).rgb;
        return beamrtMakeReceiverDescriptor(prepass, specular, receiverDepth, projParams.y);
    }

    float packed = tex2D(currentReflectionTex, viewportCoordToRenderTarget(receiverUV, rtParams0)).a;
    float2 hitUV = 0.0;
    float hitDepth = 0.0;
    if (beamrtHasHitUV(packed))
    {
        hitUV = beamrtUnpackHitUV(packed);
        hitDepth = ndcToRealDepth(tex2D(prepassDepthTex,
            viewportCoordToRenderTarget(hitUV, rtParams1)).r, projParams.zw);
        if (!(hitDepth > 0.0 && hitDepth < projParams.y * 0.9999)) return 0.0;
    }
    else
    {
        float4 color = tex2D(temporalReflectionTex, viewportCoordToRenderTarget(receiverUV, rtParams3));
        if (reflectionHistoryValid <= 0.5 || reflectionCameraMotion > 0.0001
            || color.a <= 0.0 || max(color.r, max(color.g, color.b)) <= 0.0) return 0.0;
        uint inputsWidth, inputsHeight;
        hitInputsTexTex.GetDimensions(inputsWidth, inputsHeight);
        if (inputsWidth != uint(logicalSize.x) || inputsHeight != uint(logicalSize.y * 2)) return 0.0;
        float4 previous = hitInputsTexTex.Load(int3(pixel, 0));
        if (!beamrtHasHitUV(previous.z) || previous.w <= 0.0) return 0.0;
        hitUV = beamrtUnpackHitUV(previous.z);
        hitDepth = previous.w;
    }
    float distanceToHit = 0.0;
    if (rayStepsValid)
    {
        float2 pixelOffset = (hitUV - receiverUV) / uvStep;
        float3 hitEyeRay = receiverEyeRay + eyeDx * pixelOffset.x + eyeDy * pixelOffset.y;
        distanceToHit = length(hitEyeRay * (hitDepth / projParams.y)
            - receiverEyeRay * (receiverDepth / projParams.y));
    }
    return float4(hitUV, hitDepth, distanceToHit);
}

PFXVertToPix mainV(PFXVert IN) { return processPostFxVert(IN); }
