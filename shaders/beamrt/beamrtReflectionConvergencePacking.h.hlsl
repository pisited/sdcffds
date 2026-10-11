#ifndef BEAMRT_CONVERGENCE_PACKING
#define BEAMRT_CONVERGENCE_PACKING
// Exact positive float32 integer, not bitcast: count/unknown/dark in 8 bits.
// Max128 per counter uses at most24 bits. Never filtered, blended or stored R16.
uint3 convergenceCounters(float packed)
{
    uint word = uint(max(packed, 0.0));
    return uint3((word >> 16) & 255u, (word >> 8) & 255u, word & 255u);
}
float convergencePack(uint3 value) { return float((value.x << 16) | (value.y << 8) | value.z); }
#endif
