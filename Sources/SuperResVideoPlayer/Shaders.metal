#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

/// Draws a full-screen triangle (no vertex buffer needed) and derives UVs
/// from the clip-space position. Cheaper than a quad + index buffer for a
/// single textured blit.
vertex VertexOut videoVertexShader(uint vertexID [[vertex_id]]) {
    // Clip-space positions for a triangle that fully covers the viewport.
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2(-1.0,  3.0),
        float2( 3.0, -1.0)
    };

    VertexOut out;
    float2 p = positions[vertexID];
    out.position = float4(p, 0.0, 1.0);

    // Map clip space [-1,1] to UV space [0,1], flipping V because
    // CVPixelBuffer-backed textures are top-left origin while Metal's
    // texture sampling expects bottom-left origin for this mapping.
    out.uv = float2((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5);
    return out;
}

fragment float4 videoFragmentShader(VertexOut in [[stage_in]],
                                     texture2d<float> videoTexture [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    return videoTexture.sample(s, in.uv);
}

// MARK: - AI Image Enhancer

struct EnhanceParams {
    float sharpness;   // 0..1
    float denoise;     // 0..1
};

/// Same-resolution image enhancement: a light edge-aware denoise followed by
/// contrast-adaptive sharpening (CAS-style, after AMD FidelityFX). The
/// sharpening strength adapts per pixel to local contrast, so already-crisp
/// edges aren't over-driven into halos while soft detail gets lifted —
/// "cleaner and more detailed without changing the resolution". Runs before
/// Super Resolution so the upscaler receives the improved image.
kernel void enhanceKernel(texture2d<float, access::sample> inputTexture [[texture(0)]],
                           texture2d<float, access::write> outputTexture [[texture(1)]],
                           constant EnhanceParams &params [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    uint width = outputTexture.get_width();
    uint height = outputTexture.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }

    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 texSize = float2(width, height);
    float2 uv = (float2(gid) + 0.5) / texSize;
    float2 px = 1.0 / texSize;

    // 3x3 neighborhood.
    float3 a = inputTexture.sample(s, uv + float2(-px.x, -px.y)).rgb;
    float3 b = inputTexture.sample(s, uv + float2( 0.0,  -px.y)).rgb;
    float3 c = inputTexture.sample(s, uv + float2( px.x, -px.y)).rgb;
    float3 d = inputTexture.sample(s, uv + float2(-px.x,  0.0)).rgb;
    float3 e = inputTexture.sample(s, uv).rgb;
    float3 f = inputTexture.sample(s, uv + float2( px.x,  0.0)).rgb;
    float3 g = inputTexture.sample(s, uv + float2(-px.x,  px.y)).rgb;
    float3 h = inputTexture.sample(s, uv + float2( 0.0,   px.y)).rgb;
    float3 i = inputTexture.sample(s, uv + float2( px.x,  px.y)).rgb;

    // Light edge-aware denoise: blend toward the cross average only in
    // flat regions (high local range = edge = leave untouched). Cleans up
    // compression noise/mosquito artifacts without smearing detail.
    float3 crossAvg = (b + d + f + h) * 0.25;
    float3 range = max(max(max(b, d), max(f, h)), e) - min(min(min(b, d), min(f, h)), e);
    float flatness = 1.0 - saturate(dot(range, float3(1.0 / 3.0)) * 8.0);
    float3 base = mix(e, crossAvg, params.denoise * flatness * 0.6);

    // Contrast-adaptive sharpening (CAS). The negative-lobe weight scales
    // with sqrt of local headroom, limiting ringing at strong edges.
    float3 mnRGB = min(min(min(d, e), min(f, b)), h);
    float3 mxRGB = max(max(max(d, e), max(f, b)), h);
    float3 mnRGB2 = min(mnRGB, min(min(a, c), min(g, i)));
    float3 mxRGB2 = max(mxRGB, max(max(a, c), max(g, i)));
    mnRGB += mnRGB2;
    mxRGB += mxRGB2;

    float3 rcpM = 1.0 / (mxRGB + 1e-4);
    float3 amp = sqrt(saturate(min(mnRGB, 2.0 - mxRGB) * rcpM));

    // Lobe strength: -1/8 (mild) .. -1/5 (strong) with the slider.
    float peak = -1.0 / mix(8.0, 5.0, saturate(params.sharpness));
    float3 w = amp * peak;
    float3 rcpW = 1.0 / (1.0 + 4.0 * w);
    float3 sharpened = saturate(((b + d + f + h) * w + base) * rcpW);

    float3 result = mix(base, sharpened, saturate(params.sharpness));
    outputTexture.write(float4(result, 1.0), gid);
}

// MARK: - Frame interpolation support kernels

/// Fills a texture with a flat/constant depth value. Video frames have no
/// real scene depth (there's no 3D geometry, just decoded 2D color), so this
/// stands in for the depth buffer MTLFXFrameInterpolator expects from game
/// engines. Dispatched once whenever the depth texture is (re)created, not
/// per-frame.
kernel void clearDepthKernel(texture2d<float, access::write> depthTexture [[texture(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= depthTexture.get_width() || gid.y >= depthTexture.get_height()) {
        return;
    }
    // 1.0 = "far plane" in a normalized [0,1] depth convention; since every
    // pixel is equally flat there's no disocclusion depth cue at all, which
    // is the fundamental trade-off of applying a game-oriented API to video.
    depthTexture.write(float4(1.0, 0.0, 0.0, 0.0), gid);
}

/// Custom motion-compensated blend used for the 3x interpolation mode (and
/// as a soft fallback if the native MetalFX interpolator is unsupported).
/// MTLFXFrameInterpolator only produces one fixed intermediate frame per
/// pair, so to get an arbitrary temporal phase `t` between `previousTexture`
/// and `currentTexture` we do a simple bidirectional backward-warp + linear
/// blend using the same optical-flow motion field, instead of Apple's ML
/// interpolator. This is a much cruder technique than MetalFX's (no
/// disocclusion/hole-filling), but it's straightforward, well-understood
/// math, and doesn't depend on an undocumented API capability.
///
/// Motion vector convention: `motionTexture` holds Vision's raw *forward*
/// flow — at a pixel of the previous frame, the (dx, dy) pixel-space
/// displacement to that content's location in the current frame (see
/// OpticalFlowEstimator's doc comment). The warp below wants the backward
/// convention, so the sampled vector is negated here.
kernel void warpBlendKernel(texture2d<float, access::sample> previousTexture [[texture(0)]],
                             texture2d<float, access::sample> currentTexture [[texture(1)]],
                             texture2d<float, access::sample> motionTexture [[texture(2)]],
                             texture2d<float, access::write> outputTexture [[texture(3)]],
                             constant float &t [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    uint width = outputTexture.get_width();
    uint height = outputTexture.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }

    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float2 pixel = float2(gid) + float2(0.5, 0.5);
    float2 texSize = float2(width, height);

    // Negate: Vision provides forward flow (previous -> current); the warp
    // math below is written for backward flow (current -> previous).
    float2 flow = -motionTexture.sample(s, pixel / texSize).xy;

    // Move partway toward the previous frame's sample position as t -> 0,
    // and partway toward the un-shifted current position as t -> 1.
    float2 currentSamplePos = pixel - flow * (1.0 - t);
    float2 previousSamplePos = pixel + flow * t;

    float2 currentUV = currentSamplePos / texSize;
    float2 previousUV = previousSamplePos / texSize;

    float4 colorFromCurrent = currentTexture.sample(s, currentUV);
    float4 colorFromPrevious = previousTexture.sample(s, previousUV);

    float4 blended = mix(colorFromPrevious, colorFromCurrent, t);
    outputTexture.write(blended, gid);
}

/// Strength control for the offline Core ML enhancer.
kernel void blendEnhancementKernel(texture2d<float, access::read> original [[texture(0)]],
                                   texture2d<float, access::read> enhanced [[texture(1)]],
                                   texture2d<float, access::write> output [[texture(2)]],
                                   constant float &strength [[buffer(0)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }
    output.write(float4(mix(original.read(gid).rgb, enhanced.read(gid).rgb,
                            saturate(strength)), 1.0), gid);
}
