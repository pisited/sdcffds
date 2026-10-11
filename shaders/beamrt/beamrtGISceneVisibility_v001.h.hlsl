// BeamRT GI world-space *opaque* visibility v001.
// The scene database intentionally provides only faces whose alphaMode has
// been explicitly verified as opaque. Unknown / alpha-masked triangles are
// omitted so missing material masks cannot create false GI occlusion.
#ifndef BEAMRT_SCENE_VISIBILITY_GI_H
#define BEAMRT_SCENE_VISIBILITY_GI_H

bool beamrtGISegmentHitsTriangle(float3 origin, float3 ray, float maxDistance,
                                 float3 a, float3 b, float3 c)
{
    float3 edge1=b-a;
    float3 edge2=c-a;
    float3 p=cross(ray,edge2);
    float determinant=dot(edge1,p);
    if (abs(determinant)<0.00001) return false;
    float invDet=1.0/determinant;
    float3 offset=origin-a;
    float u=dot(offset,p)*invDet;
    if (u<0.0 || u>1.0) return false;
    float3 q=cross(offset,edge1);
    float v=dot(ray,q)*invDet;
    if (v<0.0 || u+v>1.0) return false;
    float distance=dot(edge2,q)*invDet;
    return distance>0.08 && distance<maxDistance-0.08;
}

// Returns true ONLY for an actual hit on an explicitly opaque imported
// triangle. False does NOT mean the unimported rest of the map is transparent.
bool beamrtGIBlockedByKnownGeometry(float3 fromWorld, float3 toWorld)
{
    if (sceneVisibilityEnabled<0.5) return false;
    float3 offset=toWorld-fromWorld;
    float distance=length(offset);
    if (distance<0.20) return false;
    float3 direction=offset/distance;
    int count=clamp((int)sceneVisibilityTriangleCount,0,12);
    [loop]
    for(int index=0;index<12;++index)
    {
        if(index>=count) break;
        float3 a=sceneVisTri0A.xyz;
        float3 b=sceneVisTri0B.xyz;
        float3 c=sceneVisTri0C.xyz;
        if(index==1)
        {
            a=sceneVisTri1A.xyz;
            b=sceneVisTri1B.xyz;
            c=sceneVisTri1C.xyz;
        }
        else if(index==2)
        {
            a=sceneVisTri2A.xyz;
            b=sceneVisTri2B.xyz;
            c=sceneVisTri2C.xyz;
        }
        else if(index==3)
        {
            a=sceneVisTri3A.xyz;
            b=sceneVisTri3B.xyz;
            c=sceneVisTri3C.xyz;
        }
        else if(index==4)
        {
            a=sceneVisTri4A.xyz;
            b=sceneVisTri4B.xyz;
            c=sceneVisTri4C.xyz;
        }
        else if(index==5)
        {
            a=sceneVisTri5A.xyz;
            b=sceneVisTri5B.xyz;
            c=sceneVisTri5C.xyz;
        }
        else if(index==6)
        {
            a=sceneVisTri6A.xyz;
            b=sceneVisTri6B.xyz;
            c=sceneVisTri6C.xyz;
        }
        else if(index==7)
        {
            a=sceneVisTri7A.xyz;
            b=sceneVisTri7B.xyz;
            c=sceneVisTri7C.xyz;
        }
        else if(index==8)
        {
            a=sceneVisTri8A.xyz;
            b=sceneVisTri8B.xyz;
            c=sceneVisTri8C.xyz;
        }
        else if(index==9)
        {
            a=sceneVisTri9A.xyz;
            b=sceneVisTri9B.xyz;
            c=sceneVisTri9C.xyz;
        }
        else if(index==10)
        {
            a=sceneVisTri10A.xyz;
            b=sceneVisTri10B.xyz;
            c=sceneVisTri10C.xyz;
        }
        else if(index==11)
        {
            a=sceneVisTri11A.xyz;
            b=sceneVisTri11B.xyz;
            c=sceneVisTri11C.xyz;
        }
        if (beamrtGISegmentHitsTriangle(fromWorld,direction,distance,a,b,c))
            return true;
    }
    return false;
}
#endif
