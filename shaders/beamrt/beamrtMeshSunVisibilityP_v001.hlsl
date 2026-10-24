// Deterministic full-resolution sunlight visibility, before AL_LightBin.
// XYZ identifies the receiver; W=2 only for a definite opaque blocker.
// W=1 valid receiver without definite blocker; W=0 invalid/missing trace.
#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(prepassTex,0);
uniform_sampler2D(prepassDepthTex,1);
uniform_sampler2D(meshDataTex,2);
cbuffer perDraw:register(b0)
{
    uniform float3 eyePosWorld;
    uniform float3 sunDirection;
    uniform float meshSunSign;
    #include "beamrtMeshBVHUniforms.h.hlsl"
    POSTFX_UNIFORMS
};
#include "shaders/common/postFx/postFx.hlsl"
#include "beamrtMeshBVHCommon.h.hlsl"
#ifdef SHADER_STAGE_VS
#define mainV main
#else
#define mainP main
#endif
float4 mainP(PFXVertToPix IN):SV_Target0
{
    float4 receiver=decodeGBuffer(TEX_SAMPLER(prepassDepthTex),TEX_SAMPLER(prepassTex),IN.uv0,projParams);
    // Invalid depth/normals/toggles cannot certify either clear or blocked sun.
    if(!all(isfinite(receiver)) || receiver.w<=0 || receiver.w>=.9999
        || !isfinite(meshVisibilityEnabled) || meshVisibilityEnabled<.5)return float4(0,0,0,0);
    float3 world=eyePosWorld+IN.wsEyeRay*receiver.w;
    if(!all(isfinite(world)))return float4(0,0,0,0);
    float3 towardSun=sunDirection*meshSunSign;
    float magnitude=dot(towardSun,towardSun);
    if(!all(isfinite(towardSun)) || !isfinite(magnitude) || magnitude<1e-8)return float4(world,0);
    towardSun*=rsqrt(magnitude);
    if(dot(receiver.xyz,towardSun)<=.001)return float4(world,1);
    uint visits;
    int hit=beamrtMeshTrace(world+receiver.xyz*.035,towardSun,200,.05,visits);
    return float4(world,hit<0?0:(hit==2?2:1));
}
PFXVertToPix mainV(PFXVert IN){return processPostFxVert(IN);}
