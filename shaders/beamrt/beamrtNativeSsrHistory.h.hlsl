#ifndef BEAMRT_NATIVE_SSR_HISTORY_H_HLSL
#define BEAMRT_NATIVE_SSR_HISTORY_H_HLSL

// OFFLINE experiment, not included by BeamRT or an installed native shader.
// The caller owns reprojection, predicted previous-camera linear depth and
// native texture decoding. This helper only reconstructs one four-tap history
// footprint. It is not a replacement for native temporal disocclusion.
struct BeamRTNativeHistoryTap
{
    float3 normalWS;
    float linearDepth;
    float receiverClass;
    float mask;
    float4 radianceCoverage;
};

bool beamrtNativeHistoryFinite4(float4 value)
{
    return all((asuint(value) & 0x7f800000u) != 0x7f800000u);
}

bool beamrtNativeHistoryClassValid(float value)
{
    return value >= 0.0 && value <= 3.0 && value == floor(value);
}

bool beamrtNativeHistoryNormalValid(float3 value)
{
    float lengthSquared = dot(value, value);
    // Finite components alone are insufficient: their squared sum can
    // overflow, turning normalize() into a zero/nonfinite pseudo-normal.
    return beamrtNativeHistoryFinite4(float4(value, lengthSquared))
        && lengthSquared >= 0.000001;
}

float4 beamrtNativeHistoryFootprint(BeamRTNativeHistoryTap taps[4],
    float2 phase, float3 normalWS, float linearDepth, float receiverClass,
    float normalRejection, float depthRejection, float minimumConfidence,
    out float compatibleWeight, out bool valid)
{
    compatibleWeight = 0.0;
    valid = false;
    if (!beamrtNativeHistoryFinite4(float4(normalWS, linearDepth))
        || !beamrtNativeHistoryFinite4(float4(phase, receiverClass, minimumConfidence))
        || !beamrtNativeHistoryFinite4(float4(normalRejection, depthRejection, 0, 0))
        || !beamrtNativeHistoryClassValid(receiverClass)
        || linearDepth <= 0.0 || !beamrtNativeHistoryNormalValid(normalWS)
        || any(phase < 0.0) || any(phase > 1.0)
        || normalRejection < 0.0 || depthRejection < 0.0
        || minimumConfidence < 0.0 || minimumConfidence > 1.0) return 0.0;
    normalWS = normalize(normalWS);
    float4 sum = 0.0;
    [unroll] for (int index = 0; index < 4; ++index)
    {
        BeamRTNativeHistoryTap tap = taps[index];
        if (!beamrtNativeHistoryFinite4(float4(tap.normalWS, tap.linearDepth))
            || !beamrtNativeHistoryFinite4(float4(tap.receiverClass, tap.mask, 0, 0))
            || !beamrtNativeHistoryFinite4(tap.radianceCoverage)
            || tap.mask != 1.0 || !beamrtNativeHistoryClassValid(tap.receiverClass)
            || tap.receiverClass != receiverClass || tap.linearDepth <= 0.0
            || !beamrtNativeHistoryNormalValid(tap.normalWS)
            || any(tap.radianceCoverage.rgb < 0.0)
            // Native history is RGBA16F. Enforcing its representable domain
            // also keeps finite hostile float32 fixtures from overflowing sums.
            || any(tap.radianceCoverage.rgb > 65504.0)
            || tap.radianceCoverage.a < 0.0 || tap.radianceCoverage.a > 1.0
            || (tap.radianceCoverage.a == 0.0 && any(tap.radianceCoverage.rgb != 0.0))) continue;
        float normalError = 1.0 - saturate(dot(normalWS, normalize(tap.normalWS)));
        float depthError = abs(tap.linearDepth / linearDepth - 1.0);
        float confidence = exp(-normalError * normalRejection - depthError * depthRejection);
        if (!(confidence > minimumConfidence)) continue;
        float2 axisWeight = float2((index & 1) ? phase.x : 1.0 - phase.x,
            (index & 2) ? phase.y : 1.0 - phase.y);
        float weight = axisWeight.x * axisWeight.y;
        // No radiance/confidence normalization by successful rays. Valid zero
        // estimates and uncovered samples remain in the same denominator.
        sum += tap.radianceCoverage * weight;
        compatibleWeight += weight;
    }
    valid = compatibleWeight > 0.000001;
    return valid ? sum / compatibleWeight : 0.0;
}

#endif
