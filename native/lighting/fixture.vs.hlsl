// OFFLINE receiver geometry for the actual GI/reflection history shaders.
struct V { float4 hpos:SV_Position;float2 uv0:TEXCOORD0;float2 uv1:TEXCOORD1;
    float2 uv2:TEXCOORD2;float2 uv3:TEXCOORD3;float3 eye:TEXCOORD4; };
V main(uint index:SV_VertexID){
    V v;v.uv0=float2((index<<1)&2,index&2);v.uv1=v.uv2=v.uv3=v.uv0;
    v.eye=float3(0,0,-10);v.hpos=float4(v.uv0*float2(2,-2)+float2(-1,1),0,1);return v;
}
