#version 330 core

in vec2 v_uv;
out vec4 f_color;

uniform sampler2D u_prev_frame;   // previous diffusion frame
uniform sampler2D u_cur_frame;    // latest diffusion frame
uniform sampler2D u_feedback;     // previous composite (trails)

uniform vec2  u_resolution;
uniform float u_time;
uniform float u_blend;            // crossfade prev -> cur
uniform float u_pulse;            // kick envelope
uniform float u_pulse_amount;
uniform float u_chroma_px;
uniform float u_trail_amount;
uniform float u_trail_decay;
uniform float u_trail_zoom;
uniform float u_strobe;
uniform float u_hue;              // accumulated hue angle, radians
uniform float u_grain;
uniform float u_vignette;
uniform float u_beat_phase;
uniform float u_beat_breathe;

const float TAU = 6.28318530718;

float hash13(vec3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}

vec3 diff(vec2 uv) {
    return mix(texture(u_prev_frame, uv).rgb, texture(u_cur_frame, uv).rgb, u_blend);
}

vec3 hue_rotate(vec3 c, float a) {
    const vec3 k = vec3(0.57735026919);
    float cs = cos(a);
    return c * cs + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - cs);
}

void main() {
    // 1. kick pulse: image inhales toward center on every kick
    vec2 uv = (v_uv - 0.5) * (1.0 - u_pulse * u_pulse_amount) + 0.5;

    // 2. radial chromatic aberration
    vec2 dir = uv - 0.5;
    vec2 off = dir * 2.0 * (u_chroma_px / u_resolution.x);
    vec3 fresh;
    fresh.r = diff(uv + off).r;
    fresh.g = diff(uv).g;
    fresh.b = diff(uv - off).b;

    // 3. feedback trails, sampled slightly zoomed so streaks push outward;
    // half-pixel hash jitter prevents resample interference banding when the
    // same diffusion frame accumulates many trail passes (slow diffusion fps)
    vec2 fuv = (v_uv - 0.5) / u_trail_zoom + 0.5;
    fuv += (vec2(hash13(vec3(v_uv * u_resolution, fract(u_time) * 43.7)),
                 hash13(vec3(v_uv * u_resolution, fract(u_time) * 91.3))) - 0.5)
           / u_resolution;
    vec3 fb = texture(u_feedback, fuv).rgb * u_trail_decay;
    vec3 color = mix(fresh, fb, u_trail_amount);

    // 5. slow hue rotation
    color = hue_rotate(color, u_hue);

    // 7. sub-visible brightness breathing locked to beat phase
    color *= 1.0 + u_beat_breathe * sin(u_beat_phase * TAU);

    // 4. strobe (hard-gated upstream by enable_strobe)
    color = mix(color, vec3(1.0), u_strobe);

    // 6. animated film grain + vignette
    float g = hash13(vec3(v_uv * u_resolution, fract(u_time) * 61.7)) - 0.5;
    color += g * u_grain;
    float d = length(v_uv - 0.5);
    color *= 1.0 - u_vignette * smoothstep(0.35, 0.78, d);

    f_color = vec4(clamp(color, 0.0, 1.0), 1.0);
}
