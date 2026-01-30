shader_type spatial;
render_mode unshaded, cull_disabled;

// Texture containing either RGB image or Packed YUV data
uniform sampler2D yuv_tex : filter_linear, repeat_disable;
uniform bool is_yuv = false;
uniform float saturation : hint_range(0.0, 2.0) = 1.1;
uniform bool use_full_range = true;
uniform float contrast = 1.1;
uniform float brightness = 0.0;

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

        // SURGICAL GREEN MASK:
        // Only mask if BOTH U and V are nearly zero (uninitialized).
        // This prevents the "washed out" look while still killing the Green Screen.
        if (u_raw < 0.05 && v_raw < 0.05) {
            u_raw = 0.5; 
            v_raw = 0.5; 
        }
		
		// 1. Shift and Scale based on Range
		float y_adj, u_adj, v_adj;
		
		if (use_full_range) {
			y_adj = y;
			u_adj = u_raw - 0.5;
			v_adj = v_raw - 0.5;
		} else {
			y_adj = (y - 0.0625) * 1.16438;
			u_adj = (u_raw - 0.5) * 1.138392;
			v_adj = (v_raw - 0.5) * 1.138392;
		}

		// 2. BT.709 Standard Matrix (Precise)
		float r = y_adj + 1.5748 * v_adj;
		float g = y_adj - 0.1873 * u_adj - 0.4681 * v_adj;
		float b = y_adj + 1.8556 * u_adj;

		vec3 rgb = clamp(vec3(r, g, b), 0.0, 1.0);
		
		// 3. Contrast / Brightness Tuning
		rgb = (rgb - 0.5) * contrast + 0.5 + brightness;
		
		// 4. Saturation
		vec3 hsv = rgb2hsv(clamp(rgb, 0.0, 1.0));
		hsv.y *= saturation; 
		rgb = hsv2rgb(hsv);
		
		// 5. GAMMA TO LINEAR: Godot 4 expects ALBEDO in Linear space.
		// Video is Gamma space. If we don't pow(2.2) here, Godot "lifts" it, making it look washed out.
		ALBEDO = pow(clamp(rgb, 0.0, 1.0), vec3(2.2));
	}
}
