// Isolated one-instance world-ray / model-space BVH diagnostic.
// RGBA: hit category (0 miss,1 unknown opacity,2 declared opaque), traversal
// complete (1 yes,0 budget/-1 invalid GPU data), node visits/limit, receiver.
#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(prepassTex,0);
uniform_sampler2D(prepassDepthTex,1);
uniform_sampler2D(meshDataTex,2);
cbuffer perDraw : register(b0)
{
    uniform float3 eyePosWorld;
    uniform float3 sunDirection;
    uniform float3 meshOrigin;
    uniform float3 meshInvX;
    uniform float3 meshInvY;
    uniform float3 meshInvZ;
    uniform float3 meshQuantMin;
    uniform float3 meshQuantExtent;
    uniform float meshNodeCount;
    uniform float meshTriangleCount;
    uniform float meshTriangleOffset;
    uniform float2 meshAtlasSize;
    uniform float meshSunSign;
    uniform float meshBindingView;
    uniform float meshMaxDistance;
    uniform float meshTestLightEnabled;
    uniform float3 meshTestLightPosition;
    POSTFX_UNIFORMS
};
#include "shaders/common/postFx/postFx.hlsl"
#ifdef SHADER_STAGE_VS
#define mainV main
#else
#define mainP main
#endif
float3 encodeSRGB(float3 c)
{
    return lerp(1.055*pow(max(c,0.0),1.0/2.4)-0.055,12.92*c,step(c,0.0031308));
}
uint4 meshBytes(uint index,bool srgb)
{
    uint width=(uint)meshAtlasSize.x;
    float4 c=meshDataTexTex.Load(int3(index%width,index/width,0));
    if(srgb)c.rgb=encodeSRGB(c.rgb);
    return (uint4)round(saturate(c)*255.0);
}
uint meshWord(uint index,bool srgb)
{
    uint4 b=meshBytes(index,srgb);
    return b.x|(b.y<<8)|(b.z<<16)|(b.w<<24);
}
float3 meshPoint(uint index,bool srgb)
{
    uint4 a=meshBytes(index,srgb),b=meshBytes(index+1,srgb);
    return meshQuantMin+meshQuantExtent*float3(a.x+256*a.y,a.z+256*a.w,b.x+256*b.y)/65535.0;
}
float3 localVector(float3 p){return float3(dot(meshInvX,p),dot(meshInvY,p),dot(meshInvZ,p));}
bool boxHit(float3 origin,float3 dir,float3 lo,float3 hi,float reach)
{
    float near=0.05,far=reach;
    [unroll]for(int axis=0;axis<3;++axis)
    {
        if(abs(dir[axis])<1e-10){if(origin[axis]<lo[axis]||origin[axis]>hi[axis])return false;}
        else
        {
            float a=(lo[axis]-origin[axis])/dir[axis],b=(hi[axis]-origin[axis])/dir[axis];
            near=max(near,min(a,b));far=min(far,max(a,b));
            if(near>far)return false;
        }
    }
    return true;
}
bool triangleHit(float3 origin,float3 dir,float3 a,float3 b,float3 c,float reach)
{
    float3 e1=b-a,e2=c-a,p=cross(dir,e2);
    float det=dot(e1,p);
    if(abs(det)<1e-10)return false;
    float3 t=origin-a;float u=dot(t,p)/det;
    if(u<0||u>1)return false;
    float3 q=cross(t,e1);float v=dot(dir,q)/det;
    if(v<0||u+v>1)return false;
    float distance=dot(e2,q)/det;
    return distance>0.05&&distance<reach;
}
float4 mainP(PFXVertToPix IN):SV_Target0
{
    uint width,height;meshDataTexTex.GetDimensions(width,height);
    if(width!=(uint)meshAtlasSize.x||height!=(uint)meshAtlasSize.y||width==0)
        return float4(0,-1,0,1);
    float4 header=meshDataTexTex.Load(int3(0,0,0));
    bool srgb=any(round(header.rgb*255.0)!=float3(64,128,192));
    uint4 h0=meshBytes(0,srgb),h1=meshBytes(1,srgb);
    bool valid=all(h0==uint4(64u,128u,192u,255u))
        &&all(h1==uint4(23u,101u,211u,37u))
        &&meshNodeCount>0&&meshTriangleCount>0
        &&meshTriangleOffset+meshTriangleCount*7<=(float)(width*height);
    if(!valid)return float4(0,-1,0,1);
    if(meshBindingView>.5)return float4(0,1,srgb?.5:1,1);
    float4 receiver=decodeGBuffer(TEX_SAMPLER(prepassDepthTex),TEX_SAMPLER(prepassTex),IN.uv0,projParams);
    if(receiver.w>=.9999)return float4(0,0,0,0);
    float3 worldReceiver=eyePosWorld+IN.wsEyeRay*receiver.w;
    float3 sunlight=meshTestLightEnabled>.5?meshTestLightPosition-worldReceiver:sunDirection*meshSunSign;
    float lengthSquared=dot(sunlight,sunlight);
    if(lengthSquared<1e-8)return float4(0,0,0,1);
    sunlight*=rsqrt(lengthSquared);
    if(dot(receiver.xyz,sunlight)<=0.001)return float4(0,0,0,1);
    float reach=meshTestLightEnabled>.5?min(meshMaxDistance,sqrt(lengthSquared)-.04):meshMaxDistance;
    float3 worldOrigin=worldReceiver+receiver.xyz*.035;
    float3 origin=localVector(worldOrigin-meshOrigin);
    // Do not normalize the transformed direction: t stays in WORLD metres
    // under nonuniform scale. Caster data has no screen-space dependency.
    float3 dir=localVector(sunlight);
    uint node=0,visits=0;
    [loop]for(uint iteration=0;iteration<4096;++iteration)
    {
        if(node>=(uint)meshNodeCount)break;
        visits++;
        uint offset=2+node*6;
        uint info=meshWord(offset+5,srgb),count=info&255u,escape=info>>8;
        if(escape<=node||escape>(uint)meshNodeCount||count>8)return float4(0,-1,0,1);
        if(!boxHit(origin,dir,meshPoint(offset,srgb),meshPoint(offset+2,srgb),reach))
        {node=escape;continue;}
        if(count==0){node++;continue;}
        uint start=meshWord(offset+4,srgb);
        if(start+count>(uint)meshTriangleCount)return float4(0,-1,0,1);
        [loop]for(uint i=0;i<8;++i)
        {
            if(i>=count)break;
            uint p=(uint)meshTriangleOffset+(start+i)*7;
            if(triangleHit(origin,dir,meshPoint(p,srgb),meshPoint(p+2,srgb),meshPoint(p+4,srgb),reach))
            {
                uint alpha=meshBytes(p+6,srgb).x;
                return float4(alpha==1?2:1,1,(float)visits/max(meshNodeCount,1),1);
            }
        }
        node=escape;
    }
    return float4(0,node>=(uint)meshNodeCount?1:0,(float)visits/max(meshNodeCount,1),1);
}
PFXVertToPix mainV(PFXVert IN){return processPostFxVert(IN);}
