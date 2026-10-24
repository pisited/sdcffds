// Native GI contract v1. Full-float, point-loaded data, NOT a filtered mask.
// Row 0 pixel 0: exact positive 24-bit view/frame, geometry, surfel keys, ABI=1.
// Rows 1..H: four integer-valued byte channels encoding 32 opaque-blocker bits.
// Negative/invalid texels, key/size mismatch and disabled all preserve original GI.
#ifndef BEAMRT_NATIVE_GI_VISIBILITY_V001
#define BEAMRT_NATIVE_GI_VISIBILITY_V001
bool beamrtNativeGIBlocked(float2 sceneUv,int surfelIndex)
{
    if(!isfinite(nativeGIVisibilityEnabled) || nativeGIVisibilityEnabled<0.5 || surfelIndex<0 || surfelIndex>=32) return false;
    uint width,height;nativeGIVisibilityTexTex.GetDimensions(width,height);
    if(width==0 || height<2 || any(float2(width,height-1)!=nativeGIVisibilitySize)) return false;
    if(any(nativeGIVisibilityKey.xyz<1) || any(nativeGIVisibilityKey.xyz>16777215)
        || any(nativeGIVisibilityKey!=floor(nativeGIVisibilityKey)) || nativeGIVisibilityKey.w!=1) return false;
    float4 header=nativeGIVisibilityTexTex.Load(int3(0,0,0));
    if(!all(header==nativeGIVisibilityKey)) return false;
    // rtParams maps the normalized prepass viewport into its render target.
    // An inverted/outside viewport can still round-trip to a plausible pixel;
    // never certify a blocker using such metadata. Allow only rounding noise
    // at the upper extent, not a clamped/repaired mapping or another receiver.
    if(!all(isfinite(rtParams0)) || !all(rtParams0.xy>=0) || !all(rtParams0.zw>0)
        || !all(rtParams0.xy+rtParams0.zw<=1.000001)) return false;
    if(!all(isfinite(sceneUv)) || !all(sceneUv>=0) || !all(sceneUv<1)) return false;
    float2 viewportUv=(sceneUv-rtParams0.xy)/rtParams0.zw;
    if(!all(viewportUv>=0) || !all(viewportUv<1)) return false;
    int2 pixel=(int2)floor(viewportUv*nativeGIVisibilitySize);pixel.y+=1;
    float4 bytes=nativeGIVisibilityTexTex.Load(int3(pixel,0));
    if(!all(bytes>=0) || !all(bytes<=255) || !all(bytes==floor(bytes))) return false;
    uint bits=(uint)bytes[surfelIndex>>3];
    return (bits & (1u<<(surfelIndex&7)))!=0;
}
#endif
