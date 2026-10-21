// Diagnostic geometry preview, never a water-reflection or lighting override.
#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(sceneTex, 0);
uniform_sampler2D(prepassDepthTex, 1);
cbuffer perDraw : register(b0)
{
    uniform float waterReceiverPreviewEnabled;
    uniform float4 waterReceiverPlane;
    uniform float4 waterReceiverBlockMin;
    uniform float4 waterReceiverBlockMax;
    uniform float waterReceiverMaxDistance;
    uniform float3 eyePosWorld;
    POSTFX_UNIFORMS
};
#include "shaders/common/postFx/postFx.hlsl"
#include "beamrtWaterReceiver.h.hlsl"
#ifdef SHADER_STAGE_VS
#define mainV main
#else
#define mainP main
#endif
float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float4 scene = tex2D(sceneTex, IN.uv0);
    if (waterReceiverPreviewEnabled <= 0.5) return scene;
    float ndc = tex2D(prepassDepthTex, IN.uv1).r;
    if (!beamrtWaterFinite3(float3(ndc, projParams.w, 0.0))
        || !beamrtWaterFinite3(projParams.xyz)
        || projParams.x <= 0.0 || projParams.y <= projParams.x) return scene;
    float denominator = ndc - projParams.z;
    float realDepth = abs(denominator) > 0.00000001 ? projParams.w / denominator : projParams.y;
    if (!beamrtWaterFinite3(float3(realDepth, 0, 0)) || realDepth <= 0.0) return scene;
    bool opaqueValid = realDepth < projParams.y * 0.9999;
    float3 opaqueWorld = eyePosWorld + IN.wsEyeRay * (realDepth / projParams.y);
    float3 position, normal; float distance, kind;
    bool candidate = beamrtWaterReceiverCandidate(eyePosWorld, IN.wsEyeRay,
        opaqueWorld, opaqueValid, waterReceiverPlane, waterReceiverBlockMin,
        waterReceiverBlockMax, waterReceiverMaxDistance, position, normal, distance, kind);
    if (!candidate) return scene;
    float3 tint = kind > 1.5 ? float3(0.1, 0.4, 1.0) : float3(0.0, 0.8, 0.8);
    return float4(lerp(scene.rgb, tint, 0.65), scene.a);
}
PFXVertToPix mainV(PFXVert IN) { return processPostFxVert(IN); }
