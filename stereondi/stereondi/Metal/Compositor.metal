//  Compositor.metal
//
//  Slice #4 stereo compositor — one mode (SbS, no anaglyph). Slice #6
//  added per-eye HIT (sub-pixel via texture-coord offset + hardware
//  bilinear filtering) plus an auto-crop "common region" implemented
//  as a per-side source-UV remap. Slice #7 added the crop-mode toggle.
//  Slice #8 adds two new screen-only modes: pure-luma red/cyan
//  anaglyph and a sources-bypassed channel test.
//
//  Per-side SbS fragment buffer 0 carries an `AlignmentUniforms` value
//  computed CPU-side from AlignmentState + the source's own width. The
//  shader maps destination UV in [0,1] to source UV in [uMin, uMax],
//  which is the cropped (or full, depending on mode) HIT-translated
//  visible region of the source. The shader itself does NOT branch on
//  the crop mode — the CPU sets `(u_min, u_max)` to the correct
//  window for the mode and the shader's `uv_outside_source` check
//  produces black bars wherever the window pokes outside [0, 1] (the
//  OFF-mode case). The `crop_mode_flag` field is purely informational
//  in the shader for now (0 = auto, 1 = off); future per-mode shader
//  branches can read it.
//
//  Anaglyph and channel-test draw a single full-frame quad (NDC
//  (-1,-1)→(+1,+1), UV (0,0)→(1,1)) instead of the per-side
//  aspect-fit halves used by SbS. Anaglyph samples both sources in
//  one fragment invocation using per-side `AnaglyphSideUniforms`
//  carrying the source's aspect-fit subrect within the full output
//  plus the same `(u_min, u_max)` HIT/crop window the SbS path uses.
//  Channel-test bypasses sources entirely.

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

// Slice #8: per-side payload for the anaglyph shader. Carries the
// destination subrect (in full-frame UV space) where this source's
// aspect-fit lives, plus the SbS-style (u_min, u_max) HIT/crop
// sampling window in source UV (X axis), plus a decode flag (0 =
// BGRA, 1 = UYVY/.bgrg422). The single combined draw lets us keep
// one anaglyph pipeline regardless of whether the two sources are
// BGRA-BGRA, BGRA-UYVY, or UYVY-UYVY.
struct AnaglyphSideUniforms {
    float dst_uv_x_min;
    float dst_uv_x_max;
    float dst_uv_y_min;
    float dst_uv_y_max;
    float u_min;
    float u_max;
    uint  decode_mode;
    uint  _padding;
};

struct AnaglyphUniforms {
    AnaglyphSideUniforms red_side;   // luma → red channel
    AnaglyphSideUniforms cyan_side;  // luma → green + blue channels
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

// MARK: - Slice #8: anaglyph + channel-test (full-frame quad)

// Fullscreen quad for the screen-only modes. Two triangles emitted as
// a strip from CPU side via -drawPrimitives, vertex 0..3 = TL, BL, TR,
// BR with UV (0,0) at top-left to match the SbS convention.
struct FullFrameVaryings {
    float4 position [[position]];
    float2 uv;
};

vertex FullFrameVaryings fullframe_vertex(SbSVertexIn in [[stage_in]]) {
    FullFrameVaryings out;
    out.position = float4(in.position, 0.0, 1.0);
    out.uv = in.uv;
    return out;
}

// BT.709 limited-range YCbCr → full-range RGB, identical to the SbS
// UYVY path. Returns full-range RGB in [0, 1].
static inline half3 decode_uyvy_sample_to_rgb(half4 sample) {
    half y  = sample.r;
    half cb = sample.g - 0.5h;
    half cr = sample.b - 0.5h;

    y  = (y - 16.0h / 255.0h) * (255.0h / 219.0h);
    cb = cb * (255.0h / 224.0h);
    cr = cr * (255.0h / 224.0h);

    half r = y + 1.5748h * cr;
    half g = y - 0.1873h * cb - 0.4681h * cr;
    half b = y + 1.8556h * cb;
    return saturate(half3(r, g, b));
}

// BT.709 luma weights — same coefficients used by NDI's BT.709
// limited-range pipeline. Operates on full-range linear-ish RGB
// values (the bilinear filter delivers them in the source's gamma
// space, but for an alignment view that's fine — we want consistency
// with what the operator's eye perceives, not photometric accuracy).
static inline half luma_bt709(half3 rgb) {
    return 0.2126h * rgb.r + 0.7152h * rgb.g + 0.0722h * rgb.b;
}

// Sample one source for the anaglyph compose. Returns (luma, in_bounds)
// where `in_bounds` is 0 outside the destination subrect or outside
// the [0, 1] post-HIT source-U window (the same out-of-source behavior
// as the SbS path's black bars), 1 otherwise.
static inline half2 anaglyph_sample_luma(float2 uvFull,
                                         AnaglyphSideUniforms side,
                                         texture2d<half> source) {
    if (uvFull.x < side.dst_uv_x_min || uvFull.x > side.dst_uv_x_max ||
        uvFull.y < side.dst_uv_y_min || uvFull.y > side.dst_uv_y_max) {
        return half2(0.0h, 0.0h);
    }
    float dst_w = max(side.dst_uv_x_max - side.dst_uv_x_min, 1e-6f);
    float dst_h = max(side.dst_uv_y_max - side.dst_uv_y_min, 1e-6f);
    float2 dst_local = float2((uvFull.x - side.dst_uv_x_min) / dst_w,
                              (uvFull.y - side.dst_uv_y_min) / dst_h);
    float src_u = side.u_min + dst_local.x * (side.u_max - side.u_min);
    if (src_u < 0.0f || src_u > 1.0f) {
        return half2(0.0h, 0.0h);
    }
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    half4 sample = source.sample(s, float2(src_u, dst_local.y));
    half3 rgb = (side.decode_mode == 1u) ? decode_uyvy_sample_to_rgb(sample)
                                         : sample.rgb;
    return half2(luma_bt709(rgb), 1.0h);
}

// Pure-luma red/cyan anaglyph. The "red side" texture is the source
// whose luma drives the red channel; the "cyan side" texture's luma
// drives green + blue. CPU-side swap-eyes is implemented by swapping
// which source is bound where (no shader branch needed).
fragment half4 fragment_anaglyph(FullFrameVaryings in [[stage_in]],
                                 texture2d<half> red_source [[texture(0)]],
                                 texture2d<half> cyan_source [[texture(1)]],
                                 constant AnaglyphUniforms& uniforms [[buffer(0)]]) {
    half2 red_sample  = anaglyph_sample_luma(in.uv, uniforms.red_side,  red_source);
    half2 cyan_sample = anaglyph_sample_luma(in.uv, uniforms.cyan_side, cyan_source);
    half red  = red_sample.x;
    half cyan = cyan_sample.x;
    return half4(red, cyan, cyan, 1.0h);
}

// Channel-test: solid red on the left half, solid cyan on the right
// half. Sources are not bound — the operator uses this to verify
// glasses orientation before doing alignment work, so the shader is
// deliberately source-independent.
fragment half4 fragment_channeltest(FullFrameVaryings in [[stage_in]]) {
    if (in.uv.x < 0.5f) {
        return half4(1.0h, 0.0h, 0.0h, 1.0h);
    }
    return half4(0.0h, 1.0h, 1.0h, 1.0h);
}
