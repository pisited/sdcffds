// Owned fixture pass for binding interception, not an additional tracer.
Texture2D<float4> first : register(t0);
Texture2D<float4> second : register(t1);
StructuredBuffer<float4> lights : register(t2);
RWStructuredBuffer<float4> result : register(u0);
cbuffer FixtureConstants : register(b0) { float fixtureRootValue; };
struct V { float4 position:SV_Position; };
V mainV(uint id:SV_VertexID) { V v;float2 p=float2((id<<1)&2,id&2);v.position=float4(p*float2(2,-2)+float2(-1,1),0,1);return v; }
float4 mainP(V v):SV_Target0 { return first.Load(int3(0,0,0))+second.Load(int3(0,0,0))+.25*lights[0]+fixtureRootValue; }
[numthreads(1,1,1)]
void mainC(uint3 id:SV_DispatchThreadID) { result[id.x]=first.Load(int3(0,0,0))+second.Load(int3(0,0,0))+.25*lights[0]; }
