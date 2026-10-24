// Native PS instrumentation, not a screen-space occluder tracer.
// All selection constants are immutable defines on a private ShaderData.
uniform_sampler2D(beamrtNativeFrame,14);
bool beamrtNativeSelected(LightDataAdv light)
{
    if(any(abs(light.lightPosition-BEAMRT_NATIVE_POSITION)>.002)
        ||abs(light.lightRange-BEAMRT_NATIVE_RANGE)>.002)return false;
#if BEAMRT_NATIVE_SPOT
    if(any(abs(light.lightDirection-BEAMRT_NATIVE_DIRECTION)>.0001)
        ||abs(light.lightSpotParams.x-BEAMRT_NATIVE_OUTER)>.0001)return false;
#endif
    return true;
}
float beamrtNativePacket(float visibility,bool available)
{
    uint w,h;beamrtNativeFrameTex.GetDimensions(w,h);
    if(w!=1||h!=1)return 0;
    float4 tag=beamrtNativeFrameTex.Load(int3(0,0,0));
    if(!all(isfinite(tag))||tag.y!=.375||tag.z!=.625||tag.w!=1)return 0;
    uint epoch=(uint)round(tag.x);
    // Exact finite NORMAL binary16 patterns: no denorm/NaN/Inf, no epoch reuse.
    if(tag.x!=(float)epoch||epoch<32||epoch>2015||epoch==480||(epoch>=992&&epoch<=1055))return 0;
    uint code=available?(uint)round(saturate(visibility)*15):16;
    return f16tof32((epoch<<5)|code);
}
