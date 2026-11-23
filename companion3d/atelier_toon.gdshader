shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2D fabric_texture : source_color, filter_linear_mipmap, hint_default_white;
uniform vec4 base_tint : source_color = vec4(1.0);
uniform float alpha_cut = 0.0;
uniform float profile = 0.0;
uniform bool refined = false;

void fragment() {
	vec4 texel = texture(fabric_texture, UV) * base_tint;
	if (texel.a < alpha_cut) {
		discard;
	}

	vec3 normal = normalize(FRONT_FACING ? NORMAL : -NORMAL);
	vec3 key = normalize(vec3(-0.55, 0.68, 0.76));
	vec3 half_dir = normalize(key + vec3(0.0, 0.0, 1.0));
	float diffuse = dot(normal, key);
	float lit = smoothstep(-0.28, 0.52, diffuse);
	float rim = pow(1.0 - clamp(dot(normal, VIEW), 0.0, 1.0), 2.4);
	float highlight = pow(max(0.0, dot(normal, half_dir)), profile == 1.0 ? 28.0 : 15.0);
	vec3 shadow = vec3(0.64, 0.56, 0.73);
	vec3 tint = vec3(1.0, 0.95, 1.02);
	float sheen = 0.027;
	if (profile == 0.0) {
		shadow = vec3(0.83, 0.67, 0.73);
		tint = vec3(1.06, 1.0, 0.97);
	} else if (profile == 1.0) {
		sheen = 0.14;
	} else if (profile == 3.0) {
		sheen = 0.25;
	}

	if (refined) {
		shadow = mix(shadow, vec3(0.72, 0.68, 0.83), 0.38);
		tint *= vec3(0.98, 0.99, 1.0);
		sheen *= 0.83;
	}
	vec3 edge = vec3(0.25, 0.29, 0.53) * rim * (0.24 + 0.28 * lit);
	vec3 lit_color = texel.rgb * mix(shadow, tint, lit);
	ALBEDO = lit_color + edge * (profile == 0.0 ? 0.34 : 1.0) + sheen * highlight;
}
