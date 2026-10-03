#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// The Click Drop develop: a photo resolving out of its pixels. Blocks halve in whole steps from
/// `maxBlock` (the drop's pixelated look) down to the photo, sweeping out from the center so the
/// middle sharpens first, with a soft light riding the resolving front. `progress` 0 is the
/// pixels, 1 the photo.
[[ stitchable ]] half4 clickDropDevelop(float2 position, SwiftUI::Layer layer, float2 size, float progress, float maxBlock) {
    float2 center = size * 0.5;
    // 0 at the center, 1 at a corner.
    float reach = length(position - center) / max(length(center), 1.0);
    // Each point resolves over its own window: the center starts first, the corners finish at 1.
    float local = smoothstep(0.0, 1.0, saturate(progress * 1.6 - reach * 0.6));
    float levels = log2(max(maxBlock, 1.0));
    float block = maxBlock * exp2(-floor(levels * local));
    if (local >= 1.0 || block <= 1.0) {
        return layer.sample(position);
    }
    // Blocks are centered on the photo, so every stage stays symmetric.
    float2 cell = (floor((position - center) / block) + 0.5) * block + center;
    half4 color = layer.sample(cell);
    half glow = half(sin(local * M_PI_F) * 0.16) * color.a;
    color.rgb = min(color.rgb + glow, half3(color.a));
    return color;
}
