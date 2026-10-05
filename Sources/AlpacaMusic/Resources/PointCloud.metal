#include <metal_stdlib>
using namespace metal;

struct CloudPoint {
    float4 positionDepthSeed;
    float4 colorLuminance;
    float4 scatter;
};
struct CloudUniforms {
    float4x4 projection;
    float4x4 modelView;
    float4 motion;    // time, bass energy, beat pulse, assembly progress
    float4 shape;     // depth, bounce, idle, point size
    float4 wave;      // frequency, speed, invert, scheme
    float4 behavior;  // beat pop, motion enabled, dissolve, opacity
    float4 viewport;  // projection scale, glow, density compensation, focal distance
};
struct PointOutput {
    float4 position [[position]];
    float pointSize [[point_size]];
    float3 color;
    float opacity;
    float softness;
};

// A single position function is shared by rasterization and the test-only
// compute probe appended by DepthTests. Axis checks exercise the real GPU math.
float3 cloudPosition(CloudPoint point, constant CloudUniforms &u) {
    float2 base = point.positionDepthSeed.xy;
    float depth = mix(point.positionDepthSeed.z, 1.0 - point.positionDepthSeed.z, u.wave.z);
    float seed = point.positionDepthSeed.w;
    float3 p = float3(base, (depth - 0.5) * u.shape.x * 2.0);
    float weight = 0.7 + 0.6 * depth;
    // Coherent, slow breathing keeps lettering and silhouettes legible. The
    // boundary moves less than the interior instead of fraying into noise.
    float edge = 1.0 - smoothstep(0.70, 1.0, max(abs(base.x), abs(base.y)));
    float envelope = mix(0.24, 1.0, edge);
    float idle = sin(u.motion.x * 0.8 + base.x * 2.0 + base.y * 1.2) * u.shape.z;
    float wave = sin(base.x * u.wave.x - u.motion.x * u.wave.y + depth * 1.5);
    float continuous = (idle + wave * u.shape.y * 1.25 * u.motion.y * weight) * u.behavior.y * envelope;
    float beat = u.motion.z * u.behavior.y;
    float kick = beat * u.shape.y * 0.7 * weight;
    float pop = beat * u.behavior.x;
    float a = 1.0 - u.wave.w, b = u.wave.w;
    // A: only Y carries a continuous wave. B: only Z. The remaining axes
    // move exclusively during beat accents; relief remains static on Z.
    float legibility = max(0.075, u.shape.y * 0.65);
    p.y += clamp(continuous + kick, -legibility, legibility) * a;
    p.z += continuous * b;
    p.z += pop * 0.13 * depth * a;
    p.xy += base * pop * ((0.004 + 0.010 * depth) * a + (0.012 + 0.014 * depth) * b);
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
    float focus = u.viewport.w > 0.0 ? clamp((abs(viewPosition.z + u.viewport.w) - 0.25) * 0.22, 0.0, 0.28) : 0.0;
    output.pointSize = clamp(u.shape.w * 0.0059 * densityScale * (1.0 + beat * 0.22) * (1.0 + focus) * u.viewport.x / max(0.1, -viewPosition.z), 0.9, 24.0);
    // Keep photographic color instead of clipping highlights under additive glow.
    float exposure = u.viewport.y > 0.5 ? 0.67 : 1.0;
    output.color = point.colorLuminance.rgb * exposure * (1.0 + beat * 0.12 + u.motion.y * 0.05);
    output.opacity = u.behavior.w * point.scatter.w * (1.0 - focus * 0.35);
    output.softness = focus;
    return output;
}

fragment float4 cloudFragment(PointOutput point [[stage_in]], float2 coordinate [[point_coord]]) {
    float radius = length(coordinate - 0.5);
    if (radius > 0.5) discard_fragment();
    float alpha = 1.0 - smoothstep(0.27 - point.softness * 0.2, 0.5, radius);
    return float4(point.color, alpha * point.opacity);
}
