//  UYVYEncoder.metal
//
//  BT.709 limited-range RGB → packed UYVY 4:2:2 conversion.
//
//  One thread = one UYVY pair (two horizontal source pixels). The
//  Metal grid is sized to (width/2, height); each thread reads two
//  adjacent BGRA texels, computes their per-pixel BT.709 luma plus
//  the chroma of their average, and writes four bytes (U, Y0, V, Y1)
//  into the destination buffer at byte offset (y*bytesPerRow + x*4).
//
//  We can't use a Metal texture for the destination because Metal's
//  `bgrg422`/`gbgr422` formats are read-only on Apple silicon — UYVY
//  must be assembled into a raw byte buffer that CPU code can
//  subsequently `getBytes` on (the pipeline's MTLBuffer is .shared
//  storage so the contents pointer is mapped on completion).

#include <metal_stdlib>
using namespace metal;

// BT.709 limited-range (16..235 luma, 16..240 chroma) encoding.
// Coefficients folded with the limited-range scale-and-offset:
//   Y  = (0.2126R + 0.7152G + 0.0722B) * 219 + 16
//   Cb = (-0.1146R - 0.3854G + 0.5B)   * 224 + 128
//   Cr = (0.5R - 0.4542G - 0.0458B)    * 224 + 128
kernel void bgra_to_uyvy_bt709(
    texture2d<float, access::read> source [[texture(0)]],
    device uchar* uyvy                    [[buffer(0)]],
    constant uint& bytesPerRow            [[buffer(1)]],
    uint2 gid                             [[thread_position_in_grid]]
) {
    const uint pairWidth = source.get_width() / 2;
    const uint height    = source.get_height();
    if (gid.x >= pairWidth || gid.y >= height) {
        return;
    }

    const uint x0 = gid.x * 2;
    const uint x1 = x0 + 1;

    const float4 c0 = source.read(uint2(x0, gid.y));
    const float4 c1 = source.read(uint2(x1, gid.y));

    const float y0 = (0.2126f * c0.r + 0.7152f * c0.g + 0.0722f * c0.b) * 219.0f + 16.0f;
    const float y1 = (0.2126f * c1.r + 0.7152f * c1.g + 0.0722f * c1.b) * 219.0f + 16.0f;

    const float3 avg = 0.5f * (c0.rgb + c1.rgb);
    const float cb = (-0.1146f * avg.r - 0.3854f * avg.g + 0.5f    * avg.b) * 224.0f + 128.0f;
    const float cr = ( 0.5f    * avg.r - 0.4542f * avg.g - 0.0458f * avg.b) * 224.0f + 128.0f;

    const uchar U  = uchar(clamp(round(cb), 0.0f, 255.0f));
    const uchar Y0 = uchar(clamp(round(y0), 0.0f, 255.0f));
    const uchar V  = uchar(clamp(round(cr), 0.0f, 255.0f));
    const uchar Y1 = uchar(clamp(round(y1), 0.0f, 255.0f));

    device uchar* row = uyvy + gid.y * bytesPerRow + gid.x * 4;
    row[0] = U;
    row[1] = Y0;
    row[2] = V;
    row[3] = Y1;
}
