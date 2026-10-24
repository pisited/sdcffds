#include "shaders/beamrt/beamrtWaterReceiver.h.hlsl"
cbuffer perDraw : register(b0)
{
    float3 fixtureEye;
    float3 fixtureRay;
    float3 fixtureOpaque;
    float fixtureOpaqueValid;
    float fixtureOutput;
    float4 waterReceiverPlane;
    float4 waterReceiverBlockMin;
    float4 waterReceiverBlockMax;
    float waterReceiverMaxDistance;
};
struct V { float4 hpos:SV_Position;float2 uv0:TEXCOORD0;float2 uv1:TEXCOORD1;
    float2 uv2:TEXCOORD2;float2 uv3:TEXCOORD3;float3 eye:TEXCOORD4; };
V mainV(uint index:SV_VertexID)
{
    V v;v.uv0=float2((index<<1)&2,index&2);v.uv1=v.uv2=v.uv3=v.uv0;
    v.eye=float3(v.uv0*2-1,-10);
    v.hpos=float4(v.uv0*float2(2,-2)+float2(-1,1),0,1);return v;
}
float4 mainP(V IN):SV_Target0
{
    float3 position,normal;float distance,kind;
    bool hit=beamrtWaterReceiverCandidate(fixtureEye,fixtureRay,fixtureOpaque,
        fixtureOpaqueValid>0.5,waterReceiverPlane,waterReceiverBlockMin,
        waterReceiverBlockMax,waterReceiverMaxDistance,position,normal,distance,kind);
    if(!hit)return 0;
    return fixtureOutput>0.5?float4(normal,distance):float4(position,kind);
}
