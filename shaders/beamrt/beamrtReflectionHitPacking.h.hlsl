#ifndef BEAMRT_REFLECTION_HIT_PACKING_H_HLSL
#define BEAMRT_REFLECTION_HIT_PACKING_H_HLSL

// Numeric integers, not float bitcasts: [1, 2^24] is exact in R32F.
// Zero denotes missing metadata. Coordinates are viewport UV, never receiver UV.
// Twelve bits per axis give approximately 0.313 pixel error at width 2560.
// These values must never pass through R16F, blending or linear filtering.
float beamrtPackHitUV(float2 viewportUV)
{
    uint2 q = uint2(round(saturate(viewportUV) * 4095.0));
    return float(q.x | (q.y << 12)) + 1.0;
}

bool beamrtHasHitUV(float packed)
{
    return packed >= 1.0 && packed <= 16777216.0 && packed == floor(packed);
}

float2 beamrtUnpackHitUV(float packed)
{
    uint word = uint(packed) - 1u;
    return float2(word & 4095u, (word >> 12) & 4095u) / 4095.0;
}
#endif
