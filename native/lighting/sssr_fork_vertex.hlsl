// OFFLINE vertex producer sharing the exact production perDraw layout.
// Eye-ray length must track the fixture camera far plane, not a fixed 10 m.
#include "../../shaders/beamrt/nativeSsr/traceP_v002.hlsl"
PFXVertToPix fixtureMainV(uint index : SV_VertexID)
{
    PFXVertToPix output;
    output.uv0 = float2((index << 1) & 2, index & 2);
    output.uv1 = output.uv2 = output.uv3 = output.uv0;
    output.wsEyeRay = float3(output.uv0.x - 0.5, 0.5 - output.uv0.y, 1) * projParams.y;
    output.hpos = float4(output.uv0 * float2(2, -2) + float2(-1, 1), 0, 1);
    return output;
}
