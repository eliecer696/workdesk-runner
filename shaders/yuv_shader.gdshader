shader_type spatial;
render_mode unshaded, cull_disabled;

// Texture containing either RGB image or Packed YUV data
uniform sampler2D yuv_tex : filter_linear, repeat_disable;
uniform bool is_yuv = false;

void fragment() {
	if (!is_yuv) {
		// Standard RGB texture (JPEG fallback)
		ALBEDO = texture(yuv_tex, UV).rgb;
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
		float u = texture(yuv_tex, vec2(u_uv_x, chrom_uv_y)).r - 0.5;
		
		// V Sample (Bottom 1/3, Right)
		float v_uv_x = 0.5 + (UV.x * 0.5);
		float v = texture(yuv_tex, vec2(v_uv_x, chrom_uv_y)).r - 0.5;
		
		// Convert to RGB (standard BT.601)
		// R = Y + 1.402 * V
		// G = Y - 0.344136 * U - 0.714136 * V
		// B = Y + 1.772 * U
		float r = y + 1.402 * v;
		float g = y - 0.344136 * u - 0.714136 * v;
		float b = y + 1.772 * u;
		
		ALBEDO = vec3(r, g, b);
	}
}
