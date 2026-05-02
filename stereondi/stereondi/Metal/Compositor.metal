//  Compositor.metal
//
//  Slice #4 stereo compositor — one mode (SbS, no anaglyph). Slice #6
//  added per-eye HIT (sub-pixel via texture-coord offset + hardware
//  bilinear filtering) plus an auto-crop "common region" implemented
//  as a per-side source-UV remap. Slice #7 adds the crop-mode toggle.
//
//  Per-side fragment buffer 0 carries an `AlignmentUniforms` value
//  computed CPU-side from AlignmentState + the source's own width. The
//  shader maps destination UV in [0,1] to source UV in [uMin, uMax],
//  which is the cropped (or full, depending on mode) HIT-translated
//  visible region of the source. The shader itself does NOT branch on
//  the crop mode — the CPU sets `(u_min, u_max)` to the correct
//  window for the mode and the shader's `uv_outside_source` check
//  produces black bars wherever the window pokes outside [0, 1] (the
//  OFF-mode case). The `crop_mode_flag` field is purely informational
//  in the shader for now (0 = auto, 1 = off); future per-mode shader
//  branches (e.g. anaglyph specialization) can read it.

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
// `crop_mode_flag` field is informational only in this slice (0 =
// auto, 1 = off); the (u_min, u_max) the CPU writes already encodes
// the chosen mode's sampling window, and the shader's
// `uv_outside_source` branch handles the OFF-mode black bars.
struct AlignmentUniforms {
    float u_min;
    float u_max;
    float crop_mode_flag;
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
