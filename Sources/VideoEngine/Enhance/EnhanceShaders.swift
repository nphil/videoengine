// The picture enhancer's GPU kernels, written for this engine in Metal Shading Language and compiled on the device
// the first time the enhancer needs them. Nothing here is copied from another shader: the Lanczos filter, the
// contrast-adaptive sharpen, the edge steepening for line art and the dither follow the published descriptions of
// those techniques. Every read goes through `read()` with explicit clamping, so no sampler state is involved.
//
// The kernels, in the order the chain runs them:
//   ingest_nv12         video-range or full-range NV12 -> BGRA, with the video's own matrix
//   lanczos_horizontal  first half of the separable Lanczos-3 scale (rgba16Float in the middle)
//   lanczos_vertical    second half
//   line_art_steepen    pulls the pixels beside a line toward the side they belong to
//   compose             deband, sharpen and dither in one pass
enum EnhanceShaders {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    constant float3 kLuma = float3(0.2126, 0.7152, 0.0722);
    constant int kTaps = 6;
    constant float2 kRing[8] = {
        float2(1.0, 0.0), float2(0.7071068, 0.7071068), float2(0.0, 1.0), float2(-0.7071068, 0.7071068),
        float2(-1.0, 0.0), float2(-0.7071068, -0.7071068), float2(0.0, -1.0), float2(0.7071068, -0.7071068)
    };

    inline float3 fetch(texture2d<float, access::read> image, int2 position, int2 last) {
        return image.read(uint2(clamp(position, int2(0), last))).rgb;
    }

    inline float3 fetch_linear(texture2d<float, access::read> image, float2 position, int2 last) {
        int2 base = int2(floor(position));
        float2 blend = position - float2(base);
        float3 top = mix(fetch(image, base, last), fetch(image, base + int2(1, 0), last), blend.x);
        float3 bottom = mix(fetch(image, base + int2(0, 1), last), fetch(image, base + int2(1, 1), last), blend.x);
        return mix(top, bottom, blend.y);
    }

    inline float luminance(float3 colour) {
        return dot(colour, kLuma);
    }

    // MurmurHash3's finalizer: turns a counter into well-spread bits.
    inline uint scramble(uint value) {
        value ^= value >> 16;
        value *= 0x85ebca6bu;
        value ^= value >> 13;
        value *= 0xc2b2ae35u;
        value ^= value >> 16;
        return value;
    }

    // 24 random bits as a number in [0, 1).
    inline float unit_noise(uint bits) {
        return float(bits >> 8) * (1.0 / 16777216.0);
    }

    struct IngestParams {
        float yOffset;
        float yScale;
        float cOffset;
        float cScale;
        float kr;
        float kb;
    };

    kernel void ingest_nv12(
        texture2d<float, access::read> luma [[texture(0)]],
        texture2d<float, access::read> chroma [[texture(1)]],
        texture2d<float, access::write> output [[texture(2)]],
        constant IngestParams& p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        int2 size = int2(output.get_width(), output.get_height());
        if (int(gid.x) >= size.x || int(gid.y) >= size.y) { return; }
        int2 last = int2(chroma.get_width(), chroma.get_height()) - 1;

        // 4:2:0 chroma sits on the even columns and halfway between the even and odd rows, as H.264 and HEVC code it.
        float2 at = float2(float(gid.x) * 0.5, (float(gid.y) - 0.5) * 0.5);
        int2 base = int2(floor(at));
        float2 blend = at - float2(base);
        float2 c00 = chroma.read(uint2(clamp(base, int2(0), last))).rg;
        float2 c10 = chroma.read(uint2(clamp(base + int2(1, 0), int2(0), last))).rg;
        float2 c01 = chroma.read(uint2(clamp(base + int2(0, 1), int2(0), last))).rg;
        float2 c11 = chroma.read(uint2(clamp(base + int2(1, 1), int2(0), last))).rg;
        float2 cbcr = mix(mix(c00, c10, blend.x), mix(c01, c11, blend.x), blend.y);

        float y = (luma.read(gid).r - p.yOffset) * p.yScale;
        float cb = (cbcr.x - p.cOffset) * p.cScale;
        float cr = (cbcr.y - p.cOffset) * p.cScale;
        float r = y + 2.0 * (1.0 - p.kr) * cr;
        float b = y + 2.0 * (1.0 - p.kb) * cb;
        float g = (y - p.kr * r - p.kb * b) / (1.0 - p.kr - p.kb);
        output.write(float4(saturate(float3(r, g, b)), 1.0), gid);
    }

    kernel void lanczos_horizontal(
        texture2d<float, access::read> input [[texture(0)]],
        texture2d<float, access::write> output [[texture(1)]],
        device const int* starts [[buffer(0)]],
        device const float* weights [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }
        int last = int(input.get_width()) - 1;
        int first = starts[gid.x];
        float4 sum = float4(0.0);
        for (int tap = 0; tap < kTaps; ++tap) {
            sum += weights[int(gid.x) * kTaps + tap] * input.read(uint2(uint(clamp(first + tap, 0, last)), gid.y));
        }
        output.write(sum, gid);
    }

    kernel void lanczos_vertical(
        texture2d<float, access::read> input [[texture(0)]],
        texture2d<float, access::write> output [[texture(1)]],
        device const int* starts [[buffer(0)]],
        device const float* weights [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }
        int last = int(input.get_height()) - 1;
        int first = starts[gid.y];
        float4 sum = float4(0.0);
        for (int tap = 0; tap < kTaps; ++tap) {
            sum += weights[int(gid.y) * kTaps + tap] * input.read(uint2(gid.x, uint(clamp(first + tap, 0, last))));
        }
        output.write(saturate(sum), gid);
    }

    struct LineArtParams {
        float strength;
    };

    // A shock-filter style pass (the idea Osher and Rudin published in 1990, here in a form for drawn pictures):
    // across an edge, a pixel on the bright shoulder is pushed toward the brighter of its two neighbours along the
    // gradient and a pixel on the dark shoulder toward the darker one. Soft edges get steeper and lines thinner,
    // the middle of a ramp and the core of a thin line stay put, and since the target is always a colour already
    // beside the pixel, nothing rings or overshoots.
    kernel void line_art_steepen(
        texture2d<float, access::read> input [[texture(0)]],
        texture2d<float, access::write> output [[texture(1)]],
        constant LineArtParams& p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        int2 size = int2(input.get_width(), input.get_height());
        if (int(gid.x) >= size.x || int(gid.y) >= size.y) { return; }
        int2 last = size - 1;
        int2 at = int2(gid);
        float3 centre = fetch(input, at, last);

        float tl = luminance(fetch(input, at + int2(-1, -1), last));
        float tc = luminance(fetch(input, at + int2(0, -1), last));
        float tr = luminance(fetch(input, at + int2(1, -1), last));
        float ml = luminance(fetch(input, at + int2(-1, 0), last));
        float mr = luminance(fetch(input, at + int2(1, 0), last));
        float bl = luminance(fetch(input, at + int2(-1, 1), last));
        float bc = luminance(fetch(input, at + int2(0, 1), last));
        float br = luminance(fetch(input, at + int2(1, 1), last));
        // Sobel slope: how fast the brightness changes, per pixel, and which way it rises.
        float2 slope = float2((tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl), (bl + 2.0 * bc + br) - (tl + 2.0 * tc + tr)) * 0.125;
        float steepness = length(slope);
        float confidence = smoothstep(0.02, 0.08, steepness);
        if (confidence <= 0.0) {
            output.write(float4(centre, 1.0), gid);
            return;
        }
        float2 across = slope / steepness;
        float3 ahead = fetch_linear(input, float2(at) + across, last);
        float3 behind = fetch_linear(input, float2(at) - across, last);
        float here = luminance(centre);
        float forward = luminance(ahead);
        float backward = luminance(behind);
        // Positive: the pixel sits lower than the average of its two neighbours (a dark shoulder); negative: a bright one.
        float bend = forward + backward - 2.0 * here;
        float3 target = bend > 0.0 ? (forward < backward ? ahead : behind) : (forward > backward ? ahead : behind);
        float amount = p.strength * confidence * smoothstep(0.01, 0.05, fabs(bend));
        output.write(float4(mix(centre, target, amount), 1.0), gid);
    }

    struct ComposeParams {
        float sharpen;
        float deband;
        float debandRadius;
        float debandThreshold;
        uint frame;
    };

    kernel void compose(
        texture2d<float, access::read> input [[texture(0)]],
        texture2d<float, access::write> output [[texture(1)]],
        constant ComposeParams& p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        int2 size = int2(output.get_width(), output.get_height());
        if (int(gid.x) >= size.x || int(gid.y) >= size.y) { return; }
        int2 last = size - 1;
        int2 at = int2(gid);
        float3 original = fetch(input, at, last);
        float3 colour = original;

        if (p.deband > 0.0) {
            // Average a ring of neighbours at random distances and a per-pixel turn, but let in only the ones
            // that differ from the pixel by less than the threshold: gentle steps are smoothed, real edges stay.
            uint seed = scramble(gid.x * 1973u + gid.y * 9277u + 0x9e3779b9u);
            float angle = unit_noise(seed) * 6.2831853;
            float2 turn = float2(cos(angle), sin(angle));
            float3 total = float3(0.0);
            for (int tap = 0; tap < 8; ++tap) {
                float2 ring = kRing[tap];
                float2 direction = float2(ring.x * turn.x - ring.y * turn.y, ring.x * turn.y + ring.y * turn.x);
                float reach = 0.3 + 0.7 * unit_noise(scramble(seed + uint(tap + 1) * 0x632be5abu));
                int2 spot = at + int2(round(direction * (reach * p.debandRadius)));
                float3 neighbour = fetch(input, spot, last);
                float3 gap = fabs(neighbour - original);
                float largest = max(gap.r, max(gap.g, gap.b));
                float within = 1.0 - smoothstep(0.5 * p.debandThreshold, p.debandThreshold, largest);
                total += mix(original, neighbour, within);
            }
            colour = total * 0.125;
        }

        if (p.sharpen > 0.0) {
            // Contrast-adaptive: the room a neighbourhood has before it clips sets how hard it is sharpened,
            // so flat and near-black or near-white areas are left alone and mid-tone detail gets the most.
            float3 up = fetch(input, at + int2(0, -1), last);
            float3 down = fetch(input, at + int2(0, 1), last);
            float3 left = fetch(input, at + int2(-1, 0), last);
            float3 right = fetch(input, at + int2(1, 0), last);
            float3 low = min(min(up, down), min(min(left, right), colour));
            float3 high = max(max(up, down), max(max(left, right), colour));
            float3 room = saturate(min(low, 1.0 - high) / max(high, float3(0.0001)));
            float3 weight = -sqrt(room) * (0.05 + 0.15 * p.sharpen);
            colour = (colour + (up + down + left + right) * weight) / (1.0 + 4.0 * weight);
        }

        if (p.deband > 0.0) {
            // Triangular dither, new every frame, hides what is left of a step once the result is rounded to 8 bits.
            uint bits = scramble(gid.x + gid.y * 65537u + p.frame * 0x27d4eb2fu);
            float noise = unit_noise(bits) + unit_noise(scramble(bits ^ 0x68e31da4u)) - 1.0;
            colour += noise * ((0.5 + 0.5 * p.deband) / 255.0);
        }
        output.write(float4(saturate(colour), 1.0), gid);
    }
    """#
}
