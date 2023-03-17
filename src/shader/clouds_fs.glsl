#include <atmosphere.glsl>

// ------------------------------------------------------------------
// OUTPUT VARIABLES  ------------------------------------------------
// ------------------------------------------------------------------

out vec3 FS_OUT_Color;

// ------------------------------------------------------------------
// INPUT VARIABLES  -------------------------------------------------
// ------------------------------------------------------------------

in vec2 FS_IN_TexCoord;

// ------------------------------------------------------------------
// STRUCTURES -------------------------------------------------------
// ------------------------------------------------------------------

struct Ray
{
    vec3 origin;
    vec3 direction;
};

// ------------------------------------------------------------------
// UNIFORMS ---------------------------------------------------------
// ------------------------------------------------------------------

layout(std140, binding = 0) uniform GlobalUniforms
{
    mat4 view_proj;
    mat4 inv_view_proj;
    vec4 cam_pos;
};

uniform sampler3D s_ShapeNoise;
uniform sampler3D s_DetailNoise;
uniform sampler2D s_BlueNoise;
uniform sampler2D s_CurlNoise;

uniform vec3  	  u_PlanetCenter;
uniform float 	  u_PlanetRadius;
uniform float 	  u_CloudMinHeight;
uniform float 	  u_CloudMaxHeight;
uniform float 	  u_ShapeNoiseScale;
uniform float 	  u_DetailNoiseScale;
uniform float 	  u_DetailNoiseModifier;
uniform float 	  u_TurbulenceNoiseScale;
uniform float 	  u_TurbulenceAmount;
uniform float 	  u_CloudCoverage;
uniform vec3 	  u_WindDirection;
uniform float	  u_WindSpeed;
uniform float	  u_WindShearOffset;
uniform float     u_Time;
uniform float	  u_MaxNumSteps;
uniform float 	  u_LightStepLength;
uniform float 	  u_LightConeRadius;
uniform vec3      u_SunDir;
uniform vec3      u_SunColor;
uniform vec3      u_CloudBaseColor;
uniform vec3      u_CloudTopColor;
uniform float 	  u_Precipitation;
uniform float 	  u_AmbientLightFactor;
uniform float 	  u_SunLightFactor;
uniform float 	  u_HenyeyGreensteinGForward;
uniform float 	  u_HenyeyGreensteinGBackward;

// ------------------------------------------------------------------
// FUNCTIONS --------------------------------------------------------
// ------------------------------------------------------------------

Ray generate_ray()
{
    vec2 tex_coord_neg_to_pos = FS_IN_TexCoord * 2.0f - 1.0f;
    vec4 target = inv_view_proj * vec4(tex_coord_neg_to_pos, 0.0f, 1.0f);
    target /= target.w;

    Ray ray;

    ray.origin 	  = cam_pos.xyz;
    ray.direction = normalize(target.xyz - ray.origin);

    return ray;
}

// ------------------------------------------------------------------

vec3 ray_sphere_intersection(in Ray ray, in vec3 sphere_center, in float sphere_radius)
{
    vec3 l = ray.origin - sphere_center;
	float a = 1.0;
	float b = 2.0 * dot(ray.direction, l);
	float c = dot(l, l) - pow(sphere_radius, 2);
	float D = pow(b, 2) - 4.0 * a * c;
	
    if (D < 0.0)
		return ray.origin;
	else if (abs(D) - 0.00005 <= 0.0)
		return ray.origin + ray.direction * (-0.5 * b / a);
	else
	{
		float q = 0.0;
		if (b > 0.0) 
            q = -0.5 * (b + sqrt(D));
		else 
            q = -0.5 * (b - sqrt(D));
		
		float h1 = q / a;
		float h2 = c / q;
		vec2 t = vec2(min(h1, h2), max(h1, h2));

		if (t.x < 0.0) 
        {
			t.x = t.y;
			
            if (t.x < 0.0)
				return ray.origin;
		}
        
		return ray.origin + t.x * ray.direction;
	}
}

// ------------------------------------------------------------------

float blue_noise()
{
	ivec2 size = textureSize(s_BlueNoise, 0);

	vec2 interleaved_pos = (mod(floor(gl_FragCoord.xy), float(size.x)));
	vec2 tex_coord 	     = interleaved_pos / float(size.x) + vec2(0.5f / float(size.x), 0.5f / float(size.x));
	
	return texture(s_BlueNoise, tex_coord).r * 2.0f - 1.0f;
}

// ------------------------------------------------------------------

float remap(float original_value, float original_min, float original_max, float new_min, float new_max)
{
	return new_min + (((original_value - original_min) / (original_max - original_min)) * (new_max - new_min));
}

// ------------------------------------------------------------------

// returns height fraction [0, 1] for point in cloud
float height_fraction_for_point(vec3 _position)
{
	return clamp((distance(_position,  u_PlanetCenter) - (u_PlanetRadius + u_CloudMinHeight)) / (u_CloudMaxHeight - u_CloudMinHeight), 0.0f, 1.0f);
}

// ------------------------------------------------------------------

float density_height_gradient_for_point(vec3 _position, float _height_fraction)
{
	return 1.0f;
}

// ------------------------------------------------------------------

float sample_cloud_density(vec3 _position, float _height_fraction, float _lod)
{
    // Shear cloud top along wind direction.
    vec3 position = _position + u_WindDirection * u_WindShearOffset * _height_fraction; 

    // Animate clouds in wind direction and add a small upward bias to the wind direction.
    position += (u_WindDirection + vec3(0.0f, 0.1f, 0.0f)) * u_WindSpeed * u_Time;

    // Read the low-frequency Perlin-Worley and Worley noises.
    vec4 low_frequency_noises = textureLod(s_ShapeNoise, position * u_ShapeNoiseScale, _lod);

    // Build an FBM out of the low-frequency Worley noises to add detail to the low-frequeny Perlin-Worley noise.
    float low_freq_fbm = (low_frequency_noises.g * 0.625f) + (low_frequency_noises.b * 0.25f) + (low_frequency_noises.a * 0.125f);

    // Define the base cloud shape by dilating it with the low-frequency FBM made of Worley noise.
    float base_cloud = remap(low_frequency_noises.r, (1.0f - low_freq_fbm), 1.0f, 0.0f, 1.0f);

    // Get the density-height gradient using the density height function.
    float density_height_gradient = density_height_gradient_for_point(position, _height_fraction);

    // Apply the height function to the base cloud shape.
    base_cloud *= density_height_gradient;

    // Fetch cloud coverage value.
    float cloud_coverage = u_CloudCoverage;

    // Remap to apply the cloud coverage attribute.
    float base_cloud_with_coverage = remap(base_cloud, cloud_coverage, 1.0f, 0.0f, 1.0f);

    // Multiply result by the cloud coverage attribute so that smaller clouds are lighter and more aesthetically pleasing.
    base_cloud_with_coverage *= cloud_coverage;

    // Exit out if base cloud density is zero.
    if (base_cloud_with_coverage <= 0.0f)
        return 0.0f;

	// Sample curl noise texture.
	vec2 curl_noise = textureLod(s_CurlNoise, position.xz * u_TurbulenceNoiseScale, 0.0f).rg;
	
	// Add some turbulence to bottom of clouds.
	position.xy += curl_noise * (1.0f - _height_fraction) * u_TurbulenceAmount;

	// Sample high-frequency noises.
	vec3 high_frequency_noises = textureLod(s_DetailNoise, position * u_DetailNoiseScale, _lod).rgb;

	// Build high-frequency Worley noise FBM.
	float high_freq_fbm = (high_frequency_noises.r * 0.625f) + (high_frequency_noises.g * 0.25f) + (high_frequency_noises.b * 0.125f);

	// Transition from wispy shapes to billowy shapes over height.
	float high_freq_noise_modifier = mix(1.0f - high_freq_fbm, high_freq_fbm, clamp(_height_fraction * 10.0f, 0.0f, 1.0f));

	// Erode the base cloud shape with the distorted high-frequency Worley noise.
	float final_cloud = remap(base_cloud_with_coverage, high_freq_noise_modifier * u_DetailNoiseModifier, 1.0f, 0.0f, 1.0f);

    return final_cloud;
}

// ------------------------------------------------------------------

// GPU Pro 7
float beer_law(float density)
{
	float d = -density * u_Precipitation;// * _Density;
	return max(exp(d), exp(d * 0.5f) * 0.7f);
}

// ------------------------------------------------------------------

// GPU Pro 7
float henyey_greenstein_phase(float cos_angle, float g)
{
	float g2 = g * g;
	return ((1.0f - g2) / pow(1.0f + g2 - 2.0f * g * cos_angle, 1.5f)) / 4.0f * 3.1415f;
}

// ------------------------------------------------------------------

// GPU Pro 7
float powder_effect(float density, float cos_angle)
{
	float powder = 1.0f - exp(-density * 2.0f);
	return mix(1.0f, powder, clamp((-cos_angle * 0.5f) + 0.5f, 0.0f, 1.0f));
}

// ------------------------------------------------------------------

// calculates direct light components and multiplies them together
float calculate_light_energy(float density, float cos_angle, float powder_density) 
{ 
	float beer_powder = 2.0f * beer_law(density) * powder_effect(powder_density, cos_angle);
	float HG = max(henyey_greenstein_phase(cos_angle, u_HenyeyGreensteinGForward), henyey_greenstein_phase(cos_angle, u_HenyeyGreensteinGBackward)) * 0.07f + 0.8f;
	return beer_powder * HG;
}

// ------------------------------------------------------------------

vec3 sample_cone_to_light(vec3 pos, vec3 light_dir, float cos_angle, float density)
{
	const vec3 RandomUnitSphere[5] = // precalculated random vectors
	{
		{ -0.6, -0.8, -0.2 },
		{ 1.0, -0.3, 0.0 },
		{ -0.7, 0.0, 0.7 },
		{ -0.2, 0.6, -0.8 },
		{ 0.4, 0.3, 0.9 }
	};

	float density_along_cone = 0.0f;

	for (int i = 0; i < 5; i++) 
	{
		pos += light_dir * u_LightStepLength; // march forward
		vec3 random_offset = RandomUnitSphere[i] * u_LightStepLength * u_LightConeRadius * (float(i + 1));
		vec3 p = pos + random_offset; // light sample point
		// sample cloud
		float height_fraction = height_fraction_for_point(p); 
		density_along_cone += sample_cloud_density(p, height_fraction, float(i) * 0.5f);
	}

	// pos += 32.0f * u_LightStepLength * light_dir; // light sample from further away
	// float height_fraction = height_fraction_for_point(pos);
	// density_along_cone += sample_cloud_density(pos, height_fraction, 2.0f) * 3.0f;
	
	return calculate_light_energy(density_along_cone, cos_angle, density) * u_SunColor;
}

// ------------------------------------------------------------------

vec4 ray_march(vec3 ray_origin, vec3 ray_direction, float cos_angle, float num_steps)
{
	vec3  position    = ray_origin;
	vec4  result      = vec4(0.0f);
	float step_length = 1.0f;

	for (float i = 0.0f; i < num_steps; i+= step_length)
	{
		if (result.a >= 0.99f)
			break;

		float height_fraction = height_fraction_for_point(position);

		float density = sample_cloud_density(position, height_fraction, 0.0f);

		if (density > 0.0f)
		{
			vec4 particle = vec4(density); // construct cloud particle
			vec3 direct_light = sample_cone_to_light(position, u_SunDir, cos_angle, density); // calculate direct light energy and color
			vec3 ambient_light = mix(u_CloudBaseColor, u_CloudTopColor, height_fraction); // and ambient

			direct_light *= u_SunLightFactor; // multiply them by their uniform factors
			ambient_light *= u_AmbientLightFactor;

			particle.rgb = direct_light + ambient_light; // add lights up and set cloud particle color
			
			particle.rgb *= particle.a; // multiply color by clouds density
			result = vec4(1.0f - result.a) * particle + result; // use premultiplied alpha blending to acumulate samples
		}

		position += ray_direction * step_length;
	}

	return result;
}

// ------------------------------------------------------------------
// MAIN -------------------------------------------------------------
// ------------------------------------------------------------------

void main()
{
	Ray ray = generate_ray();

	vec3 ray_start = ray_sphere_intersection(ray, u_PlanetCenter, u_PlanetRadius + u_CloudMinHeight);
	vec3 ray_end   = ray_sphere_intersection(ray, u_PlanetCenter, u_PlanetRadius + u_CloudMaxHeight);

	float num_steps = mix(u_MaxNumSteps, u_MaxNumSteps * 0.5f, ray.direction.y);
	float step_size = length(ray_start - ray_end) / num_steps;

	ray_start += step_size * ray.direction * blue_noise();

	float cos_angle = dot(ray.direction, u_SunDir);
	vec4  clouds    = ray_march(ray_start, ray.direction * step_size, cos_angle, num_steps);
	vec4  sky       = vec4(calculateSkyLuminanceRGB(u_SunDir, ray.direction, 2.0f) * 0.05f, 1.0f);

    FS_OUT_Color = clouds.a * clouds.rgb + (1.0f - clouds.a) * sky.rgb;
}

// ------------------------------------------------------------------