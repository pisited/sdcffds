Texture2D<float4> sources[6] : register(t0);
SamplerState filters[6] : register(s0);
cbuffer Fixture : register(b0) {float4 bias;};
struct V {float4 position:SV_Position;};
V mainV(uint id:SV_VertexID){V v;float2 p=float2((id<<1)&2,id&2);v.position=float4(p*float2(2,-2)+float2(-1,1),0,1);return v;}
float4 mainP(V v):SV_Target0 {
    float4 color=bias;
    [unroll] for(uint i=0;i<6;++i)color+=sources[i].SampleLevel(filters[i],float2(.5,.5),0);
    return color;
}
