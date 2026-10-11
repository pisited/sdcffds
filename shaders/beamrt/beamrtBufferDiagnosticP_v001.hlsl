// Temporary BeamRT named-buffer probe. Delete this file and its Lua registration
// once the BeamNG buffer semantics have been identified.
#include "beamrtBufferDiagnostic_v001.h.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float3 selectDiagnosticChannel(float4 value, float channel)
{
    if (channel < 0.5)
    {
        return value.rgb;
    }

    float selected = value.r;
    if (channel < 1.5) selected = value.r;
    else if (channel < 2.5) selected = value.g;
    else if (channel < 3.5) selected = value.b;
    else selected = value.a;
    return selected.xxx;
}

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float4 rawValue = tex2D(inputTex, IN.uv0);

    // Contain obviously invalid/extreme finite data inside the disposable
    // diagnostic pass instead of propagating it into the backbuffer.
    if (any(abs(rawValue) > 65504.0))
    {
        return float4(1.0, 0.0, 1.0, 1.0);
    }

    float displayScale = max(diagnosticGain, 0.0)
        * exp2(clamp(diagnosticExposure, -20.0, 20.0));

    // Raw is deliberately the default. It performs no assumptions about the
    // source encoding and simply copies/scales the requested components.
    if (diagnosticHDRDecode < 0.5)
    {
        float4 scaledValue = rawValue * displayScale;
        return float4(selectDiagnosticChannel(scaledValue, diagnosticChannel), 1.0);
    }

    // Optional BeamNG HDR interpretation. Decode RGB before channel selection,
    // apply exposure in linear space, then re-encode for the HDR backbuffer.
    // Alpha is never HDR-decoded.
    if (diagnosticChannel >= 3.5)
    {
        float alphaValue = rawValue.a * displayScale;
        return float4(alphaValue.xxx, 1.0);
    }

    float3 decodedRGB = max(hdrDecode(rawValue.rgb), 0.0) * displayScale;
    float4 decodedValue = float4(decodedRGB, rawValue.a);
    float3 selectedValue = selectDiagnosticChannel(decodedValue, diagnosticChannel);
    return float4(hdrEncode(selectedValue), 1.0);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
