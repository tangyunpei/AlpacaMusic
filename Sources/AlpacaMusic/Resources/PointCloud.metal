#include <metal_stdlib>
using namespace metal;

struct CloudPoint {
    float4 positionDepthSeed;
    float4 colorLuminance;
    float4 scatter;
    float4 geometryFeatures; // contour anchor, grain footprint, region phase, abstraction
};
struct CloudUniforms {
    float4x4 projection;
    float4x4 modelView;
    float4 motion;    // time, bass energy, beat pulse, assembly progress
    float4 shape;     // depth, bounce, idle, point size
    float4 wave;      // frequency, speed, invert, scheme
    float4 behavior;  // beat pop, motion enabled, dissolve, opacity
    float4 viewport;  // projection scale, halo pass, density compensation, focal distance
};
struct PointOutput {
    float4 position [[position]];
    float pointSize [[point_size]];
    float3 color;
    float opacity;
    float halo;
    float softness;
};

// A single position function is shared by rasterization and the test-only
// compute probe appended by DepthTests. Axis checks exercise the real GPU math.
float3 cloudPosition(CloudPoint point, constant CloudUniforms &u) {
    float2 base = point.positionDepthSeed.xy;
    float depth = mix(point.positionDepthSeed.z, 1.0 - point.positionDepthSeed.z, u.wave.z);
    float seed = point.positionDepthSeed.w;
    float abstraction = saturate(point.geometryFeatures.w);
    float regionPhase = point.geometryFeatures.z * 6.2831853;
    float3 p = float3(base, (depth - 0.5) * u.shape.x * 2.0);
    // A low-frequency volume belongs to each color region, rather than to the
    // source pixel grid. Its resting shape survives pause / reduced motion.
    float contour = sin(base.x * 2.1 + regionPhase * 0.34) * cos(base.y * 1.8 - regionPhase * 0.21);
    p.z += contour * abstraction * u.shape.x * 0.24;
    float weight = 0.8 + 0.4 * depth;
    // The image sampler identifies color/alpha boundaries and fine detail.
    // Pin those features more strongly than flat regions, so a bass accent
    // never pulls lettering or a face apart into independent moving points.
    float protection = mix(1.0, 0.16, saturate(point.geometryFeatures.x));
    float edge = 1.0 - smoothstep(0.70, 1.0, max(abs(base.x), abs(base.y)));
    float envelope = mix(0.30, 1.0, edge) * protection;
    float idle = sin(u.motion.x * 0.65 + base.x * 1.3 + base.y * 0.9) * min(0.008, u.shape.z * 0.32);
    float wave = sin(base.x * min(u.wave.x, 6.0) * 0.55 - u.motion.x * u.wave.y * 0.35 + depth * 0.65 + regionPhase * abstraction * 0.28);
    float breath = sin(u.motion.x * 0.42 + base.y * 1.9 + regionPhase * 0.2) * min(0.012, u.shape.z * 0.35) * abstraction;
    float continuous = (idle + breath + wave * u.shape.y * (0.11 + abstraction * 0.035) * u.motion.y * weight) * u.behavior.y * envelope;
    float beat = u.motion.z * u.behavior.y;
    float kick = beat * u.shape.y * 0.025 * weight * envelope;
    float pop = beat * u.behavior.x;
    float a = 1.0 - u.wave.w, b = u.wave.w;
    // A: only Y carries a continuous wave. B: only Z. The remaining axes
    // move exclusively during beat accents; relief remains static on Z.
    float displacement = clamp(continuous + kick, -0.04 - abstraction * 0.02, 0.04 + abstraction * 0.02);
    p.y += displacement * a;
    p.z += displacement * b;
    p.z += pop * (0.018 + abstraction * 0.022) * depth * protection * a;
    // A coherent scale accent reads as a pulse, without distorting the image.
    p.xy *= 1.0 + pop * (0.005 + abstraction * 0.014);
    float progress = clamp(u.motion.w * 1.25 - seed * 0.25, 0.0, 1.0);
    float ease = 1.0 - pow(1.0 - progress, 3.0);
    p = mix(point.scatter.xyz, p, ease);
    p = mix(p, point.scatter.xyz, u.behavior.z * 0.32);
    return p;
}

vertex PointOutput cloudVertex(uint id [[vertex_id]],
                              const device CloudPoint *points [[buffer(0)]],
                              constant CloudUniforms &u [[buffer(1)]]) {
    CloudPoint point = points[id];
    float3 p = cloudPosition(point, u);
    float beat = u.motion.z * u.behavior.y;
    float4 viewPosition = u.modelView * float4(p, 1.0);
    PointOutput output;
    output.position = u.projection * viewPosition;
    float densityScale = u.viewport.z > 0.0 ? u.viewport.z : 1.0;
    float detail = saturate(point.geometryFeatures.x);
    float abstraction = saturate(point.geometryFeatures.w);
    float footprint = clamp(1.05 + (u.shape.w - 1.8) * 0.16, 0.78, 1.35);
    // Tie the splat to its source cell rather than arbitrary screen pixels.
    // The density multiplier preserves coverage at all quality tiers.
    float spacing = (2.0 / 159.0) * densityScale;
    float diameter = spacing * footprint * max(0.5, point.geometryFeatures.y);
    // In the painterly cloud, visible air separates pigment grains. Spatially
    // varying source footprints still cluster them into coherent color masses.
    diameter *= mix(1.0, 0.95, detail) * mix(1.0, 0.76, abstraction) * (1.0 + beat * (0.06 + abstraction * 0.08));
    bool halo = u.viewport.y > 0.5;
    output.pointSize = clamp(diameter * (halo ? 1.8 : 1.0) * u.viewport.x / max(0.1, -viewPosition.z), mix(0.9, 0.65, abstraction), 32.0);
    // The core always uses ordinary alpha compositing and unmodified linear
    // sampled pigment color. Glow is a separate, faint underlay; it cannot replace
    // dark ink with additive light or overexpose the photograph's highlights.
    output.color = point.colorLuminance.rgb;
    float haloAlpha = (0.045 + beat * 0.02) * (1.0 - detail * 0.65) * (1.0 - point.colorLuminance.w * 0.70);
    // Dust from a flat background has no luminous veil. Keep a little halo
    // around larger pigment grains and macro contours to reveal their depth.
    float pigmentHalo = smoothstep(0.9, 1.65, point.geometryFeatures.y) * 0.72 + detail * 0.20;
    haloAlpha *= mix(1.0, pigmentHalo, saturate(abstraction * 1.4));
    float regionalCoverage = mix(1.0, 0.90 + 0.10 * sin(point.geometryFeatures.z * 6.2831853), abstraction);
    output.opacity = u.behavior.w * point.scatter.w * (halo ? haloAlpha : regionalCoverage);
    output.halo = halo ? 1.0 : 0.0;
    output.softness = abstraction;
    return output;
}

fragment float4 cloudFragment(PointOutput point [[stage_in]], float2 coordinate [[point_coord]]) {
    float radius = length(coordinate - 0.5);
    if (radius > 0.5) discard_fragment();
    float alpha = point.halo > 0.5
        ? exp(-radius * radius * 18.0) * (1.0 - smoothstep(0.40, 0.50, radius))
        : 1.0 - smoothstep(mix(0.43, 0.37, point.softness), 0.50, radius);
    return float4(point.color, alpha * point.opacity);
}
