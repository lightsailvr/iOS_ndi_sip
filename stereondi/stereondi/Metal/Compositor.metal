//  Compositor.metal
//
//  Slice #4 stereo compositor — one mode (SbS, no HIT, no anaglyph).
//  Each per-eye draw call submits a single triangle list (4 verts /
//  2 triangles via .triangleStrip) covering the aspect-fit region of
//  one half of the target. Two fragment paths share one vertex shader:
//   - sbs_fragment_bgra : straight BGRA8 sample
//   - sbs_fragment_uyvy : sampled .bgrg422 → BT.709-limited YCbCr → RGB
//
//  Slice #6 will add HIT + crop math; slice #7 adds anaglyph and the
//  channel-test mode. The vertex format and per-side draw structure
//  are the seam those slices extend.

#include <metal_stdlib>
using namespace metal;

struct SbSVertexIn {
    float2 position [[attribute(0)]];
    float2 uv       [[attribute(1)]];
};

struct SbSVaryings {
    float4 position [[position]];
    float2 uv;
};

vertex SbSVaryings sbs_vertex(SbSVertexIn in [[stage_in]]) {
    SbSVaryings out;
    out.position = float4(in.position, 0.0, 1.0);
    out.uv = in.uv;
    return out;
}

fragment half4 sbs_fragment_bgra(SbSVaryings in [[stage_in]],
                                 texture2d<half> source [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    half4 c = source.sample(s, in.uv);
    return half4(c.rgb, 1.0h);
}

// BT.709 limited-range YCbCr → full-range RGB. The sampled bgrg422
// texel is presented to the shader as (Y, Cb, Cr, ?) by the hardware
// chroma-reconstruction step — the alpha channel is not meaningful.
//
// HITL-verify (slice #4): on real iPad hardware confirm the channel
// order from .bgrg422 sampling. If colors look swapped, the source is
// likely UYVY-with-byte-order-different and the right format is
// .gbgr422; the math below stays the same, only the format binding
// in StereoCompositor.swift changes.
fragment half4 sbs_fragment_uyvy(SbSVaryings in [[stage_in]],
                                 texture2d<half> source [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    half4 sample = source.sample(s, in.uv);

    half y  = sample.r;
    half cb = sample.g - 0.5h;
    half cr = sample.b - 0.5h;

    y  = (y - 16.0h / 255.0h) * (255.0h / 219.0h);
    cb = cb * (255.0h / 224.0h);
    cr = cr * (255.0h / 224.0h);

    half r = y + 1.5748h * cr;
    half g = y - 0.1873h * cb - 0.4681h * cr;
    half b = y + 1.8556h * cb;

    return half4(saturate(half3(r, g, b)), 1.0h);
}
