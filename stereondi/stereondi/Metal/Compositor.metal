//  Compositor.metal
//
//  Slice #4 stereo compositor — one mode (SbS, no anaglyph). Slice #6
//  adds per-eye HIT (sub-pixel via texture-coord offset + hardware
//  bilinear filtering) plus an auto-crop "common region" implemented
//  as a per-side source-UV remap. Slice #7 will add anaglyph and the
//  channel-test mode and toggle the auto-crop OFF.
//
//  Per-side fragment buffer 0 carries an `AlignmentUniforms` value
//  computed CPU-side from AlignmentState + the source's own width. The
//  shader maps destination UV in [0,1] to source UV in [uMin, uMax],
//  which is the auto-cropped + HIT-translated visible region of the
//  source. With auto-crop the mapped UV is always in [0,1] so the
//  out-of-range black check below is dead-code in this slice — it
//  exists ahead of the slice #7 OFF mode where uMin can go negative
//  and uMax can exceed 1, and we want black bars on the missing edge
//  rather than clamp-to-edge smearing.

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

// Per-side alignment uniforms. Layout matches the Swift
// `StereoCompositor.AlignmentUniforms` struct exactly. The
// `reservedCrop` field is unused this slice (slice #7 will repurpose
// it as a crop-mode flag); kept here so the layout stays stable.
struct AlignmentUniforms {
    float u_min;
    float u_max;
    float reserved_crop;
    float _padding;
};

vertex SbSVaryings sbs_vertex(SbSVertexIn in [[stage_in]]) {
    SbSVaryings out;
    out.position = float4(in.position, 0.0, 1.0);
    out.uv = in.uv;
    return out;
}

// Map destination UV ∈ [0,1] to source UV ∈ [u_min, u_max]. Y is
// untouched — HIT is a horizontal (U) operation only.
static inline float2 remapped_source_uv(float2 dst_uv, constant AlignmentUniforms& a) {
    float src_u = a.u_min + dst_uv.x * (a.u_max - a.u_min);
    return float2(src_u, dst_uv.y);
}

static inline bool uv_outside_source(float2 src_uv) {
    return src_uv.x < 0.0f || src_uv.x > 1.0f;
}

fragment half4 sbs_fragment_bgra(SbSVaryings in [[stage_in]],
                                 texture2d<half> source [[texture(0)]],
                                 constant AlignmentUniforms& alignment [[buffer(0)]]) {
    float2 src_uv = remapped_source_uv(in.uv, alignment);
    if (uv_outside_source(src_uv)) {
        return half4(0.0h, 0.0h, 0.0h, 1.0h);
    }
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    half4 c = source.sample(s, src_uv);
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
                                 texture2d<half> source [[texture(0)]],
                                 constant AlignmentUniforms& alignment [[buffer(0)]]) {
    float2 src_uv = remapped_source_uv(in.uv, alignment);
    if (uv_outside_source(src_uv)) {
        return half4(0.0h, 0.0h, 0.0h, 1.0h);
    }
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    half4 sample = source.sample(s, src_uv);

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
