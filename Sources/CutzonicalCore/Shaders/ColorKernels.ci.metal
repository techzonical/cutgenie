#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

// Colour wheels (global / shadows / midtones / highlights), computed in float on the encoded values.
// lw   = luma weights (Rec.709 or Rec.2020)
// gT.. = colour offsets per wheel (already made luma-neutral on the CPU when Preserve Luma is on)
// sat  = saturation factor per wheel (global, shadows, mids, highlights); 1 = unchanged
// bri  = brightness offset per wheel; 0 = unchanged
// ---- colour space conversion -------------------------------------------------------------------------------------
// Linear unit L: 1.0 = diffuse white (SDR 100 nits, HDR 203 nits). Transfer ids: 0 Rec.709 (BT.1886, gamma 2.4),
// 1 sRGB, 2 HLG, 3 PQ, 4 S-Log3. Primaries are converted with a 3x3 matrix in linear light.
constant float HLG_A = 0.17883277, HLG_B = 0.28466892, HLG_C = 0.55991073;
constant float HLG_PEAK = 1000.0, REFWHITE = 203.0, HLG_GAMMA = 1.2;
constant float3 LUMA2020 = float3(0.2627, 0.6780, 0.0593);

float3 decodeTF(float3 v, int tf) {
    if (tf == 0) return pow(max(v, 0.0), 2.4);
    if (tf == 1) { float3 lo = v / 12.92; float3 hi = pow((max(v, 0.0) + 0.055) / 1.055, 2.4); return select(hi, lo, v <= 0.04045); }
    if (tf == 2) {   // HLG signal -> scene linear -> display light (OOTF gamma 1.2, 1000 nit) -> units of reference white
        float3 e = max(v, 0.0);
        float3 es = select((exp((e - HLG_C) / HLG_A) + HLG_B) / 12.0, (e * e) / 3.0, e <= 0.5);
        float ys = dot(es, LUMA2020);
        return es * pow(max(ys, 1e-6), HLG_GAMMA - 1.0) * (HLG_PEAK / REFWHITE);
    }
    if (tf == 3) {   // PQ
        const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
        float3 np = pow(max(v, 0.0), 1.0 / m2);
        float3 l = pow(max(np - c1, 0.0) / (c2 - c3 * np), 1.0 / m1);
        return l * (10000.0 / REFWHITE);
    }
    // S-Log3 -> scene reflectance (18% grey = 0.18), 90% white = diffuse white
    float3 x = v * 1023.0;
    float3 hi = pow(10.0, (x - 420.0) / 261.5) * 0.19 - 0.01;
    float3 lo = (x - 95.0) * 0.01125 / (171.2102946929 - 95.0);
    return select(lo, hi, v >= 171.2102946929 / 1023.0) / 0.9;
}

float3 encodeTF(float3 l, int tf) {
    l = max(l, 0.0);
    if (tf == 0) return pow(l, 1.0 / 2.4);
    if (tf == 1) { float3 lo = l * 12.92; float3 hi = 1.055 * pow(l, 1.0 / 2.4) - 0.055; return select(hi, lo, l <= 0.0031308); }
    if (tf == 2) {
        float3 fd = l * (REFWHITE / HLG_PEAK);
        float yd = dot(fd, LUMA2020);
        float3 es = fd * pow(max(yd, 1e-6), (1.0 - HLG_GAMMA) / HLG_GAMMA);
        return select(HLG_A * log(max(12.0 * es - HLG_B, 1e-6)) + HLG_C, sqrt(3.0 * es), es <= 1.0 / 12.0);
    }
    if (tf == 3) {
        const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
        float3 y = pow(l * (REFWHITE / 10000.0), m1);
        return pow((c1 + c2 * y) / (1.0 + c3 * y), m2);
    }
    float3 r = l * 0.9;
    float3 hi = (420.0 + log(max((r + 0.01) / 0.19, 1e-6)) / log(10.0) * 261.5) / 1023.0;
    float3 lo = (r * (171.2102946929 - 95.0) / 0.01125 + 95.0) / 1023.0;
    return select(hi, lo, r < 0.01125);
}

// Soft roll-off for HDR -> SDR: unchanged up to the knee, then eases toward 1.0 instead of clipping.
float3 toneMapSoft(float3 c) {
    const float knee = 0.75;
    float y = dot(c, float3(0.2126, 0.7152, 0.0722));
    if (y <= knee) return c;
    float y2 = knee + (1.0 - knee) * (1.0 - exp(-(y - knee) / (1.0 - knee)));
    return c * (y2 / y);
}

extern "C" { namespace coreimage {
// Window display curve only (never used for renders/exports): matches how Final Cut's viewer shows Rec.709 pictures.
float4 cutzonicalDisplay(sample_t s, float g, float3 gain) { return float4(pow(max(s.rgb, 0.0), float3(g)) * gain, s.a); }

// tf = (in, out, toneMap 0 clip / 1 soft, hdrToSdr flag); rows = 3x3 primaries conversion (linear light)
float4 cutzonicalConvert(sample_t s, float4 tf, float3 r0, float3 r1, float3 r2) {
    float3 l = decodeTF(s.rgb, int(tf.x));
    l = float3(dot(r0, l), dot(r1, l), dot(r2, l));
    if (tf.w > 0.5) { l = (tf.z > 0.5) ? toneMapSoft(max(l, 0.0)) : min(max(l, 0.0), 1.0); }
    float3 o = encodeTF(l, int(tf.y));
    return float4(o, s.a);
}

float4 cutzonicalWheels(sample_t s, float3 lw, float3 gT, float3 sT, float3 mT, float3 hT, float4 sat, float4 bri, float2 shape) {
    float3 c = s.rgb;
    float Y = dot(c, lw);
    // Tonal reach of each wheel, fitted to a Final Cut export (see PROTOTYPE.md): shadows (1-Y)^p, highlights Y^p,
    // midtones a bell of height shape.y. Low p = reaches far across the picture, high p = only the extremes.
    float yc = clamp(Y, 0.0, 1.0);
    float ws = pow(1.0 - yc, shape.x);
    float wh = pow(yc, shape.x);
    float wm = shape.y * 4.0 * yc * (1.0 - yc);
    float3 o = c + gT + bri.x
                 + ws * (sT + bri.y) + wm * (mT + bri.z) + wh * (hT + bri.w);
    float f = sat.x + ws * (sat.y - 1.0) + wm * (sat.z - 1.0) + wh * (sat.w - 1.0);
    float Yo = dot(o, lw);
    o = float3(Yo) + (o - float3(Yo)) * f;
    return float4(o, s.a);
}
}}
