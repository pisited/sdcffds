#ifndef BEAMRT_REFLECTION_RADIANCE_SAFETY_H_HLSL
#define BEAMRT_REFLECTION_RADIANCE_SAFETY_H_HLSL

// Inspect the IEEE-754 exponent with integer operations. Floating-point
// comparisons alone may be simplified under finite-math compilation options.
bool beamrtReflectionRadianceIsFinite(float3 radiance)
{
    uint3 exponents = asuint(radiance) & 0x7f800000u;
    return all(exponents != 0x7f800000u);
}

// Reject the whole unsupported RGB sample before confidence/BRDF weighting.
// This is not a confidence or geometry decision: callers retain their alpha.
float3 beamrtReflectionFiniteSource(float3 radiance)
{
    return beamrtReflectionRadianceIsFinite(radiance) ? radiance : 0.0;
}

// Only the outgoing contribution is clamped. Clamping source radiance before
// its weights would incorrectly dim a bright source with an in-range result.
float3 beamrtReflectionSafeRadiance(float3 radiance)
{
    if (!beamrtReflectionRadianceIsFinite(radiance)) return 0.0;
    return clamp(radiance, 0.0, 65504.0);
}

#endif
