// Parked/paused player vehicle, true exterior triangles and native opacity UV0.
// R16 quantized BVH. No final-image multiplication or native shadow replacement.
#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(prepassTex,0);
uniform_sampler2D(prepassDepthTex,1);
uniform_sampler2D(glassGeometryTex,2);
uniform_sampler2D(glassOpacity0,3);
uniform_sampler2D(glassOpacity1,4);
uniform_sampler2D(glassOpacity2,5);
cbuffer perDraw:register(b0)
{
    float3 eyePosWorld;
    float3 sunDirection;
    float3 glassMin,glassExtent;
    float2 glassUVMin,glassUVExtent;
    float2 glassAtlasSize;
    float glassTag,glassTriangles,glassNodes,glassMaterials;
    float3 glassOpacityFactor;
    float glassStrength,glassSunSign;
    POSTFX_UNIFORMS
};
#include "shaders/common/postFx/postFx.hlsl"
#ifdef SHADER_STAGE_VS
#define mainV main
#else
#define mainP main
#endif
float glassRead(uint index)
{
    return glassGeometryTexTex.Load(int3(index%(uint)glassAtlasSize.x,index/(uint)glassAtlasSize.x,0)).r;
}
uint glassUInt(uint index){return (uint)round(glassRead(index)*65535.0);}
float3 glassPosition(uint index)
{
    return glassMin+float3(glassRead(index),glassRead(index+1),glassRead(index+2))*glassExtent;
}
bool glassBox(float3 origin,float3 direction,float3 lo,float3 hi)
{
    float enter=0,leave=200;
    [unroll] for(int axis=0;axis<3;axis++)
    {
        if(abs(direction[axis])<1e-8)
        {
            if(origin[axis]<lo[axis]||origin[axis]>hi[axis])return false;
        }
        else
        {
            float a=(lo[axis]-origin[axis])/direction[axis],b=(hi[axis]-origin[axis])/direction[axis];
            enter=max(enter,min(a,b));leave=min(leave,max(a,b));
            if(leave<enter)return false;
        }
    }
    return leave>=enter;
}
bool glassTriangle(float3 origin,float3 direction,uint triIndex,out float distance,out float2 uv,out uint material)
{
    uint base=8+(uint)glassNodes*8+triIndex*16;
    float3 a=glassPosition(base),e1=glassPosition(base+3)-a,e2=glassPosition(base+6)-a;
    float3 p=cross(direction,e2);float determinant=dot(e1,p);
    distance=0;uv=0;material=0;
    if(abs(determinant)<1e-9)return false;
    float inv=1/determinant;float3 q=origin-a;
    float u=dot(q,p)*inv;float3 r=cross(q,e1);float v=dot(direction,r)*inv;
    distance=dot(e2,r)*inv;
    if(u<-.00001||v<-.00001||u+v>1.00001||distance<.015||distance>200)return false;
    float2 ua=float2(glassRead(base+9),glassRead(base+10));
    float2 ub=float2(glassRead(base+11),glassRead(base+12));
    float2 uc=float2(glassRead(base+13),glassRead(base+14));
    uv=glassUVMin+(ua*(1-u-v)+ub*u+uc*v)*glassUVExtent;
    material=glassUInt(base+15);
    return material<(uint)glassMaterials&&all(isfinite(uv));
}
float glassTrace(float3 origin,float3 direction)
{
    if(!glassBox(origin,direction,glassMin-.002,glassMin+glassExtent+.002))return 1;
    uint stack[32];stack[0]=0;uint top=1,visits=0;
    float distances[8],opacities[8];uint hits=0;
    [unroll] for(int init=0;init<8;init++){distances[init]=0;opacities[init]=0;}
    [loop] while(top>0)
    {
        if(++visits>(uint)glassNodes)return 1; // malformed traversal cannot invent extinction
        uint node=stack[--top];if(node>=(uint)glassNodes)return 1;
        uint base=8+node*8;
        if(!glassBox(origin,direction,glassPosition(base),glassPosition(base+3)))continue;
        uint first=glassUInt(base+6),last=glassUInt(base+7);
        if(last<32768)
        {
            if(top+2>32||first>=(uint)glassNodes||last>=(uint)glassNodes)return 1;
            stack[top++]=last;stack[top++]=first;
        }
        else
        {
            uint count=last-32768;
            if(count==0||count>8||first+count>(uint)glassTriangles)return 1;
            [loop] for(uint i=0;i<count;i++)
            {
                float t;float2 uv;uint m;
                if(!glassTriangle(origin,direction,first+i,t,uv,m))continue;
                float opacity=m==0?glassOpacity0Tex.SampleLevel(glassOpacity0_sampler_,uv,0).r:
                    (m==1?glassOpacity1Tex.SampleLevel(glassOpacity1_sampler_,uv,0).r:
                          glassOpacity2Tex.SampleLevel(glassOpacity2_sampler_,uv,0).r);
                if(!isfinite(opacity)||opacity<0||opacity>1)return 1;
                opacity=saturate(opacity*glassOpacityFactor[m]);
                bool merged=false;
                [unroll] for(int hitIndex=0;hitIndex<8;hitIndex++)
                {
                    // Triangle seams/duplicate faces at one pane are one crossing.
                    if(!merged&&(uint)hitIndex<hits&&abs(distances[hitIndex]-t)<.01)
                    {opacities[hitIndex]=max(opacities[hitIndex],opacity);merged=true;}
                }
                if(!merged)
                {
                    if(hits>=8)return 1; // explicitly bounded; never silently truncate panes
                    distances[hits]=t;opacities[hits]=opacity;hits++;
                }
            }
        }
    }
    float transmission=1;
    [unroll] for(int multiplyIndex=0;multiplyIndex<8;multiplyIndex++)
        if((uint)multiplyIndex<hits)transmission*=1-opacities[multiplyIndex];
    return lerp(1,transmission,saturate(glassStrength));
}
float4 mainP(PFXVertToPix IN):SV_Target0
{
    uint w,h;glassGeometryTexTex.GetDimensions(w,h);
    if(!all(isfinite(glassMin))||!all(isfinite(glassExtent))||any(glassExtent<=0)
        ||!all(isfinite(glassUVMin))||!all(isfinite(glassUVExtent))||any(glassUVExtent<=0)
        ||!all(isfinite(glassAtlasSize))||!all(isfinite(glassOpacityFactor))
        ||any(glassOpacityFactor<0)||any(glassOpacityFactor>1)
        ||!isfinite(glassStrength)||!isfinite(glassTag)||!isfinite(glassSunSign)
        ||!isfinite(glassTriangles)||!isfinite(glassNodes)||!isfinite(glassMaterials))return 0;
    if(w!=(uint)glassAtlasSize.x||h!=(uint)glassAtlasSize.y||w==0||glassMaterials<1||glassMaterials>3
        ||glassTriangles<1||glassTriangles>4096||glassNodes<1||glassNodes>1023)return 0;
    if(glassUInt(0)!=45678||glassUInt(1)!=(uint)glassTriangles||glassUInt(2)!=(uint)glassTag
        ||glassUInt(3)!=1||glassUInt(4)!=(uint)glassNodes)return 0;
    if(8+glassNodes*8+glassTriangles*16>(float)(w*h))return 0;
    uint ow,oh;
    glassOpacity0Tex.GetDimensions(ow,oh);if(ow==0||oh==0)return 0;
    if(glassMaterials>1){glassOpacity1Tex.GetDimensions(ow,oh);if(ow==0||oh==0)return 0;}
    if(glassMaterials>2){glassOpacity2Tex.GetDimensions(ow,oh);if(ow==0||oh==0)return 0;}
    float4 receiver=decodeGBuffer(TEX_SAMPLER(prepassDepthTex),TEX_SAMPLER(prepassTex),IN.uv0,projParams);
    if(!all(isfinite(receiver))||receiver.w<=0||receiver.w>=.9999)return 0;
    float3 world=eyePosWorld+IN.wsEyeRay*receiver.w;
    float3 direction=sunDirection*glassSunSign;float magnitude=dot(direction,direction);
    if(!all(isfinite(world))||!all(isfinite(direction))||magnitude<1e-8)return 0;
    direction*=rsqrt(magnitude);
    float transmission=dot(receiver.xyz,direction)>.001?glassTrace(world+receiver.xyz*.005,direction):1;
    return float4(world,1+transmission);
}
PFXVertToPix mainV(PFXVert IN){return processPostFxVert(IN);}
