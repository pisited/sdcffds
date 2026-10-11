// Full-scene geometry query shared with GI; old v001 remains a fallback.
#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(prepassTex,0);
uniform_sampler2D(prepassDepthTex,1);
uniform_sampler2D(meshDataTex,2);
cbuffer perDraw:register(b0)
{
    uniform float3 eyePosWorld;
    uniform float3 sunDirection;
    #include "beamrtMeshBVHUniforms.h.hlsl"
    uniform float meshSunSign;
    uniform float meshBindingView;
    uniform float meshMaxDistance;
    uniform float meshTestLightEnabled;
    uniform float3 meshTestLightPosition;
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
    bool srgb;if(!beamrtMeshDataValid(srgb))return float4(0,-1,0,1);
    if(meshBindingView>.5)return float4(0,1,srgb?.5:1,1);
    float4 receiver=decodeGBuffer(TEX_SAMPLER(prepassDepthTex),TEX_SAMPLER(prepassTex),IN.uv0,projParams);
    if(receiver.w>=.9999)return float4(0,0,0,0);
    float3 world=eyePosWorld+IN.wsEyeRay*receiver.w;
    float3 light=meshTestLightEnabled>.5?meshTestLightPosition-world:sunDirection*meshSunSign;
    float lengthSquared=dot(light,light);if(lengthSquared<1e-8)return float4(0,0,0,1);
    light*=rsqrt(lengthSquared);if(dot(receiver.xyz,light)<=.001)return float4(0,0,0,1);
    float reach=meshTestLightEnabled>.5?min(meshMaxDistance,sqrt(lengthSquared)-.04):meshMaxDistance;
    uint visits;int category=beamrtMeshTrace(world+receiver.xyz*.035,light,reach,.05,visits);
    if(category==-1)return float4(0,-1,0,1);
    return float4(max(category,0),category==-2?0:1,(float)visits/max(meshNodeCount,1),1);
}
PFXVertToPix mainV(PFXVert IN){return processPostFxVert(IN);}
