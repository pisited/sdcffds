// Isolated compute diagnostic. Full float triangles, no depth/color buffer,
// quantized BVH, material opacity, DXR or game-resource bindings.
struct Triangle { float3 a; uint owner; float3 b; uint reference; float3 c; uint reserved; };
struct Ray { float3 origin; float reach; float3 direction; uint excludedOwner; };
struct Hit { uint owner; uint reference; float distance; uint state; };
StructuredBuffer<Triangle> triangles : register(t0);
StructuredBuffer<Ray> rays : register(t1);
RWStructuredBuffer<Hit> hits : register(u0);
cbuffer Counts : register(b0) { uint triangleCount; uint rayCount; };
[numthreads(64,1,1)]
void main(uint3 id : SV_DispatchThreadID)
{
    if (id.x>=rayCount) return;
    Ray ray=rays[id.x];
    Hit best; best.owner=0xffffffff; best.reference=0xffffffff; best.distance=0; best.state=0;
    [loop] for (uint i=0;i<triangleCount;++i)
    {
        Triangle tri=triangles[i];
        if (tri.owner==ray.excludedOwner) continue;
        precise float3 e1=tri.b-tri.a, e2=tri.c-tri.a;
        precise float3 p=cross(ray.direction,e2);
        precise float determinant=dot(e1,p);
        if (abs(determinant)<1e-7) continue;
        precise float inverse=1.0/determinant;
        precise float3 t=ray.origin-tri.a;
        precise float u=dot(t,p)*inverse;
        if (u<0 || u>1) continue;
        precise float3 q=cross(t,e1);
        precise float v=dot(ray.direction,q)*inverse;
        if (v<0 || u+v>1) continue;
        precise float distance=dot(e2,q)*inverse;
        if (distance<=.08 || distance>=ray.reach-.08) continue;
        if (best.state==0 || distance<best.distance || (distance==best.distance && tri.reference<best.reference))
        {
            best.owner=tri.owner; best.reference=tri.reference;
            best.distance=distance; best.state=1;
        }
    }
    hits[id.x]=best;
}
