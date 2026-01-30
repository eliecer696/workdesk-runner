shader_type spatial;
render_mode unshaded, cull_disabled;

// Texture containing either RGB image or Packed YUV data
uniform sampler2D yuv_tex : filter_linear, repeat_disable;
uniform bool is_yuv = false;
uniform float saturation : hint_range(0.0, 2.0) = 1.2; // Default 20% boost

vec3 rgb2hsv(vec3 c) {
    vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
    vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));

    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
    vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void fragment() {
	if (!is_yuv) {
		// Just sample RGB texture
		vec3 color = texture(yuv_tex, UV).rgb;
		
		// Apply saturation boost to RGB fallback too
		vec3 hsv = rgb2hsv(color);
		hsv.y *= saturation;
		ALBEDO = hsv2rgb(hsv);
	} else {
		// YUV Layout in single L8 texture:
		// Top 2/3 (0.0 to 0.666) -> Y Plane (luminance)
		// Bottom 1/3 -> U and V planes side-by-side
		// U: Left Half (0.0 to 0.5)
		// V: Right Half (0.5 to 1.0)
		
		// Y Sample (Top 2/3)
		float y_uv_y = UV.y * 0.666666;
		float y = texture(yuv_tex, vec2(UV.x, y_uv_y)).r;
		
		// U Sample (Bottom 1/3, Left)
		float u_uv_x = UV.x * 0.5;
		float chrom_uv_y = 0.666666 + (UV.y * 0.333333);
		float u_raw = texture(yuv_tex, vec2(u_uv_x, chrom_uv_y)).r;
		float u = u_raw - 0.5;
		
		// V Sample (Bottom 1/3, Right)
		float v_uv_x = 0.5 + (UV.x * 0.5);
		float v_raw = texture(yuv_tex, vec2(v_uv_x, chrom_uv_y)).r;
		float v = v_raw - 0.5;

        // GREEN SCREEN FIX:
        // If U and V are exactly 0.0 (from a zero-initialized texture), the result is GREEN.
        // We detect this (raw value near 0) and force it to Grey (0.5 - 0.5 = 0.0).
        if (u_raw < 0.01 && v_raw < 0.01) {
            u = 0.0;
            v = 0.0;
        }
		
		// Convert from Limited Range (16-235) to Full Range (0-255)
		// Y: (val - 16/255) / (219/255)
		// UV: (val - 128/255) / (224/255) ... (since texture samples 0-1, 0.5 is center)
		
		float y_adj = (y - 0.0625) * 1.16438;
		float u_adj = (u - 0.5) * 1.13839; // Correction factor for limited range chroma might differ, simplified here
		float v_adj = (v - 0.5) * 1.13839;
		
		// BT.709 Coefficients (HD Standard)
		// R = Y + 1.5748 * V
		// G = Y - 0.1873 * U - 0.4681 * V
		// B = Y + 1.8556 * U
		
		// Note: The y_adj already includes the 1.164 contrast stretch shared by all.
		// Standard integer math is: R = 1.164(Y-16) + 1.793(V-128)
		// Let's stick to the direct float approximation for restricted range BT.709:
		
		// Re-calculating with standard formula:
		// R = 1.164 * (y - 16/255) + 1.793 * (v - 0.5)
		// G = 1.164 * (y - 16/255) - 0.213 * (u - 0.5) - 0.533 * (v - 0.5)
		// B = 1.164 * (y - 16/255) + 2.112 * (u - 0.5)
		
		// Using pre-adjusted Y (brightness/contrast fixed)
		y = (y - 0.0625) * 1.164;
		u = u - 0.5;
		v = v - 0.5;
		

		float r = y + 1.793 * v;
		float g = y - 0.213 * u - 0.533 * v;
		float b = y + 2.112 * u;

		vec3 rgb = vec3(r, g, b);
		vec3 hsv = rgb2hsv(rgb);
		hsv.y *= saturation; // Boost saturation
		ALBEDO = hsv2rgb(hsv);
	}
}
