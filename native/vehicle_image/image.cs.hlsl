// Full frozen-camera primary + ideal geometric mirror queries on an owned BVH.
// No screen depth/color inputs, material radiance or DXR; results are hit records.
struct Triangle { float3 a; uint owner; float3 b; uint reference; float3 c; uint reserved; };
struct Node { float3 low; uint left; float3 high; uint right; uint first; uint count; uint pad0; uint pad1; };
struct Hit { uint owner; uint reference; float distance; uint state; };
struct Pixel { Hit primary; Hit full; Hit excluded; };
StructuredBuffer<Triangle> triangles : register(t0);
StructuredBuffer<Node> nodes : register(t1);
StructuredBuffer<uint> order : register(t2);
RWStructuredBuffer<Pixel> pixels : register(u0);
cbuffer Camera : register(b0) {
    float4 cameraRight; // xyz axis, near
    float4 cameraForward; // xyz axis, native far
    float4 cameraUp; // xyz axis, secondary far
    float4 frustum; // left, right, top, bottom
    uint4 counts; // triangles, nodes, width, height
    uint4 options; // linear reference traversal for self-test ONLY
};
Hit miss() { Hit h;h.owner=0xffffffff;h.reference=0xffffffff;h.distance=0;h.state=0;return h; }
Hit invalid() { Hit h=miss();h.state=2;return h; }
Hit incomplete() { Hit h=miss();h.state=3;return h; }
Hit testTriangle(uint index,float3 origin,float3 direction,float far,uint excluded,Hit best) {
    Triangle tri=triangles[index];if(tri.owner==excluded)return best;
    precise float3 e1=tri.b-tri.a,e2=tri.c-tri.a;
    precise float3 p=cross(direction,e2);precise float determinant=dot(e1,p);
    if(abs(determinant)<1e-7)return best;
    precise float inverse=1.0/determinant;precise float3 t=origin-tri.a;
    precise float u=dot(t,p)*inverse;if(u<0||u>1)return best;
    precise float3 q=cross(t,e1);precise float v=dot(direction,q)*inverse;
    if(v<0||u+v>1)return best;
    precise float distance=dot(e2,q)*inverse;
    if(distance<=.08||distance>=far-.08)return best;
    if(best.state==0||distance<best.distance||(distance==best.distance&&tri.reference<best.reference)) {
        best.owner=tri.owner;best.reference=tri.reference;best.distance=distance;best.state=1;
    }
    return best;
}
bool intersects(Node n,float3 origin,float3 direction,float far) {
    float begin=0,end=far;
    [unroll] for(uint j=0;j<3;++j) {
        float padding=1e-5+max(abs(n.low[j]),abs(n.high[j]))*2e-7;
        float low=n.low[j]-padding,high=n.high[j]+padding;
        if(abs(direction[j])<1e-20) {if(origin[j]<low||origin[j]>high)return false;}
        else {
            precise float a=(low-origin[j])/direction[j],b=(high-origin[j])/direction[j];
            begin=max(begin,min(a,b));end=min(end,max(a,b));if(begin>end)return false;
        }
    }
    return true;
}
Hit trace(float3 origin,float3 direction,float far,uint excluded) {
    Hit best=miss();
#ifdef BEAMRT_GPU_LINEAR_REFERENCE
    { // Separately compiled full scan for isolated host regression only.
        [loop] for(uint i=0;i<counts.x;++i)best=testTriangle(i,origin,direction,far,excluded,best);
        return best;
    }
#else
    uint stack[64];[unroll] for(uint s=0;s<64;++s)stack[s]=0;
    uint size=1,visits=0,triangleTests=0;
    [loop] while(size>0) {
        uint index=stack[--size];if(index>=counts.y||++visits>counts.y)return invalid();
        if(visits>8192)return incomplete();
        Node n=nodes[index];if(!intersects(n,origin,direction,best.state==1?best.distance:far-.08))continue;
        if(n.left==0xffffffff) {
            if(n.count==0||n.first>counts.x||n.count>counts.x-n.first)return invalid();
            [loop] for(uint j=0;j<n.count;++j) {
                uint tri=order[n.first+j];if(tri>=counts.x)return invalid();
                if(++triangleTests>65536)return incomplete();
                best=testTriangle(tri,origin,direction,far,excluded,best);
            }
        } else {
            if(size>61||n.left>=counts.y||n.right>=counts.y)return invalid();
            stack[size++]=n.right;stack[size++]=n.left;
        }
    }
    return best;
#endif
}
[numthreads(8,8,1)]
void main(uint3 id:SV_DispatchThreadID) {
    if(id.x>=counts.z||id.y>=counts.w)return;
#ifdef BEAMRT_GPU_LINEAR_REFERENCE
    if(options.y==1) {
        if(id.x!=0||id.y!=0)return;
        id.xy=uint2(options.z%counts.z,options.z/counts.z);
    }
#endif
    float2 uv=(float2(id.xy)+.5)/float2(counts.zw);
    float x=lerp(frustum.x,frustum.y,uv.x),y=lerp(frustum.z,frustum.w,uv.y);
    precise float3 origin=cameraRight.xyz*x+cameraForward.xyz*cameraRight.w+cameraUp.xyz*y;
    precise float3 direction=normalize(origin);
    float forwardDot=dot(direction,cameraForward.xyz);
    float far=min(1000,(cameraForward.w-cameraRight.w)/forwardDot);
    Pixel result;result.primary=trace(origin,direction,far,0);result.full=miss();result.excluded=miss();
    if(result.primary.state==1) {
        Triangle tri=triangles[result.primary.reference];
        precise float3 crossNormal=cross(tri.b-tri.a,tri.c-tri.a);
        float lengthSquared=dot(crossNormal,crossNormal);
        if(lengthSquared<=0||!isfinite(lengthSquared)) {result.full=invalid();result.excluded=invalid();}
        else {
            precise float3 normal=crossNormal/sqrt(lengthSquared);
            precise float3 reflected=normalize(direction-2*dot(direction,normal)*normal);
            precise float3 start=origin+direction*result.primary.distance+reflected*.01;
            result.full=trace(start,reflected,cameraUp.w,0);
            result.excluded=trace(start,reflected,cameraUp.w,3-result.primary.owner);
        }
    }
    pixels[id.y*counts.z+id.x]=result;
}
