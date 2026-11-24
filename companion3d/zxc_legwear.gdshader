shader_type spatial;
render_mode cull_disabled, specular_disabled;

uniform sampler2D fabric_texture : source_color, filter_linear_mipmap;
uniform vec4 stocking_tint : source_color;
uniform vec4 welt_tint : source_color;

void fragment() {
	vec3 painted = texture(fabric_texture, UV).rgb;
	vec2 atlas = UV * vec2(2048.0, 1536.0);
	float chart = step(6.0, atlas.x) * step(atlas.x, 110.0) * step(atlas.y, 575.0);
	float coverage = smoothstep(200.0, 203.0, atlas.y) * chart;
	float band = 1.0 - smoothstep(207.0, 211.0, atlas.y);
	float curved_shade = 0.96 + 0.04 * cos((atlas.x - 8.0) * TAU / 100.0);
	vec3 fabric = mix(stocking_tint.rgb, welt_tint.rgb, band);
	vec3 normal = normalize(FRONT_FACING ? NORMAL : -NORMAL);
	float satin = pow(max(0.0, dot(normal, vec3(-0.29, 0.38, 0.88))), 18.0);
	ALBEDO = mix(painted, fabric * curved_shade + satin * 0.035, coverage);
	ROUGHNESS = 0.9;
}
