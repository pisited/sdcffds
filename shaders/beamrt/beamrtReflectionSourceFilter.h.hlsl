// Three explicit depth-aware color levels (2x, 4x, 8x) in one 2D input.
// An approximate source-footprint filter, not additional GGX ray integration.
float3 beamrtReflectionSourceLevel(float2 viewportUV, float sourceDepth, int level, float3 fallback)
{
    int2 size = int2(reflectionHalfSize);
    int startY = 0;
    if (level >= 1) { startY += size.y; size = (size + 1) >> 1; }
    if (level >= 2) { startY += size.y; size = (size + 1) >> 1; }
    float2 position = saturate(viewportUV) * size - 0.5;
    int2 base = int2(floor(position));
    float2 phase = frac(position);
    float3 sum = 0;
    float weights = 0;
    [unroll] for (int y = 0; y < 2; ++y)
    [unroll] for (int x = 0; x < 2; ++x)
    {
        int2 p = clamp(base + int2(x, y), 0, size - 1);
        float4 value = reflectionRadianceTexTex.Load(int3(p + int2(0, startY), 0));
        float2 axis = lerp(1.0 - phase, phase, float2(x, y));
        float tolerance = max(0.03, sourceDepth * 0.006);
        float weight = axis.x * axis.y
            * (1.0 - smoothstep(tolerance, tolerance * 4.0, abs(value.a - sourceDepth)));
        sum += value.rgb * weight;
        weights += weight;
    }
    // Missing/cross-surface footprint falls back to the accepted raw hit.
    return lerp(fallback, weights > 0.0001 ? sum / weights : fallback, saturate(weights));
}
float3 beamrtReflectionFilteredSource(float3 raw, float2 hitViewportUV,
    float hitDepth, float roughness, float travel)
{
    // Keep polished/mirror source detail. Conservative approximate footprint
    // with an 8-source-pixel cap; do not stack an unrestricted second GGX cone.
    float materialWeight = smoothstep(0.04, 0.16, roughness);
    float pixels = max(1.0, roughness * roughness * travel
        / max(hitDepth, 0.01) * reflectionHalfSize.y * 0.5);
#ifdef BEAMRT_REFLECTION_TUNING
    if (reflectionSourceFootprintScale <= 0.0) return raw;
    pixels = max(1.0, pixels * clamp(reflectionSourceFootprintScale, 0.0, 2.0));
#endif
    float lod = clamp(log2(pixels), 0.0, 3.0);
    float3 color;
    if (lod <= 1.0)
        color = lerp(raw, beamrtReflectionSourceLevel(hitViewportUV, hitDepth, 0, raw), lod);
    else
    {
        int level = lod < 2.0 ? 0 : 1;
        color = lerp(beamrtReflectionSourceLevel(hitViewportUV, hitDepth, level, raw),
            beamrtReflectionSourceLevel(hitViewportUV, hitDepth, level + 1, raw),
            lod - float(level + 1));
    }
    return lerp(raw, color, materialWeight);
}
