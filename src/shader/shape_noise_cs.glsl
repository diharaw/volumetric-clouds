#include <noise.glsl>

// ------------------------------------------------------------------
// INPUTS -----------------------------------------------------------
// ------------------------------------------------------------------

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

// ------------------------------------------------------------------
// UNIFORMS ---------------------------------------------------------
// ------------------------------------------------------------------

layout(binding = 0, rgba16f) uniform image3D i_Noise;

uniform int u_Size;

// ------------------------------------------------------------------
// MAIN -------------------------------------------------------------
// ------------------------------------------------------------------

void main()
{
    vec3 tex_coord = (vec3(gl_GlobalInvocationID) + vec3(0.5f)) / float(u_Size);

    float perlin = mix(1.0f, perlin_fbm(tex_coord, 4.0f, 7), 0.5f);
    perlin = abs(perlin * 2. - 1.); // billowy perlin noise
    
    float freq = 4.0f;

    float worley0 = worley_fbm(tex_coord, freq);
    float worley1 = worley_fbm(tex_coord, freq * 2.0f);
    float worley2 = worley_fbm(tex_coord, freq * 4.0f);
 
    float perlin_worley = remap(perlin, 0.0f, 1.0f, worley0, 1.0f); // perlin-worley
 
    vec4 cloud = vec4(perlin_worley, worley0, worley1, worley2);

    imageStore(i_Noise, ivec3(gl_GlobalInvocationID), cloud);
}

// ------------------------------------------------------------------