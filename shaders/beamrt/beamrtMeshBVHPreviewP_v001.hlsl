#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(backBufferTex,0);
uniform_sampler2D(meshVisibilityTex,1);
cbuffer perDraw:register(b0){uniform float meshPreviewView;uniform float meshSplit;POSTFX_UNIFORMS};
#include "shaders/common/postFx/postFx.hlsl"
#ifdef SHADER_STAGE_VS
#define mainV main
#else
#define mainP main
#endif
float4 mainP(PFXVertToPix IN):SV_Target0
{
    float4 scene=tex2D(backBufferTex,IN.uv0),data=tex2D(meshVisibilityTex,IN.uv1);
    float u=(IN.uv0.x-rtParams0.x)/rtParams0.z;
    if(meshSplit>.5&&u<.5)return scene;
    if(data.g<-.5)return float4(hdrEncode(float3(10,0,10)),1); // invalid DATA, never a silent miss
    if(meshPreviewView>.5)return float4(hdrEncode(float3(0,data.g,data.b)),1); // binding proof
    if(data.a<.5)return scene;
    float3 color=data.r>1.5?float3(1,.15,.05):data.r>.5?float3(1,.55,.05):
        data.g>.5?float3(.04,.35,.08):float3(.2,.15,.3);
    return float4(hdrEncode(color),1);
}
PFXVertToPix mainV(PFXVert IN){return processPostFxVert(IN);}
