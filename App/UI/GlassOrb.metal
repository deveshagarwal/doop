#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// A clear glass sphere on near-black, shaded analytically. Refraction flips and magnifies the
// faint ember glow behind it (split per channel for a touch of dispersion); a soft highlight,
// a thin bright edge and an ember rim define the glass. The radius swells with a lub-dub at
// the wearer's resting heart rate, and an ember warmth pulses at the bottom inside.

static float3 backdrop(float2 uv) {
    float3 col = float3(0.0035, 0.0035, 0.004);
    col += float3(1.0, 0.70, 0.42) * 0.05 * exp(-length((uv - float2(0.05, 0.20)) * float2(1.0, 1.3)) * 5.5);
    col += float3(0.94, 0.91, 0.87) * 0.012 * exp(-length(uv - float2(0.0, 0.14)) * 3.0);
    return col;
}

[[ stitchable ]] half4 glassOrb(float2 pos, half4 color, float2 size, float time, float bpm, float motion) {
    float2 uv = (pos - 0.5 * size) / size.y;
    uv.y = -uv.y;
    float ph = fract(time * bpm / 60.0);
    float beat = (exp(-pow(ph * 8.0, 2.0)) + 0.6 * exp(-pow((ph - 0.21) * 8.0, 2.0))) * motion;
    float r = 0.145 * (1.0 + 0.09 * beat);
    float2 c = float2(0.0, 0.14);

    float3 col = backdrop(uv);
    float2 d = (uv - c) / r;
    float len = length(d);
    float aa = 1.5 / (r * size.y);
    float m = 1.0 - smoothstep(1.0 - aa, 1.0, len);

    if (len < 1.0) {
        float nz = sqrt(max(1.0 - len * len, 0.0));
        float3 n = float3(d, nz);
        float fr = 0.04 + 0.96 * pow(1.0 - nz, 5.0);
        float3 refr;
        for (int i = 0; i < 3; i++) {
            float bend = (0.8 + 0.04 * float(i)) * (1.0 + 0.8 * (1.0 - nz));
            refr[i] = backdrop(c - d * r * bend)[i];
        }
        float3 body = refr * 1.05;
        float2 h = d - float2(0.12, -0.6);
        body += float3(1.0, 0.70, 0.42) * (0.03 + 0.12 * beat) * exp(-dot(h, h) * 12.0);
        body *= mix(1.0, 0.55, smoothstep(0.85, 1.0, len));
        float2 bp = (d - float2(-0.36, 0.42)) * float2(1.0, 1.5);
        float box = exp(-dot(bp, bp) * 22.0);
        float rim = pow(1.0 - nz, 2.5) * smoothstep(0.0, 0.9, n.x) * smoothstep(-0.7, 0.5, n.y);
        float2 sp = d - float2(-0.18, 0.6);
        float spark = exp(-dot(sp, sp) * 900.0);
        float edge = exp(-pow((1.0 - len) * size.y * r * 0.09, 2.0));
        float3 ball = body * (1.0 - fr) + float3(0.94, 0.91, 0.87) * box * 0.35 + float3(1.0, 0.70, 0.42) * rim * 0.45
                    + float3(1.0) * spark * 0.9 + float3(0.94, 0.91, 0.87) * (fr * 0.55 + edge * 0.22);
        col = mix(col, ball, m);
    }
    col = pow(max(col, 0.0), float3(1.0 / 2.2));
    return half4(half3(col), 1.0h);
}
