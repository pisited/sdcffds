// Offline GPU fixture uses the EXACT consumer predicate included by GI v084.
// It is not a substitute for executing the complete BeamNG GI draw in game.
Texture2D<float4> nativeGIVisibilityTexTex : register(t5);
cbuffer Test : register(b0) {
    float4 nativeGIVisibilityKey;
    float2 nativeGIVisibilitySize;
    float nativeGIVisibilityEnabled;
    int surfelIndex;
    float4 rtParams0;
};
#include "shaders/beamrt/beamrtNativeGIVisibility_v001.h.hlsl"
// Match the full engine PostFX input signature, including unused semantics.
struct V { float4 position:SV_Position;float2 uv:TEXCOORD0;
    float2 uv1:TEXCOORD1;float2 uv2:TEXCOORD2;float2 uv3:TEXCOORD3;float3 eye:TEXCOORD4; };
V mainV(uint index:SV_VertexID) {
    V v;v.uv=float2((index<<1)&2,index&2);
    v.uv1=v.uv2=v.uv3=v.uv;v.eye=float3(0,0,1);
    v.position=float4(v.uv*float2(2,-2)+float2(-1,1),0,1);return v;
}
float4 mainP(V v):SV_Target0 {
    // Screen contribution must survive; reject only the selected world bounce.
    float3 screen=float3(.2,.3,.4),world=float3(1,2,3);
    bool blocked=beamrtNativeGIBlocked(v.uv*rtParams0.zw+rtParams0.xy,surfelIndex);
    return float4(screen+(blocked?0.0:world),1);
}
