// Shared material-aware world segment queries. Missing/uncertain data cannot
// certify whole-scene visibility or replace native shadowing. Texture t5 in GI,
// t2 in the shadow tracer; no seventh input. Model direction is not normalized.
float3 beamrtMeshEncodeSRGB(float3 c)
{return lerp(1.055*pow(max(c,0.0),1.0/2.4)-0.055,12.92*c,step(c,0.0031308));}
uint4 beamrtMeshBytes(uint index,bool srgb)
{
    uint width=(uint)meshAtlasSize.x;
    float4 c=meshDataTexTex.Load(int3(index%width,index/width,0));
    if(srgb)c.rgb=beamrtMeshEncodeSRGB(c.rgb);
    return (uint4)round(saturate(c)*255);
}
uint beamrtMeshWord(uint index,bool srgb)
{uint4 b=beamrtMeshBytes(index,srgb);return b.x|(b.y<<8)|(b.z<<16)|(b.w<<24);}
float3 beamrtMeshPoint(uint index,bool srgb)
{
    uint4 a=beamrtMeshBytes(index,srgb),b=beamrtMeshBytes(index+1,srgb);
    return meshQuantMin+meshQuantExtent*float3(a.x+256*a.y,a.z+256*a.w,b.x+256*b.y)/65535;
}
float3 beamrtMeshLocal(float3 p){return float3(dot(meshInvX,p),dot(meshInvY,p),dot(meshInvZ,p));}
bool beamrtMeshDataValid(out bool srgb)
{
    srgb=false;
    uint w,h;meshDataTexTex.GetDimensions(w,h);
    if(w!=(uint)meshAtlasSize.x||h!=(uint)meshAtlasSize.y||w==0||meshNodeCount<1)return false;
    float4 header=meshDataTexTex.Load(int3(0,0,0));
    srgb=any(round(header.rgb*255)!=float3(64,128,192));
    return all(beamrtMeshBytes(0,srgb)==uint4(64u,128u,192u,255u))
        &&all(beamrtMeshBytes(1,srgb)==uint4(23u,101u,211u,37u))
        &&meshTriangleOffset+meshTriangleCount*7<=(float)(w*h);
}
bool beamrtMeshBox(float3 o,float3 d,float3 lo,float3 hi,float reach,float rayStartBias)
{
    float near=rayStartBias,far=reach;
    [unroll]for(int a=0;a<3;++a)
    {
        if(abs(d[a])<1e-10){if(o[a]<lo[a]||o[a]>hi[a])return false;}
        else {float x=(lo[a]-o[a])/d[a],y=(hi[a]-o[a])/d[a];near=max(near,min(x,y));far=min(far,max(x,y));if(near>far)return false;}
    }
    return near<=far;
}
bool beamrtMeshTriangle(float3 o,float3 d,float3 a,float3 b,float3 c,float reach,float rayStartBias)
{
    float3 e1=b-a,e2=c-a,p=cross(d,e2);float det=dot(e1,p);
    if(abs(det)<1e-10)return false;
    float3 t=o-a;float u=dot(t,p)/det;if(u<0||u>1)return false;
    float3 q=cross(t,e1);float v=dot(d,q)/det;if(v<0||u+v>1)return false;
    float distance=dot(e2,q)/det;return distance>rayStartBias&&distance<reach;
}
uint beamrtMeshMaterial(uint4 meta)
{
    if(meshMaterialPolicyEnabled<.5)return meta.x;
    uint index=meta.y+256*meta.z;if(index>=16)return 0;
    float4 modes=meshMaterialModes0;
    if(index>=12)modes=meshMaterialModes3;else if(index>=8)modes=meshMaterialModes2;else if(index>=4)modes=meshMaterialModes1;
    return (uint)round(modes[index&3u]);
}
// Return 2 only for a definite declared-opaque hit. Uncertain hits never
// prevent finding a later definite blocker. -1 data failure; -2 incomplete.
int beamrtMeshTrace(float3 worldOrigin,float3 worldDirection,float reach,float rayStartBias,out uint visits)
{
    visits=0;bool srgb;
    if(!beamrtMeshDataValid(srgb))return -1;
    float3 o=beamrtMeshLocal(worldOrigin-meshOrigin),d=beamrtMeshLocal(worldDirection);
    uint node=0;bool possible=false;
    [loop]for(uint iteration=0;iteration<4096;++iteration)
    {
        if(node>=(uint)meshNodeCount)break;
        visits++;uint offset=2+node*6,info=beamrtMeshWord(offset+5,srgb),count=info&255u,escape=info>>8;
        if(escape<=node||escape>(uint)meshNodeCount||count>8)return -1;
        // Preorder leaves advance by one; internal nodes contain two child
        // subtrees. Never use a malformed escape to certify hit/miss coverage.
        if((count>0 && escape!=node+1) || (count==0 && escape<=node+2))return -1;
        if(!beamrtMeshBox(o,d,beamrtMeshPoint(offset,srgb),beamrtMeshPoint(offset+2,srgb),reach,rayStartBias)){node=escape;continue;}
        if(count==0){node++;continue;}
        uint start=beamrtMeshWord(offset+4,srgb);
        // Checked subtraction avoids UINT32 addition wrapping to a valid range.
        if(start>(uint)meshTriangleCount || count>(uint)meshTriangleCount-start)return -1;
        [loop]for(uint i=0;i<8;++i)
        {
            if(i>=count)break;uint p=(uint)meshTriangleOffset+(start+i)*7;
            float3 a=beamrtMeshPoint(p,srgb),b=beamrtMeshPoint(p+2,srgb),c=beamrtMeshPoint(p+4,srgb);
            float3 area=cross(b-a,c-a);
            // Packing/invalid data can collapse a face. Distinguish that from
            // a valid face parallel to this ray: unusable geometry is unknown.
            if(!all(isfinite(a)) || !all(isfinite(b)) || !all(isfinite(c)) || !all(isfinite(area)) || all(area==0.0))return -1;
            if(beamrtMeshTriangle(o,d,a,b,c,reach,rayStartBias))
            {
                uint mode=beamrtMeshMaterial(beamrtMeshBytes(p+6,srgb));
                if(mode==1)return 2;possible=true;
            }
        }
        node=escape;
    }
    if(node<(uint)meshNodeCount)return -2;
    return possible?1:0;
}
bool beamrtMeshBlockedSegment(float3 fromWorld,float3 toWorld)
{
    if(meshVisibilityEnabled<.5)return false;
    float3 delta=toWorld-fromWorld;float distance=length(delta);
    if(distance<.2)return false;
    uint visits;return beamrtMeshTrace(fromWorld,delta/distance,distance-.08,.08,visits)==2;
}
