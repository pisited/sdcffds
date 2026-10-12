Texture2D<float4> receiverOriginTex : register(t0);
Texture2D<float4> meshDataTex : register(t1);

struct HandoffVertex {
    float4 position : SV_Position;
};

HandoffVertex mainV(uint vertexId : SV_VertexID) {
    HandoffVertex output;
    float2 uv = float2((vertexId << 1) & 2, vertexId & 2);
    output.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    return output;
}

float4 mainP(HandoffVertex input) : SV_Target0 {
    float4 receiver = receiverOriginTex.Load(int3(0, 0, 0));
    float4 mesh = meshDataTex.Load(int3(0, 0, 0));
    return float4(receiver.rgb + mesh.rgb, 1);
}
