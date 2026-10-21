// Included only by a generated copy of the installed vector-light shader.
// Apply before native direct diffuse/specular shading, never to final color.
uniform_sampler2D(beamrtMeshSunVisibility,14);
#ifndef BEAMRT_SUN_COMPARISON
#define BEAMRT_SUN_COMPARISON 0
#endif
bool beamrtMeshSunReceiver(float4 hpos,float3 worldPosition,out float visibility)
{
    visibility=1;
    uint width,height;beamrtMeshSunVisibilityTex.GetDimensions(width,height);
    uint depthWidth,depthHeight;prePassDepthBufferTex.GetDimensions(depthWidth,depthHeight);
    // No upsampling, stale resolution or missing named target accepted.
    if(width!=depthWidth||height!=depthHeight||width==0)return false;
    // NaN comparisons are not evidence of receiver identity. Reject before
    // integer conversion or matching, instead of inventing an opaque shadow.
    if(!all(isfinite(hpos.xy)) || !all(isfinite(worldPosition)))return false;
    if(any(hpos.xy<0) || any(hpos.xy>=float2(width,height)))return false;
    int2 pixel=int2(hpos.xy);
    if(any(pixel<0)||pixel.x>=(int)width||pixel.y>=(int)height)return false;
    float4 value=beamrtMeshSunVisibilityTex.Load(int3(pixel,0));
    // Receiver identity also rejects main-camera masks in reflection captures.
    // A missing/unbound resource returns zero, which is NOT a blocked sentinel.
    if(!all(isfinite(value)) || (value.w!=1&&value.w!=2)||any(abs(value.xyz-worldPosition)>.01))return false;
    visibility=value.w==2?0:1;
    return true;
}
// Retain compatibility with the original generated hybrid entry.
float beamrtMeshSunFactor(float4 hpos,float3 worldPosition)
{
    float visibility;beamrtMeshSunReceiver(hpos,worldPosition,visibility);return visibility;
}
float beamrtResolveSunVisibility(float nativeVisibility,float cloudVisibility,float4 hpos,float3 worldPosition)
{
#if BEAMRT_SUN_COMPARISON == 2
    // The explicit control must be independent of the mesh relay. Previously
    // a missing/rejected receiver silently returned native shadows even here,
    // making the supposedly unshadowed control inconclusive.
    return cloudVisibility;
#else
    float meshVisibility;
    // Never bypass native shadows on stale, unbound, invalid or other-view data.
    if(!beamrtMeshSunReceiver(hpos,worldPosition,meshVisibility))return nativeVisibility;
#if BEAMRT_SUN_COMPARISON == 1
    return cloudVisibility*meshVisibility; // BeamRT-only geometric sun shadows.
#elif BEAMRT_SUN_COMPARISON == 3
    uint width,height;prePassDepthBufferTex.GetDimensions(width,height);
    return hpos.x<width*.5?nativeVisibility:cloudVisibility*meshVisibility;
#else
    return min(nativeVisibility,meshVisibility); // Normal native-preserving path.
#endif
#endif
}
