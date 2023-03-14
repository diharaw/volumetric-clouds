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

// ------------------------------------------------------------------
// FUNCTIONS --------------------------------------------------------
// ------------------------------------------------------------------

Ray generate_ray()
{
    vec2 tex_coord_neg_to_pos = FS_IN_TexCoord * 2.0f - 1.0f;
    vec4 target = inv_view_proj * vec4(tex_coord_neg_to_pos, 0.0f, 1.0f);
    target /= target.w;

    Ray ray;

    ray.origin = cam_pos.xyz;
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
// MAIN -------------------------------------------------------------
// ------------------------------------------------------------------

void main()
{
    FS_OUT_Color = vec3(1.0f, 0.0f, 0.0f);
}

// ------------------------------------------------------------------