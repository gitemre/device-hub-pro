#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut mirror_vertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    const float2 uvs[3] = {
        float2(0.0, 1.0),
        float2(2.0, 1.0),
        float2(0.0, -1.0)
    };
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = uvs[vertexID];
    return out;
}

fragment float4 mirror_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> frameTexture [[texture(0)]],
    sampler frameSampler [[sampler(0)]],
    constant int &textureRotation [[buffer(0)]]
) {
    // The streamed buffer is composed for the device's physical pose; the
    // native composition shows it upright, so the sample coordinates are
    // rotated by the settled quarter turn (TextureRotation.posedUV).
    float2 uv = in.uv;
    switch ((textureRotation % 4 + 4) % 4) {
        case 1: uv = float2(uv.y, 1.0 - uv.x); break;
        case 2: uv = float2(1.0 - uv.x, 1.0 - uv.y); break;
        case 3: uv = float2(1.0 - uv.y, uv.x); break;
        default: break;
    }
    return frameTexture.sample(frameSampler, uv);
}
