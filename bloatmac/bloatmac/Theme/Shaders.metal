#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

/// Animated film grain layered over the aurora backdrop via `.colorEffect`.
/// `time` drifts the noise field so the grain shimmers instead of reading
/// as a frozen texture; `intensity` is ±luma amplitude (0.02–0.06 sensible).
[[ stitchable ]] half4 filmGrain(float2 pos, half4 color, float time, float intensity) {
    float2 p = pos + fmod(time * 60.0, 977.0);
    float n = fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
    return half4(color.rgb + half3((n - 0.5) * intensity), color.a);
}
