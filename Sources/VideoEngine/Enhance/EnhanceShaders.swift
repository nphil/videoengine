// The picture enhancer's GPU kernels, written for this engine in Metal Shading Language and compiled on the device
// the first time the enhancer needs them. Nothing here is copied from another shader: the Lanczos filter, the
// contrast-adaptive sharpen, the edge steepening for line art and the dither follow the published descriptions of
// those techniques. Every read goes through `read()` with explicit clamping, so no sampler state is involved.
//
// The kernels, in the order the chain runs them:
//   ingest_nv12         video-range or full-range NV12 -> BGRA, with the video's own matrix, cropping to the clean
//                       aperture and turning the frame upright on the way; softens block edges in the luma first
//   reorient_luma       the same crop, turn and block-edge softening for a luma plane that stays 4:2:0, for scalers
//                       that take 420v
//   reorient_chroma     the same crop and turn for the chroma plane
//   lanczos_horizontal  first half of the separable Lanczos-3 scale (rgba16Float in the middle)
//   lanczos_vertical    second half
//   line_art_steepen    pulls the pixels beside a line toward the side they belong to
//   downscale_horizontal, downscale_vertical
//                       scale a too-big machine-learning result down to the display (Lanczos-2, eight taps)
//   denoise             motion-adaptive temporal average with an edge-preserving spatial step
//   compose             deband, sharpen, vivid and dither in one pass
//
// Published ideas behind the kernels: Lanczos resampling; contrast-adaptive sharpening; the shock filter for line art
// (Osher and Rudin, 1990); in-loop deblocking filters as the H.264 and HEVC standards describe them (a step across a
// block edge is softened only when it is small against the quantiser and the two sides are flat); the bilateral
// filter (Tomasi and Manduchi, 1998) for the spatial step of the denoiser, and recursive temporal averaging gated by
// frame difference, the textbook form of motion-adaptive temporal noise reduction; unsharp-mask local contrast and
// vibrance-style saturation for the vivid pass. No third-party shader source is used.
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

    // Block-edge softening for the luma plane, in the coded frame's own pixels: 8x8 blocks, so an edge lies between
    // pixel columns (or rows) 8n-1 and 8n whatever the picture's size, crop or turn. A pixel within three of an edge
    // moves toward the other side by its share of the step across the edge (a half, a third and a sixth, from the
    // edge outward), which turns the step into a ramp. Nothing moves when the step is not small against `step`, or
    // when either side is busier than `activity`: those are real edges and texture, not blocking.
    struct DeblockParams {
        float step;
        float activity;
        float amount;
    };

    constant float kEdgeShare[3] = { 0.5, 0.33333334, 0.16666667 };

    inline float luma_at(texture2d<float, access::read> image, int2 position, int2 last) {
        return image.read(uint2(clamp(position, int2(0), last))).r;
    }

    inline float deblock_shift(texture2d<float, access::read> image, int2 pixel, int2 axis, int2 last, constant DeblockParams& d) {
        int phase = (axis.x != 0 ? pixel.x : pixel.y) & 7;
        int reach;
        float side;
        if (phase < 3) {
            reach = phase;
            side = -1.0;
        } else if (phase > 4) {
            reach = 7 - phase;
            side = 1.0;
        } else {
            return 0.0;
        }
        int2 q0 = side < 0.0 ? pixel - axis * reach : pixel + axis * (reach + 1);
        int2 p0 = q0 - axis;
        float p0v = luma_at(image, p0, last);
        float p1v = luma_at(image, p0 - axis, last);
        float p2v = luma_at(image, p0 - axis * 2, last);
        float q0v = luma_at(image, q0, last);
        float q1v = luma_at(image, q0 + axis, last);
        float q2v = luma_at(image, q0 + axis * 2, last);
        float jump = q0v - p0v;
        float busy = max(max(fabs(p0v - p1v), fabs(p1v - p2v)), max(fabs(q0v - q1v), fabs(q1v - q2v)));
        float gate = (1.0 - smoothstep(0.5 * d.step, d.step, fabs(jump))) * (1.0 - smoothstep(0.5 * d.activity, d.activity, busy));
        return side * kEdgeShare[reach] * jump * gate * d.amount;
    }

    struct IngestParams {
        float yOffset;
        float yScale;
        float cOffset;
        float cScale;
        float kr;
        float kb;
    };

    // Where the shown picture is in the coded frame and how it is turned. The output texture is the upright picture:
    // an output pixel is mirrored if asked, the two axes are swapped if asked, and the crop's corner is added.
    struct Geometry {
        int cropX;
        int cropY;
        int swapAxes;
        int flipAcross;
        int flipDown;
    };

    inline int2 coded_pixel(int2 upright, int2 size, constant Geometry& g) {
        int across = g.flipAcross != 0 ? size.x - 1 - upright.x : upright.x;
        int down = g.flipDown != 0 ? size.y - 1 - upright.y : upright.y;
        int2 turned = g.swapAxes != 0 ? int2(down, across) : int2(across, down);
        return turned + int2(g.cropX, g.cropY);
    }

    kernel void ingest_nv12(
        texture2d<float, access::read> luma [[texture(0)]],
        texture2d<float, access::read> chroma [[texture(1)]],
        texture2d<float, access::write> output [[texture(2)]],
        constant IngestParams& p [[buffer(0)]],
        constant Geometry& g [[buffer(1)]],
        constant DeblockParams& deblock [[buffer(2)]],
        uint2 gid [[thread_position_in_grid]])
    {
        int2 size = int2(output.get_width(), output.get_height());
        if (int(gid.x) >= size.x || int(gid.y) >= size.y) { return; }
        int2 last = int2(chroma.get_width(), chroma.get_height()) - 1;
        int2 lumaLast = int2(luma.get_width(), luma.get_height()) - 1;
        int2 pixel = coded_pixel(int2(gid), size, g);

        // 4:2:0 chroma sits on the even columns and halfway between the even and odd rows, as H.264 and HEVC code it.
        float2 at = float2(float(pixel.x) * 0.5, (float(pixel.y) - 0.5) * 0.5);
        int2 base = int2(floor(at));
        float2 blend = at - float2(base);
        float2 c00 = chroma.read(uint2(clamp(base, int2(0), last))).rg;
        float2 c10 = chroma.read(uint2(clamp(base + int2(1, 0), int2(0), last))).rg;
        float2 c01 = chroma.read(uint2(clamp(base + int2(0, 1), int2(0), last))).rg;
        float2 c11 = chroma.read(uint2(clamp(base + int2(1, 1), int2(0), last))).rg;
        float2 cbcr = mix(mix(c00, c10, blend.x), mix(c01, c11, blend.x), blend.y);

        float rawLuma = luma.read(uint2(clamp(pixel, int2(0), lumaLast))).r;
        if (deblock.amount > 0.0) {
            rawLuma += deblock_shift(luma, pixel, int2(1, 0), lumaLast, deblock) + deblock_shift(luma, pixel, int2(0, 1), lumaLast, deblock);
        }
        float y = (rawLuma - p.yOffset) * p.yScale;
        float cb = (cbcr.x - p.cOffset) * p.cScale;
        float cr = (cbcr.y - p.cOffset) * p.cScale;
        float r = y + 2.0 * (1.0 - p.kr) * cr;
        float b = y + 2.0 * (1.0 - p.kb) * cb;
        float g2 = (y - p.kr * r - p.kb * b) / (1.0 - p.kr - p.kb);
        output.write(float4(saturate(float3(r, g2, b)), 1.0), gid);
    }

    kernel void reorient_luma(
        texture2d<float, access::read> input [[texture(0)]],
        texture2d<float, access::write> output [[texture(1)]],
        constant Geometry& g [[buffer(0)]],
        constant DeblockParams& deblock [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        int2 size = int2(output.get_width(), output.get_height());
        if (int(gid.x) >= size.x || int(gid.y) >= size.y) { return; }
        int2 last = int2(input.get_width(), input.get_height()) - 1;
        int2 pixel = coded_pixel(int2(gid), size, g);
        float rawLuma = input.read(uint2(clamp(pixel, int2(0), last))).r;
        if (deblock.amount > 0.0) {
            rawLuma += deblock_shift(input, pixel, int2(1, 0), last, deblock) + deblock_shift(input, pixel, int2(0, 1), last, deblock);
        }
        output.write(float4(rawLuma, 0.0, 0.0, 1.0), gid);
    }

    // One chroma sample belongs to a 2x2 block of luma pixels. The crop's corner and the output's size are even, so
    // the block of the output's top left pixel falls inside one block of the coded frame whichever way it is turned.
    kernel void reorient_chroma(
        texture2d<float, access::read> input [[texture(0)]],
        texture2d<float, access::write> output [[texture(1)]],
        constant Geometry& g [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        int2 chromaSize = int2(output.get_width(), output.get_height());
        if (int(gid.x) >= chromaSize.x || int(gid.y) >= chromaSize.y) { return; }
        int2 last = int2(input.get_width(), input.get_height()) - 1;
        int2 pixel = coded_pixel(int2(gid) * 2, chromaSize * 2, g);
        output.write(input.read(uint2(clamp(pixel >> 1, int2(0), last))), gid);
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

    constant int kDownTaps = 8;

    kernel void downscale_horizontal(
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
        for (int tap = 0; tap < kDownTaps; ++tap) {
            sum += weights[int(gid.x) * kDownTaps + tap] * input.read(uint2(uint(clamp(first + tap, 0, last)), gid.y));
        }
        output.write(sum, gid);
    }

    kernel void downscale_vertical(
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
        for (int tap = 0; tap < kDownTaps; ++tap) {
            sum += weights[int(gid.y) * kDownTaps + tap] * input.read(uint2(gid.x, uint(clamp(first + tap, 0, last))));
        }
        output.write(saturate(sum), gid);
    }

    struct DenoiseParams {
        float range;
        float spatial;
        float tolerance;
        float history;
    };

    // Noise reduction in two steps. First a bilateral blend over the 3x3 around the pixel: a neighbour counts in
    // proportion to how close its colour is (within `range`), so grain is averaged and an edge, whose far side is
    // much further away than `range`, is not. Then, when there is a previous frame, a recursive blend toward it:
    // `history` is the most it can weigh, and the weight drops to nothing where the picture moved. Movement is read
    // two ways: the mean brightness change over the 3x3 (a moving area, with noise of about `tolerance` ignored) and
    // the pixel's own colour change (a thin or isoluminant mover the average would miss). Where either says the picture
    // moved, the current frame is kept as it is, so nothing ghosts. `history` of 0 makes it a purely spatial filter,
    // which is what the first frame after a seek, a size change or a scene change gets.
    kernel void denoise(
        texture2d<float, access::read> input [[texture(0)]],
        texture2d<float, access::read> previous [[texture(1)]],
        texture2d<float, access::write> output [[texture(2)]],
        constant DenoiseParams& p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        int2 size = int2(output.get_width(), output.get_height());
        if (int(gid.x) >= size.x || int(gid.y) >= size.y) { return; }
        int2 last = size - 1;
        int2 at = int2(gid);
        float3 around[9];
        for (int index = 0; index < 9; ++index) {
            around[index] = fetch(input, at + int2(index % 3 - 1, index / 3 - 1), last);
        }
        float3 centre = around[4];
        float3 total = float3(0.0);
        float weightSum = 0.0;
        float twoSigmaSquared = 2.0 * p.range * p.range;
        for (int index = 0; index < 9; ++index) {
            float3 gap = around[index] - centre;
            float reach = index == 4 ? 1.0 : ((index % 2) == 1 ? 0.75 : 0.5);
            float weight = exp(-dot(gap, gap) / twoSigmaSquared) * reach;
            total += around[index] * weight;
            weightSum += weight;
        }
        float3 colour = mix(centre, total / weightSum, p.spatial);

        if (p.history > 0.0) {
            float motion = 0.0;
            for (int index = 0; index < 9; ++index) {
                float3 before = fetch(previous, at + int2(index % 3 - 1, index / 3 - 1), last);
                motion += fabs(luminance(around[index]) - luminance(before));
            }
            motion *= (1.0 / 9.0);
            float still = 1.0 - smoothstep(p.tolerance, 3.0 * p.tolerance, motion);
            float3 remembered = fetch(previous, at, last);
            float3 change = fabs(centre - remembered);
            float same = 1.0 - smoothstep(2.0 * p.tolerance, 5.0 * p.tolerance, max(change.r, max(change.g, change.b)));
            colour = mix(colour, remembered, p.history * still * same);
        }
        output.write(float4(colour, 1.0), gid);
    }

    // How much a colour looks like skin, 0 to 1: between red and yellow in hue (about 10 to 50 degrees), of middling
    // saturation and not dark. Used to hold the vivid pass back where a face would turn orange.
    inline float skin_likeness(float3 c) {
        if (!(c.r >= c.g && c.g >= c.b)) { return 0.0; }
        float chroma = c.r - c.b;
        if (chroma < 0.0001) { return 0.0; }
        float hue = (c.g - c.b) / chroma;
        float saturation = chroma / c.r;
        return smoothstep(0.08, 0.2, hue) * (1.0 - smoothstep(0.7, 0.9, hue))
            * smoothstep(0.12, 0.25, saturation) * (1.0 - smoothstep(0.6, 0.8, saturation))
            * smoothstep(0.08, 0.2, c.r);
    }

    // The vivid tone boost on one pixel, given the average brightness around it. Two steps, both stronger with
    // `strength` and both held back toward white (a highlight must not clip), toward black (noise and crushed
    // shadows) and on skin:
    //   local contrast  the pixel moves away from its surroundings by 0.6 x strength of the difference, with the
    //                   difference compressed so a big step makes no halo; colour scales with the brightness, so hue holds
    //   saturation      colour moves away from grey by up to 0.5 x strength, less for colours that are already vivid
    //                   (vibrance), and never further than a channel can go without clipping
    // Grey has no colour to push and a flat area no difference, so both are left as they are.
    inline float3 vivid_tone(float3 colour, float surroundings, float strength) {
        float y = luminance(colour);
        float highlight = smoothstep(0.78, 0.97, y);
        float shadow = smoothstep(0.03, 0.15, y);
        float skin = skin_likeness(colour);

        float detail = y - surroundings;
        float lift = 0.6 * strength * (1.0 - highlight) * shadow * (1.0 - 0.5 * skin);
        float target = clamp(y + lift * detail / (1.0 + 4.0 * fabs(detail)), 0.0, 1.0);
        float peak = max(colour.r, max(colour.g, colour.b));
        float gain = y > 0.0001 ? target / y : 1.0;
        gain = clamp(gain, 0.7, max(1.0, min(1.5, 1.0 / max(peak, 0.0001))));
        colour *= gain;

        y = luminance(colour);
        float high = max(colour.r, max(colour.g, colour.b));
        float low = min(colour.r, min(colour.g, colour.b));
        float vividness = high > 0.0001 ? (high - low) / high : 0.0;
        float push = 0.5 * strength * (1.0 - highlight) * (0.5 + 0.5 * shadow) * (1.0 - 0.75 * skin);
        float factor = 1.0 + push * (1.0 - 0.6 * vividness);
        float3 away = colour - y;
        float room = 10000.0;
        for (int channel = 0; channel < 3; ++channel) {
            float d = away[channel];
            if (d > 0.00001) {
                room = min(room, (1.0 - y) / d);
            } else if (d < -0.00001) {
                room = min(room, y / -d);
            }
        }
        factor = clamp(factor, 1.0, max(room, 1.0));
        return y + away * factor;
    }

    struct ComposeParams {
        float sharpen;
        float deband;
        float debandRadius;
        float debandThreshold;
        uint frame;
        float vivid;
        float vividRadius;
        float dither;
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
            // The strongest weight the kernel is stable at, then pushed past it: 0.5 on the slider is the full
            // contrast-adaptive result and 1.0 doubles its change. Kept within a little of the neighbourhood's own
            // range, so the push shows as crisper edges, not as halos.
            float3 weight = -sqrt(room) * 0.2;
            float3 sharp = (colour + (up + down + left + right) * weight) / (1.0 + 4.0 * weight);
            float3 span = (high - low) * 0.25;
            colour = clamp(colour + (sharp - colour) * (2.0 * p.sharpen), low - span, high + span);
        }

        if (p.vivid > 0.0) {
            // The average brightness around the pixel: the pixel itself and two rings of eight taps, the outer one
            // at `vividRadius` and the inner at half of it, turned a sixteenth of a circle against each other.
            float around = luminance(original);
            for (int ring = 0; ring < 2; ++ring) {
                float reach = p.vividRadius * (ring == 0 ? 0.5 : 1.0);
                for (int tap = 0; tap < 8; ++tap) {
                    float2 direction = kRing[tap];
                    if (ring == 1) {
                        direction = float2(direction.x * 0.9238795 - direction.y * 0.3826834, direction.x * 0.3826834 + direction.y * 0.9238795);
                    }
                    around += luminance(fetch(input, at + int2(round(direction * reach)), last));
                }
            }
            colour = vivid_tone(colour, around * (1.0 / 17.0), p.vivid);
        }

        if (p.dither > 0.0) {
            // Triangular dither, new every frame, hides what is left of a step once the result is rounded to 8 bits.
            uint bits = scramble(gid.x + gid.y * 65537u + p.frame * 0x27d4eb2fu);
            float noise = unit_noise(bits) + unit_noise(scramble(bits ^ 0x68e31da4u)) - 1.0;
            colour += noise * (p.dither / 255.0);
        }
        output.write(float4(saturate(colour), 1.0), gid);
    }
    """#
}
