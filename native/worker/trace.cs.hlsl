// Reuse BeamRT's exact packed-BVH traversal. No game include or ReShade API.
Texture2D<float4> meshDataTexTex : register(t0);
struct Ray { float3 origin; float reach; float3 direction; float startBias; };
StructuredBuffer<Ray> rays : register(t1);
RWStructuredBuffer<int2> results : register(u0);
cbuffer Scene : register(b0) {
    float4 origin, inverseX, inverseY, inverseZ, quantMin, quantExtent;
    uint4 counts, atlas;
    uint4 materials[4];
};
cbuffer Batch : register(b1) { uint rayCount; };
#define meshOrigin origin.xyz
#define meshInvX inverseX.xyz
#define meshInvY inverseY.xyz
#define meshInvZ inverseZ.xyz
#define meshQuantMin quantMin.xyz
#define meshQuantExtent quantExtent.xyz
#define meshNodeCount float(counts.x)
#define meshTriangleCount float(counts.y)
#define meshTriangleOffset float(counts.z)
#define meshAtlasSize float2(atlas.xy)
#define meshMaterialPolicyEnabled 1.0
#define meshMaterialModes0 float4(materials[0])
#define meshMaterialModes1 float4(materials[1])
#define meshMaterialModes2 float4(materials[2])
#define meshMaterialModes3 float4(materials[3])
#define meshVisibilityEnabled 1.0
#include "shaders/beamrt/beamrtMeshBVHCommon.h.hlsl"
[numthreads(64,1,1)]
void main(uint3 id : SV_DispatchThreadID) {
    if (id.x >= rayCount) return;
    Ray ray = rays[id.x]; uint visits;
    int category = beamrtMeshTrace(ray.origin, ray.direction, ray.reach, ray.startBias, visits);
    results[id.x] = int2(category, (int)visits);
}
