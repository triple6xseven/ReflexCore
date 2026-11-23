shader_type spatial;
render_mode cull_disabled, specular_disabled;

uniform sampler2D fabric_texture : source_color, filter_linear_mipmap;
uniform vec4 stocking_tint : source_color;
uniform float fiber_coverage;
uniform vec4 bare_skin : source_color = vec4(0.962, 0.836, 0.839, 1.0);

void fragment() {
	vec3 painted = texture(fabric_texture, UV).rgb;
	vec2 atlas = UV * vec2(2048.0, 1536.0);
	float chart = step(6.0, atlas.x) * step(atlas.x, 110.0) * step(atlas.y, 575.0);
	float coverage = smoothstep(200.0, 203.0, atlas.y) * chart;
	float band = (1.0 - smoothstep(204.0, 207.0, atlas.y)) * coverage;
	float curved_shade = 0.96 + 0.04 * cos((atlas.x - 8.0) * TAU / 100.0);
	vec3 fabric = mix(bare_skin.rgb, stocking_tint.rgb, mix(fiber_coverage, max(fiber_coverage, 0.95), band));
	ALBEDO = mix(painted, fabric * curved_shade, coverage);
	ROUGHNESS = 0.9;
}
