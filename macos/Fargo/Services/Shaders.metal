#include <metal_stdlib>
using namespace metal;

struct QuadUniforms {
    float4 frame;
    float4 texCrop;
    float  cornerRadius;
    float  opacity;
    float  mirror;
    float  _pad;
    float2 quadPixelSize;
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float2 quadPos;
};

// MARK: - Composition shaders

vertex VertexOut compositeVertex(uint vertexID [[vertex_id]],
                                 constant QuadUniforms &u [[buffer(0)]]) {
    float2 corners[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0)
    };

    float2 corner = corners[vertexID];

    float2 pos = float2(u.frame.x + corner.x * u.frame.z,
                        u.frame.y + corner.y * u.frame.w);

    float2 tc = float2(u.texCrop.x + corner.x * u.texCrop.z,
                       u.texCrop.y + (1.0 - corner.y) * u.texCrop.w);

    if (u.mirror > 0.5) {
        tc.x = u.texCrop.x + u.texCrop.z - (tc.x - u.texCrop.x);
    }

    VertexOut out;
    out.position = float4(pos, 0.0, 1.0);
    out.texCoord = tc;
    out.quadPos = corner * u.quadPixelSize;
    return out;
}

fragment float4 compositeFragment(VertexOut in [[stage_in]],
                                   constant QuadUniforms &u [[buffer(0)]],
                                   texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, mip_filter::linear);
    float4 color = tex.sample(s, in.texCoord);

    if (u.cornerRadius > 0.0) {
        float r = u.cornerRadius;
        float2 size = u.quadPixelSize;
        float2 p = in.quadPos;

        float2 q = abs(p - size * 0.5) - (size * 0.5 - r);
        float dist = length(max(q, 0.0)) - r;

        float alpha = 1.0 - smoothstep(-1.0, 0.5, dist);
        color.a *= alpha;
    }

    color.a *= u.opacity;
    color.rgb *= color.a;

    return color;
}

// MARK: - Gaussian blur compute kernels (separable, two-pass)

struct BlurParams {
    int radius;
    float sigma;
};

kernel void gaussianBlurH(texture2d<float, access::read>  src  [[texture(0)]],
                           texture2d<float, access::write> dst  [[texture(1)]],
                           constant BlurParams &params           [[buffer(0)]],
                           uint2 gid                             [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }

    int r = params.radius;
    float sigma = params.sigma;
    float twoSigmaSq = 2.0 * sigma * sigma;

    float4 sum = float4(0.0);
    float weightSum = 0.0;

    int w = int(src.get_width());

    for (int i = -r; i <= r; i++) {
        int sx = clamp(int(gid.x) + i, 0, w - 1);
        float weight = exp(-float(i * i) / twoSigmaSq);
        sum += src.read(uint2(sx, gid.y)) * weight;
        weightSum += weight;
    }

    dst.write(sum / weightSum, gid);
}

kernel void gaussianBlurV(texture2d<float, access::read>  src  [[texture(0)]],
                           texture2d<float, access::write> dst  [[texture(1)]],
                           constant BlurParams &params           [[buffer(0)]],
                           uint2 gid                             [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }

    int r = params.radius;
    float sigma = params.sigma;
    float twoSigmaSq = 2.0 * sigma * sigma;

    float4 sum = float4(0.0);
    float weightSum = 0.0;

    int h = int(src.get_height());

    for (int i = -r; i <= r; i++) {
        int sy = clamp(int(gid.y) + i, 0, h - 1);
        float weight = exp(-float(i * i) / twoSigmaSq);
        sum += src.read(uint2(gid.x, sy)) * weight;
        weightSum += weight;
    }

    dst.write(sum / weightSum, gid);
}

// MARK: - Downsample (bilinear, for half-res blur)

kernel void downsample(texture2d<float, access::read>  src  [[texture(0)]],
                        texture2d<float, access::write> dst  [[texture(1)]],
                        uint2 gid                             [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }

    uint2 srcPos = gid * 2;
    float4 a = src.read(srcPos);
    float4 b = src.read(srcPos + uint2(1, 0));
    float4 c = src.read(srcPos + uint2(0, 1));
    float4 d = src.read(srcPos + uint2(1, 1));

    dst.write((a + b + c + d) * 0.25, gid);
}

// MARK: - Blur composite compute kernel

kernel void blurComposite(texture2d<float, access::read>  camera   [[texture(0)]],
                           texture2d<float, access::read>  blurred  [[texture(1)]],
                           texture2d<float, access::read>  mask     [[texture(2)]],
                           texture2d<float, access::write> output   [[texture(3)]],
                           uint2 gid                                 [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }

    float2 uv = float2(float(gid.x) / float(output.get_width()),
                        float(gid.y) / float(output.get_height()));

    uint2 blurPos = uint2(uv.x * float(blurred.get_width()),
                           uv.y * float(blurred.get_height()));
    blurPos = clamp(blurPos, uint2(0), uint2(blurred.get_width() - 1, blurred.get_height() - 1));

    uint2 maskPos = uint2(uv.x * float(mask.get_width()),
                           uv.y * float(mask.get_height()));
    maskPos = clamp(maskPos, uint2(0), uint2(mask.get_width() - 1, mask.get_height() - 1));

    float4 sharp = camera.read(gid);
    float4 blur = blurred.read(blurPos);
    float  m = mask.read(maskPos).r;

    output.write(mix(blur, sharp, m), gid);
}

kernel void backgroundRemove(texture2d<float, access::read>  camera   [[texture(0)]],
                              texture2d<float, access::read>  mask     [[texture(1)]],
                              texture2d<float, access::write> output   [[texture(2)]],
                              constant float4 &bgColor                 [[buffer(0)]],
                              uint2 gid                                 [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }

    float2 uv = float2(float(gid.x) / float(output.get_width()),
                        float(gid.y) / float(output.get_height()));

    uint2 maskPos = uint2(uv.x * float(mask.get_width()),
                           uv.y * float(mask.get_height()));
    maskPos = clamp(maskPos, uint2(0), uint2(mask.get_width() - 1, mask.get_height() - 1));

    float4 sharp = camera.read(gid);
    float  m = mask.read(maskPos).r;

    output.write(mix(bgColor, sharp, m), gid);
}

// MARK: - Selection border (rendered as a hollow quad)

struct BorderUniforms {
    float4 frame;
    float2 quadPixelSize;
    float  borderWidth;
    float  cornerRadius;
};

struct BorderVertexOut {
    float4 position [[position]];
    float2 quadPos;
};

vertex BorderVertexOut borderVertex(uint vertexID [[vertex_id]],
                                     constant BorderUniforms &u [[buffer(0)]]) {
    float2 corners[4] = {
        float2(0.0, 0.0), float2(1.0, 0.0),
        float2(0.0, 1.0), float2(1.0, 1.0)
    };
    float2 corner = corners[vertexID];
    float2 pos = float2(u.frame.x + corner.x * u.frame.z,
                        u.frame.y + corner.y * u.frame.w);

    BorderVertexOut out;
    out.position = float4(pos, 0.0, 1.0);
    out.quadPos = corner * u.quadPixelSize;
    return out;
}

fragment float4 borderFragment(BorderVertexOut in [[stage_in]],
                                constant BorderUniforms &u [[buffer(0)]]) {
    float2 size = u.quadPixelSize;
    float2 p = in.quadPos;
    float bw = u.borderWidth;
    float r = u.cornerRadius;

    float2 qOuter = abs(p - size * 0.5) - (size * 0.5 - r);
    float dOuter = length(max(qOuter, 0.0)) - r;

    float ri = max(r - bw, 0.0);
    float2 qInner = abs(p - size * 0.5) - (size * 0.5 - bw - ri);
    float dInner = length(max(qInner, 0.0)) - ri;

    float outer = 1.0 - smoothstep(-1.0, 0.5, dOuter);
    float inner = 1.0 - smoothstep(-1.0, 0.5, dInner);
    float border = outer - inner;

    float handleSize = 5.0;
    float handle = 0.0;

    float2 corners[4] = {
        float2(0.0, 0.0),
        float2(size.x, 0.0),
        float2(0.0, size.y),
        float2(size.x, size.y)
    };
    for (int i = 0; i < 4; i++) {
        float2 d = abs(p - corners[i]);
        if (d.x < handleSize && d.y < handleSize) {
            handle = 1.0;
        }
    }

    float2 edges[4] = {
        float2(size.x * 0.5, 0.0),
        float2(size.x * 0.5, size.y),
        float2(0.0, size.y * 0.5),
        float2(size.x, size.y * 0.5)
    };
    for (int i = 0; i < 4; i++) {
        float2 d = abs(p - edges[i]);
        if (d.x < handleSize && d.y < handleSize) {
            handle = 1.0;
        }
    }

    float alpha = max(border, handle);
    if (alpha < 0.01) { discard_fragment(); }

    float3 color = mix(float3(0.3, 0.6, 1.0), float3(1.0), handle);
    float a = mix(0.7, 1.0, handle) * alpha;

    return float4(color * a, a);
}

// MARK: - Color correction compute kernel

struct ColorCorrectionParams {
    float brightness;   // -1 to 1 (0 = no change)
    float contrast;     // 0 to 3 (1 = no change)
    float saturation;   // 0 to 3 (1 = no change)
    float gamma;        // 0.1 to 3 (1 = no change)
    float temperature;  // -1 to 1 (0 = no change, negative = cool, positive = warm)
};

kernel void colorCorrection(texture2d<float, access::read>  src     [[texture(0)]],
                              texture2d<float, access::write> dst     [[texture(1)]],
                              constant ColorCorrectionParams &params   [[buffer(0)]],
                              uint2 gid                                [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }

    float4 color = src.read(gid);
    float3 rgb = color.rgb;

    rgb += params.brightness;

    rgb = (rgb - 0.5) * params.contrast + 0.5;

    float lum = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    rgb = mix(float3(lum), rgb, params.saturation);

    if (abs(params.temperature) > 0.001) {
        rgb.r += params.temperature * 0.1;
        rgb.b -= params.temperature * 0.1;
    }

    rgb = clamp(rgb, 0.0, 1.0);
    rgb = pow(rgb, float3(1.0 / params.gamma));

    dst.write(float4(rgb, color.a), gid);
}

// MARK: - Skin smoothing (bilateral blur, mask-guided)

kernel void skinSmoothing(texture2d<float, access::read>  src       [[texture(0)]],
                           texture2d<float, access::read>  mask      [[texture(1)]],
                           texture2d<float, access::write> dst       [[texture(2)]],
                           constant float &intensity                  [[buffer(0)]],
                           uint2 gid                                  [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }

    float maskW = float(mask.get_width());
    float maskH = float(mask.get_height());
    float dstW = float(dst.get_width());
    float dstH = float(dst.get_height());
    uint2 maskPos = uint2(uint(float(gid.x) / dstW * maskW),
                          uint(float(gid.y) / dstH * maskH));
    float maskVal = mask.read(maskPos).r;

    float4 center = src.read(gid);

    if (maskVal < 0.3) {
        dst.write(center, gid);
        return;
    }

    int radius = int(mix(1.0, 6.0, intensity));
    float spatialSigma = mix(1.0, 4.0, intensity);
    float rangeSigma = mix(0.05, 0.15, intensity);

    float twoSpatialSigmaSq = 2.0 * spatialSigma * spatialSigma;
    float twoRangeSigmaSq = 2.0 * rangeSigma * rangeSigma;

    float4 sum = float4(0.0);
    float weightSum = 0.0;

    int w = int(src.get_width());
    int h = int(src.get_height());

    for (int dy = -radius; dy <= radius; dy++) {
        for (int dx = -radius; dx <= radius; dx++) {
            int sx = clamp(int(gid.x) + dx, 0, w - 1);
            int sy = clamp(int(gid.y) + dy, 0, h - 1);

            float4 neighbor = src.read(uint2(sx, sy));

            float spatialDist = float(dx * dx + dy * dy);
            float rangeDist = length_squared(neighbor.rgb - center.rgb);

            float weight = exp(-spatialDist / twoSpatialSigmaSq - rangeDist / twoRangeSigmaSq);
            sum += neighbor * weight;
            weightSum += weight;
        }
    }

    float4 smoothed = sum / weightSum;
    float blend = maskVal * intensity;
    dst.write(mix(center, smoothed, blend), gid);
}

// MARK: - Blit shader (unused in current pipeline but kept for offscreen output)

struct BlitUniforms {
    float2 scale;
};

struct BlitVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex BlitVertexOut blitVertex(uint vertexID [[vertex_id]],
                                constant BlitUniforms &u [[buffer(0)]]) {
    float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };

    float2 texCoords[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };

    BlitVertexOut out;
    out.position = float4(positions[vertexID] * u.scale, 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

fragment float4 blitFragment(BlitVertexOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    return tex.sample(s, in.texCoord);
}
