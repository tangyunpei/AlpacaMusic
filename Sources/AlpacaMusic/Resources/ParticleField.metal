#include <metal_stdlib>
using namespace metal;

// Original parametric fields. No position history, allocations, or CPU geometry
// uploads are needed: each stable point samples the same coherent surface.
struct FieldUniforms {
    float4x4 projection;
    float4x4 modelView;
    float4 timing;
    float4 viewport;
    float4 audio;
    float4 bands;
    float4 orbitEnergy;
    float4 orbitPulse;
    uint4 identity;
};

struct FieldPoint {
    float4 position [[position]];
    float size [[point_size]];
    float3 color;
    float opacity;
    float halo;
};

struct FieldBackground {
    float4 position [[position]];
    float2 uv;
};

constant float fieldTau = 6.28318530718;

uint fieldHash(uint x) {
    x ^= x >> 16; x *= 0x7feb352du;
    x ^= x >> 15; x *= 0x846ca68bu;
    return x ^ (x >> 16);
}

float fieldRandom(uint x) { return float(fieldHash(x) & 0x00ffffffu) / 16777216.0; }

float3 fieldRotateX(float3 p, float angle) {
    float c = cos(angle), s = sin(angle);
    return float3(p.x, c * p.y - s * p.z, s * p.y + c * p.z);
}
float3 fieldRotateY(float3 p, float angle) {
    float c = cos(angle), s = sin(angle);
    return float3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
}
float3 fieldRotateZ(float3 p, float angle) {
    float c = cos(angle), s = sin(angle);
    return float3(c * p.x - s * p.y, s * p.x + c * p.y, p.z);
}

// Broad deformation moves neighboring points together. The higher frequency
// layer adds detail without uncorrelated particle tremor or beat phase jumps.
float fieldSwell(float3 p, float time) {
    return sin(dot(p, float3(1.13, 1.57, 0.91)) + time * 0.31) * 0.60
         + sin(dot(p, float3(-2.17, 1.07, 1.71)) - time * 0.23) * 0.28
         + sin(dot(p, float3(3.11, -2.39, 1.23)) + time * 0.41) * 0.12;
}

float fieldPCM(constant float *samples, float position, uint count) {
    float index = clamp(position, 0.0, float(count - 1u));
    uint lower = uint(index), upper = min(count - 1u, lower + 1u);
    return mix(samples[lower], samples[upper], index - float(lower));
}

vertex FieldPoint fieldVertex(uint id [[vertex_id]], constant FieldUniforms &u [[buffer(0)]],
                             constant float *bassPCM [[buffer(1)]],
                             constant float *midPCM [[buffer(2)]],
                             constant float *treblePCM [[buffer(3)]]) {
    FieldPoint out;
    float time = u.timing.x;
    uint grid = uint(u.timing.z);
    uint row = id / (grid * 2u), column = id % (grid * 2u);
    bool fineScope = u.timing.y < 0.5 && id >= u.identity.y;
    if (fineScope) {
        uint local = id - u.identity.y;
        row = local / u.identity.z;
        column = local % u.identity.z;
    }
    uint layer = row % 3u;
    float lane = float(layer);
    uint randomID = id ^ u.identity.x;
    float grain = fieldRandom(randomID + 19u);
    float rarity = fieldRandom(randomID + 317u);
    float phase = fieldRandom(id + 813u) * fieldTau;
    float2 jitter = float2(fieldRandom(id + 37u), fieldRandom(id + 197u)) - 0.5;
    float across = (float(row / 3u) + 0.5 + jitter.y * 0.34) / float(grid / 6u);
    float along = (float(column) + 0.5 + jitter.x * 0.34) / float(grid * 2u);
    if (fineScope) {
        across = (float(row / 3u) + 0.5 + jitter.y * 0.34) / float(u.identity.w);
        along = (float(column) + 0.5 + jitter.x * 0.34) / float(u.identity.z);
    }
    float3 position = 0;
    float3 normal = float3(0, 0, 1);
    float3 color = 0;
    float opacity = 0.8;
    float worldSize = 0.0058;
    float bright = smoothstep(0.945, 0.995, rarity);
    float material = 0.5;
    float bass = u.bands.x, mid = u.bands.y, treble = u.bands.z;
    float measuredBand = 0;
    float rhythmEnergy = 0, rhythmPulse = 0;
    float ribbonEdge = 0;

    if (u.timing.y < 0.5) {
        // Keep the original three-dimensional toroidal veils, inclinations,
        // particle lattice and ambient motion. Cyan/violet/gold layers each
        // receive only their own low/mid/high signed band-pass PCM window.
        float samplePosition = fineScope ? float(column) : along * float(u.identity.z - 1u);
        float sample = layer == 0u ? fieldPCM(bassPCM, samplePosition, u.identity.z)
                     : layer == 1u ? fieldPCM(midPCM, samplePosition, u.identity.z)
                                   : fieldPCM(treblePCM, samplePosition, u.identity.z);
        float sampleUV = samplePosition / float(u.identity.z - 1u);
        float seam = smoothstep(0.0, 0.025, min(sampleUV, 1.0 - sampleUV));
        measuredBand = sample * seam;
        rhythmEnergy = u.orbitEnergy[layer];
        rhythmPulse = u.orbitPulse[layer];
        float angle = along * fieldTau + time * (0.072 + lane * 0.014);
        float crossAngle = across * fieldTau;
        // A genuine attack expands a coherent, uneven veil, then completes
        // its measured release. Keep rotation phase and camera independent of
        // every drum hit, so the structure flows instead of snapping.
        float lobe = cos(angle + lane * 0.73);
        float swellShape = 0.62 + 0.38 * lobe * lobe;
        float pulseTravel = layer == 0u ? 0.145 : layer == 1u ? 0.095 : 0.060;
        float radius = 0.83 + lane * 0.22 + rhythmEnergy * 0.028
                     + rhythmPulse * pulseTravel * swellShape;
        float width = (0.100 + lane * 0.015) * (1.0 + rhythmEnergy * 0.15 + rhythmPulse * 0.62);
        float breath = sin(angle * 2.0 - time * 0.23 + lane * 1.4);
        float displacement = breath * 0.036
                           + sin(angle * 5.0 + crossAngle * 1.6 + time * 0.33) * 0.012
                           + measuredBand * (0.30 + rhythmPulse * 0.12);
        float section = width * (1.0 + sin(angle * 3.0 - time * 0.18) * 0.22 + measuredBand * 0.15);
        float radial = radius + cos(crossAngle) * section + displacement;
        position = float3(cos(angle) * radial, sin(angle) * radial,
                          sin(crossAngle) * section * 0.72 + sin(angle * 2.0 + time * 0.17) * 0.045);
        normal = normalize(float3(cos(angle) * cos(crossAngle), sin(angle) * cos(crossAngle), sin(crossAngle)));
        float tiltX = 0.48 + lane * 0.29 + sin(time * 0.091 + lane * 1.7) * 0.07;
        float tiltY = -0.25 + lane * 0.27 + cos(time * 0.074 + lane) * 0.06;
        float tiltZ = -0.34 + lane * 0.46;
        position = fieldRotateZ(fieldRotateY(fieldRotateX(position, tiltX), tiltY), tiltZ);
        normal = fieldRotateZ(fieldRotateY(fieldRotateX(normal, tiltX), tiltY), tiltZ);
        position += normal * fieldSwell(position, time) * 0.009;
        float arc = pow(0.5 + 0.5 * sin(angle * 1.7 - time * 0.29 + lane * 2.1), 4.0);
        float3 base = layer == 0u ? float3(0.10, 0.44, 0.48)
                    : layer == 1u ? float3(0.37, 0.32, 0.65) : float3(0.72, 0.43, 0.24);
        float3 pearl = layer == 2u ? float3(1.0, 0.82, 0.59) : float3(0.65, 0.90, 0.98);
        color = mix(base, pearl, min(0.92, arc * 0.50 + bright * 0.25 + rhythmPulse * 0.25));
        material = 0.25 + arc * 0.62;
        worldSize = (0.0049 + grain * 0.0017 + bright * 0.0014) * (1.0 + rhythmPulse * 0.24);
        opacity = min(0.96, (0.64 + arc * 0.20) * (1.0 + rhythmPulse * 0.25));
        if (fineScope) {
            // Every one of the 1,024 PCM samples has a stable angular column.
            // These fine points are invisible without measured displacement,
            // leaving the original ambient lattice exactly intact. A narrow
            // measured peak therefore survives even between baseline columns.
            opacity *= smoothstep(0.0001, 0.015, abs(measuredBand)) * 0.44;
            worldSize *= 0.74;
        }
    } else if (u.timing.y < 1.5) {
        // The original soft, three-dimensional sheets keep their own flow.
        // Peach/violet/jade receive only low/mid/high signed PCM and that same
        // band's measured envelope and complete attack/release. Nothing in the
        // soundtrack changes the time phase, camera, or another sheet's pose.
        float samplePosition = along * float(u.identity.z - 1u);
        float sample = layer == 0u ? fieldPCM(bassPCM, samplePosition, u.identity.z)
                     : layer == 1u ? fieldPCM(midPCM, samplePosition, u.identity.z)
                                   : fieldPCM(treblePCM, samplePosition, u.identity.z);
        float ends = smoothstep(0.0, 0.055, along) * (1.0 - smoothstep(0.945, 1.0, along));
        measuredBand = sample * ends;
        rhythmEnergy = u.orbitEnergy[layer];
        rhythmPulse = u.orbitPulse[layer];

        float x = (along - 0.5) * 4.7;
        float s = x * 0.84 + lane * 1.63;
        // Broad low-frequency swells, rolling mid-frequency pleats, and fine
        // high-frequency ruffles share a continuous spatial carrier. Its
        // amplitude opens only when the corresponding measured band arrives.
        float foldFrequency = layer == 0u ? 0.94 : layer == 1u ? 2.75 : 6.30;
        float foldPhase = x * foldFrequency - time * (0.22 + lane * 0.04) + lane * 1.43;
        float foldAmount = layer == 0u ? rhythmEnergy * 0.15 + rhythmPulse * 0.28
                         : layer == 1u ? rhythmEnergy * 0.075 + rhythmPulse * 0.145
                                       : rhythmEnergy * 0.015 + rhythmPulse * 0.034;
        float depthAmount = foldAmount * (layer == 0u ? 0.72 : layer == 1u ? 0.64 : 0.45);
        float centerY = (lane - 1.0) * 0.64
                      + sin(s + time * 0.19) * 0.36
                      + sin(x * 1.51 - time * 0.135 + lane * 2.1) * 0.16
                      + sin(foldPhase) * foldAmount;
        float centerZ = sin(x * 0.62 + time * 0.16 + lane * 2.4) * 0.57
                      + cos(foldPhase * 0.86 + lane) * depthAmount;
        float rollAmount = layer == 0u ? rhythmEnergy * 0.13 + rhythmPulse * 0.26
                         : layer == 1u ? rhythmEnergy * 0.22 + rhythmPulse * 0.43
                                       : rhythmEnergy * 0.065 + rhythmPulse * 0.13;
        float twist = sin(x * 0.70 - time * 0.23 + lane * 2.2) * 1.18
                    + sin(x * 1.37 + time * 0.105 + lane) * 0.28
                    + cos(foldPhase * 0.67) * rollAmount;
        float spread = layer == 0u ? rhythmEnergy * 0.26 + rhythmPulse * 0.62
                     : layer == 1u ? rhythmEnergy * 0.15 + rhythmPulse * 0.32
                                   : rhythmEnergy * 0.065 + rhythmPulse * 0.14;
        float width = (0.56 + 0.10 * sin(s - time * 0.21)) * (1.0 + spread);
        float transverse = (across - 0.5) * width;
        float3 lateral = float3(0, cos(twist), sin(twist));
        float slopeY = cos(s + time * 0.19) * 0.3024
                     + cos(x * 1.51 - time * 0.135 + lane * 2.1) * 0.2416
                     + cos(foldPhase) * foldFrequency * foldAmount;
        float slopeZ = cos(x * 0.62 + time * 0.16 + lane * 2.4) * 0.3534
                     - sin(foldPhase * 0.86 + lane) * foldFrequency * 0.86 * depthAmount;
        normal = normalize(cross(float3(1, slopeY, slopeZ), lateral));
        position = float3(x, centerY, centerZ) + transverse * lateral;
        ribbonEdge = pow(abs(across - 0.5) * 2.0, 5.0);
        float swell = fieldSwell(position + lane * 0.6, time);
        position += normal * swell * 0.034;
        // The waveform remains a signed, band-limited displacement. Treble is
        // deliberately finer and stronger at the selvage, preserving a silky
        // sheet rather than turning its whole surface into trembling points.
        float pcmTravel = layer == 0u ? 0.26 : layer == 1u ? 0.20 : 0.075 + ribbonEdge * 0.09;
        position += normal * measuredBand * pcmTravel * (0.68 + 0.32 * cos(transverse * 5.0));
        float weave = sin(x * 6.2 + across * 3.5 - time * 0.38 + lane);
        float weaveAmount = layer == 0u ? rhythmEnergy * 0.006 + rhythmPulse * 0.014
                          : layer == 1u ? rhythmEnergy * 0.019 + rhythmPulse * 0.044
                                        : (rhythmEnergy * 0.020 + rhythmPulse * 0.048) * (0.30 + ribbonEdge * 0.70);
        position += normal * weave * (0.008 + weaveAmount);
        float lightFlow = pow(0.5 + 0.5 * sin(x * 0.98 - time * 0.30 + lane * 1.8), 3.0);
        float3 base = layer == 0u ? float3(0.58, 0.25, 0.24)
                    : layer == 1u ? float3(0.26, 0.33, 0.63) : float3(0.21, 0.51, 0.47);
        float3 silk = layer == 0u ? float3(1.0, 0.73, 0.51)
                    : layer == 1u ? float3(0.77, 0.70, 0.94) : float3(0.65, 0.89, 0.79);
        float accent = rhythmPulse * (layer == 2u ? 0.14 + ribbonEdge * 0.14 : 0.17);
        color = mix(base, silk, min(0.92, lightFlow * 0.52 + ribbonEdge * 0.13 + bright * 0.15
                                             + rhythmEnergy * 0.10 + accent));
        material = 0.32 + lightFlow * 0.45 + ribbonEdge * 0.10 + rhythmPulse * 0.10;
        worldSize = (0.0054 + grain * 0.0017 + bright * 0.0016) * (1.0 + rhythmPulse * 0.12);
        opacity = min(0.95, (0.65 + lightFlow * 0.19) * (1.0 + rhythmEnergy * 0.08 + rhythmPulse * 0.18)) * ends;
    } else {
        // Six gently curving rivers at independent depths. The wrapped flow
        // parameter is always masked at both ends before a point is respawned.
        uint river = id % 6u;
        float stream = float(river);
        float widthUV = fieldRandom(id + 881u);
        float flow = fract(along + time * (0.023 + stream * 0.0015));
        float x = (flow - 0.5) * 8.6;
        float depthSample = fieldRandom(id + 411u);
        float depth = -4.8 + depthSample * 6.05;
        float y = (stream - 2.5) * 0.52
                + sin(flow * fieldTau * 0.78 + stream * 0.52 - time * 0.09) * 0.55
                + (widthUV - 0.5) * 0.38;
        position = float3(x, y, depth);
        float3 current = float3(sin(y * 1.9 + depth * 0.43 + time * 0.16),
                                sin(x * 0.82 + depth * 0.32 - time * 0.12),
                                cos(x * 0.60 + y * 0.83 + time * 0.11));
        position += current * (0.08 + bass * 0.105 + mid * 0.035);
        // A quieter interstellar dust population prevents rigid lane outlines.
        if (grain < 0.19) {
            position.y += (fieldRandom(id + 97u) - 0.5) * 2.3;
            position.z -= 1.2;
        }
        normal = normalize(float3(0.25, 0.35, 1));
        float warm = smoothstep(0.52, 0.96, fieldRandom(id + 1973u));
        color = mix(float3(0.38, 0.61, 0.80), float3(0.93, 0.67, 0.39), warm);
        color = mix(color, float3(0.89, 0.93, 1), bright * 0.67);
        float twinkle = 0.78 + 0.22 * sin(time * (0.17 + grain * 0.25) + phase);
        material = (0.31 + bright * 0.70) * twinkle;
        worldSize = 0.0060 + pow(depthSample, 3.0) * 0.0070 + bright * 0.006;
        opacity = smoothstep(0.0, 0.085, flow) * (1.0 - smoothstep(0.90, 1.0, flow));
        opacity *= (0.42 + depthSample * 0.30 + bright * 0.18) * twinkle;
    }

    float4 viewPosition = u.modelView * float4(position, 1);
    float4 projected = u.projection * viewPosition;
    float distance = max(0.1, -viewPosition.z);
    float2 screen = projected.xy / max(0.01, projected.w);
    float centerDistance = length(screen / float2(0.50, 0.35));
    float centerQuiet = mix(0.62, 1.0, smoothstep(0.15, 1.2, centerDistance));
    float edge = 1.0 - smoothstep(0.82, 1.10, max(abs(screen.x), abs(screen.y)));
    float light = 0.39 + 0.40 * abs(dot(normalize(normal), normalize(float3(-0.45, 0.60, 0.72))));
    float facing = abs(dot(normalize(normal), float3(0, 0, 1)));
    float rim = pow(1.0 - facing, 2.0) * 0.16;
    float soundLight = u.timing.y < 0.5 ? 1.0 + abs(measuredBand) * 0.45 + rhythmEnergy * 0.22 + rhythmPulse * 1.48
                     : u.timing.y < 1.5 ? 1.0 + abs(measuredBand) * 0.36 + rhythmEnergy * 0.24
                                           + rhythmPulse * (0.94 + (layer == 2u ? ribbonEdge * 0.42 : 0.0))
                                        : 1.0 + u.audio.z * 0.21 + treble * bright * 0.28;
    float luma = (0.27 + material * 0.67 + rim) * light * soundLight;
    if (u.timing.y > 1.5) { luma = (0.28 + material * 0.78) * soundLight; }
    out.color = color * luma;
    out.opacity = opacity * centerQuiet * edge;
    // Pixel size follows perspective; sparse nearby points read as luminous
    // beads, while the far surface stays fine and never becomes a solid band.
    out.size = clamp(worldSize * u.viewport.z / distance, 0.80, 5.2);
    if (u.viewport.w > 0.5) { out.size *= 1.13; }
    out.halo = u.timing.w;
    if (out.halo > 0.5) {
        float selection = smoothstep(0.92, 0.985, rarity);
        out.size = min(22.0, out.size * (3.7 + bright * 1.1));
        out.opacity *= selection * (0.10 + material * 0.09) * (1.0 + rhythmPulse * 2.2);
        out.color = color * (0.65 + material * 0.28 + rhythmPulse * 0.42);
        if (fineScope) { out.opacity = 0; }
    }
    out.position = projected;
    if (viewPosition.z > -0.1 || out.opacity < 0.00005) {
        out.position = float4(3, 3, 2, 1); out.size = 1; out.opacity = 0;
    }
    return out;
}

fragment float4 fieldFragment(FieldPoint in [[stage_in]], float2 point [[point_coord]]) {
    float radius = length(point * 2.0 - 1.0);
    if (radius > 1.0) { discard_fragment(); }
    float edge = 1.0 - smoothstep(0.66, 1.0, radius);
    if (in.halo > 0.5) {
        float bloom = exp(-radius * radius * 4.6) * (1.0 - smoothstep(0.8, 1.0, radius));
        return float4(in.color, in.opacity * bloom);
    }
    float body = mix(1.0, 0.60, smoothstep(0.0, 0.78, radius));
    return float4(in.color * body, in.opacity * edge);
}

vertex FieldBackground fieldBackgroundVertex(uint id [[vertex_id]]) {
    float2 p = id == 0u ? float2(-1, -1) : id == 1u ? float2(3, -1) : float2(-1, 3);
    FieldBackground out;
    out.position = float4(p, 0.999, 1);
    out.uv = p * 0.5 + 0.5;
    return out;
}

fragment float4 fieldBackgroundFragment(FieldBackground in [[stage_in]], constant FieldUniforms &u [[buffer(0)]]) {
    float2 p = in.uv * 2.0 - 1.0;
    float vignette = 1.0 - smoothstep(0.2, 1.5, length(p));
    float3 color = float3(0.0017, 0.0025, 0.0041) + vignette * float3(0.0010, 0.0017, 0.0028);
    float warm = exp(-dot((p - float2(0.50, -0.32)) * float2(1.8, 2.0),
                         (p - float2(0.50, -0.32)) * float2(1.8, 2.0)));
    float cool = exp(-dot((p + float2(0.54, -0.25)) * float2(1.8, 1.7),
                         (p + float2(0.54, -0.25)) * float2(1.8, 1.7)));
    if (u.timing.y < 0.5) {
        color += warm * float3(0.0050, 0.0017, 0.0007) + cool * float3(0.0004, 0.0036, 0.0042);
    } else if (u.timing.y < 1.5) {
        color += warm * float3(0.0058, 0.0016, 0.0013) + cool * float3(0.0017, 0.0019, 0.0055);
    } else {
        color += warm * float3(0.0020, 0.0012, 0.0005) + cool * float3(0.0008, 0.0018, 0.0048);
    }
    return float4(color, 1);
}
