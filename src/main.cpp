#define _USE_MATH_DEFINES
#include <ogl.h>
#include <application.h>
#include <mesh.h>
#include <camera.h>
#include <material.h>
#include <memory>
#include <iostream>
#include <stack>
#include <random>
#include <chrono>
#include <random>
#include <fstream>

#define CAMERA_FAR_PLANE 1000.0f

struct GlobalUniforms
{
    DW_ALIGNED(16)
    glm::mat4 view_proj;
    DW_ALIGNED(16)
    glm::mat4 inv_view_proj;
    DW_ALIGNED(16)
    glm::vec4 cam_pos;
};

class VolumetricClouds : public dw::Application
{
protected:
    // -----------------------------------------------------------------------------------------------------------------------------------

    bool init(int argc, const char* argv[]) override
    {
        m_sun_angle = glm::radians(-58.0f);

        // Create camera.
        create_camera();

        // Create GPU resources.
        if (!create_shaders())
            return false;

        if (!create_textures())
            return false;

        if (!create_uniform_buffer())
            return false;

        // Load scene.
        if (!load_scene())
            return false;

        // Generate noise textures.
        generate_shape_noise_texture();
        generate_detail_noise_texture();

        return true;
    }

    // -----------------------------------------------------------------------------------------------------------------------------------

    void update(double delta) override
    {
        if (m_debug_gui)
            debug_gui();

        // Update camera.
        update_camera();

        update_uniforms();

        render_scene();
        render_clouds();
    }

    // -----------------------------------------------------------------------------------------------------------------------------------

    void debug_gui()
    {
        ImGui::SliderAngle("Sun Angle", &m_sun_angle, 0.0f, -180.0f);

        m_light_direction = glm::normalize(glm::vec3(0.0f, sin(m_sun_angle), cos(m_sun_angle)));
    }

    // -----------------------------------------------------------------------------------------------------------------------------------

    void window_resized(int width, int height) override
    {
        // Override window resized method to update camera projection.
        m_main_camera->update_projection(60.0f, 1.0f, CAMERA_FAR_PLANE, float(m_width) / float(m_height));
    }

    // -----------------------------------------------------------------------------------------------------------------------------------

    void key_pressed(int code) override
    {
        // Handle forward movement.
        if (code == GLFW_KEY_W)
            m_heading_speed = m_camera_speed;
        else if (code == GLFW_KEY_S)
            m_heading_speed = -m_camera_speed;

        // Handle sideways movement.
        if (code == GLFW_KEY_A)
            m_sideways_speed = -m_camera_speed;
        else if (code == GLFW_KEY_D)
            m_sideways_speed = m_camera_speed;

        if (code == GLFW_KEY_SPACE)
            m_mouse_look = true;

        if (code == GLFW_KEY_G)
            m_debug_gui = !m_debug_gui;
    }

    // -----------------------------------------------------------------------------------------------------------------------------------

    void key_released(int code) override
    {
        // Handle forward movement.
        if (code == GLFW_KEY_W || code == GLFW_KEY_S)
            m_heading_speed = 0.0f;

        // Handle sideways movement.
        if (code == GLFW_KEY_A || code == GLFW_KEY_D)
            m_sideways_speed = 0.0f;

        if (code == GLFW_KEY_SPACE)
            m_mouse_look = false;
    }

    // -----------------------------------------------------------------------------------------------------------------------------------

    void mouse_pressed(int code) override
    {
        // Enable mouse look.
        if (code == GLFW_MOUSE_BUTTON_RIGHT)
            m_mouse_look = true;
    }

    // -----------------------------------------------------------------------------------------------------------------------------------

    void mouse_released(int code) override
    {
        // Disable mouse look.
        if (code == GLFW_MOUSE_BUTTON_RIGHT)
            m_mouse_look = false;
    }

    // -----------------------------------------------------------------------------------------------------------------------------------

protected:
    // -----------------------------------------------------------------------------------------------------------------------------------

    dw::AppSettings intial_app_settings() override
    {
        dw::AppSettings settings;

        settings.maximized             = false;
        settings.major_ver             = 4;
        settings.width                 = 1920;
        settings.height                = 1080;
        settings.title                 = "Volumetric Clouds";
        settings.enable_debug_callback = false;

        return settings;
    }

    // -----------------------------------------------------------------------------------------------------------------------------------

private:
    // -----------------------------------------------------------------------------------------------------------------------------------

    bool create_shaders()
    {
        // Create general shaders
        m_mesh_vs = dw::gl::Shader::create_from_file(GL_VERTEX_SHADER, "shader/mesh_vs.glsl");
        m_mesh_fs = dw::gl::Shader::create_from_file(GL_FRAGMENT_SHADER, "shader/mesh_fs.glsl");

        if (!m_mesh_vs || !m_mesh_fs)
        {
            DW_LOG_FATAL("Failed to create Shaders");
            return false;
        }

        // Create general shader program
        m_mesh_program = dw::gl::Program::create({ m_mesh_vs, m_mesh_fs });

        if (!m_mesh_program)
        {
            DW_LOG_FATAL("Failed to create Shader Program");
            return false;
        }

        // Create clouds shaders
        m_triangle_vs = dw::gl::Shader::create_from_file(GL_VERTEX_SHADER, "shader/triangle_vs.glsl");
        m_clouds_fs = dw::gl::Shader::create_from_file(GL_FRAGMENT_SHADER, "shader/clouds_fs.glsl");

        if (!m_triangle_vs || !m_clouds_fs)
        {
            DW_LOG_FATAL("Failed to create Shaders");
            return false;
        }

        // Create general shader program
        m_clouds_program = dw::gl::Program::create({ m_triangle_vs, m_clouds_fs });

        if (!m_clouds_program)
        {
            DW_LOG_FATAL("Failed to create Shader Program");
            return false;
        }

        m_shape_noise_cs = dw::gl::Shader::create_from_file(GL_COMPUTE_SHADER, "shader/shape_noise_cs.glsl");

        // Create general shader program
        m_shape_noise_program = dw::gl::Program::create({ m_shape_noise_cs });

        if (!m_shape_noise_program)
        {
            DW_LOG_FATAL("Failed to create Shader Program");
            return false;
        }

        m_detail_noise_cs = dw::gl::Shader::create_from_file(GL_COMPUTE_SHADER, "shader/detail_noise_cs.glsl");

        // Create general shader program
        m_detail_noise_program = dw::gl::Program::create({ m_detail_noise_cs });

        if (!m_detail_noise_program)
        {
            DW_LOG_FATAL("Failed to create Shader Program");
            return false;
        }

        return true;
    }

    // -----------------------------------------------------------------------------------------------------------------------------------

    bool create_textures()
    {
        m_shape_noise_texture = dw::gl::Texture3D::create(128, 128, 128, 1, GL_R16F, GL_RED, GL_HALF_FLOAT); 
        m_detail_noise_texture = dw::gl::Texture3D::create(32, 32, 32, 1, GL_R16F, GL_RED, GL_HALF_FLOAT); 

        return true;
    }

    // -----------------------------------------------------------------------------------------------------------------------------------

    bool create_uniform_buffer()
    {
        // Create uniform buffer for global data
        m_global_ubo = dw::gl::Buffer::create(GL_UNIFORM_BUFFER, GL_MAP_WRITE_BIT, sizeof(GlobalUniforms));

        return true;
    }

    // -----------------------------------------------------------------------------------------------------------------------------------

    bool load_scene()
    {
        m_placeholder_texture = dw::gl::Texture2D::create_from_file("texture/grid.png");

        m_plane = dw::Mesh::load("mesh/plane.obj");

        if (!m_plane)
        {
            DW_LOG_FATAL("Failed to load mesh: plane");
            return false;
        }

        return true;
    }

    // -----------------------------------------------------------------------------------------------------------------------------------

    void create_camera()
    {
        m_main_camera = std::make_unique<dw::Camera>(60.0f, 1.0f, CAMERA_FAR_PLANE, float(m_width) / float(m_height), glm::vec3(0.0f, 5.0f, 0.0f), glm::vec3(-1.0f, 0.0, 0.0f));
        m_main_camera->update();
    }

    // -----------------------------------------------------------------------------------------------------------------------------------

    void generate_shape_noise_texture()
    {
        m_shape_noise_program->use();
        m_shape_noise_program->set_uniform("u_Size", (int)m_shape_noise_texture->width());
        
        m_shape_noise_texture->bind_image(0, 0, 0, GL_READ_WRITE, m_shape_noise_texture->internal_format());

        const uint32_t TEXTURE_SIZE = m_shape_noise_texture->width();
        const uint32_t NUM_THREADS  = 8;

        glDispatchCompute(TEXTURE_SIZE / NUM_THREADS, TEXTURE_SIZE / NUM_THREADS, TEXTURE_SIZE / NUM_THREADS);

        glFinish();
    }

    // -----------------------------------------------------------------------------------------------------------------------------------

    void generate_detail_noise_texture()
    {
        m_detail_noise_program->use();
        m_detail_noise_program->set_uniform("u_Size", (int)m_detail_noise_texture->width());

        m_detail_noise_texture->bind_image(0, 0, 0, GL_READ_WRITE, m_detail_noise_texture->internal_format());

        const uint32_t TEXTURE_SIZE = m_detail_noise_texture->width();
        const uint32_t NUM_THREADS  = 8;

        glDispatchCompute(TEXTURE_SIZE / NUM_THREADS, TEXTURE_SIZE / NUM_THREADS, TEXTURE_SIZE / NUM_THREADS);

        glFinish();
    }

    // -----------------------------------------------------------------------------------------------------------------------------------

    void render_mesh(dw::Mesh::Ptr mesh, glm::mat4 model)
    {
        if (m_mesh_program->set_uniform("s_Diffuse", 0))
            m_placeholder_texture->bind(0);

        m_mesh_program->set_uniform("u_LightDirection", m_light_direction);
        m_mesh_program->set_uniform("u_Model", model);

        // Bind vertex array.
        mesh->mesh_vertex_array()->bind();

        const auto& submeshes = mesh->sub_meshes();

        for (uint32_t i = 0; i < submeshes.size(); i++)
        {
            const dw::SubMesh& submesh = submeshes[i];

            // Issue draw call.
            glDrawElementsBaseVertex(GL_TRIANGLES, submesh.index_count, GL_UNSIGNED_INT, (void*)(sizeof(unsigned int) * submesh.base_index), submesh.base_vertex);
        }
    }

    // -----------------------------------------------------------------------------------------------------------------------------------

    void render_scene()
    {
        glEnable(GL_DEPTH_TEST);
        glDepthFunc(GL_LEQUAL);
        glDisable(GL_BLEND);
        glEnable(GL_CULL_FACE);
        glCullFace(GL_BACK);

        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glViewport(0, 0, m_width, m_height);

        glClearColor(0.3f, 0.3f, 0.3f, 1.0f);
        glClearDepth(1.0);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        // Bind shader program.
        m_mesh_program->use();

        // Bind uniform buffers.
        m_global_ubo->bind_base(0);

        // Draw scene.
        render_mesh(m_plane, glm::mat4(1.0f));
    }

    // -----------------------------------------------------------------------------------------------------------------------------------

    void render_clouds()
    {
        m_clouds_program->use();
        glDrawArrays(GL_TRIANGLES, 0, 3);
    }

    // -----------------------------------------------------------------------------------------------------------------------------------

    void update_uniforms()
    {
        // Global
        {
            void* ptr = m_global_ubo->map(GL_WRITE_ONLY);
            memcpy(ptr, &m_global_uniforms, sizeof(GlobalUniforms));
            m_global_ubo->unmap();
        }
    }

    // -----------------------------------------------------------------------------------------------------------------------------------

    void update_transforms(dw::Camera* camera)
    {
        // Update camera matrices.
        m_global_uniforms.view_proj     = camera->m_projection * camera->m_view;
        m_global_uniforms.inv_view_proj = glm::inverse(camera->m_projection * camera->m_view);
        m_global_uniforms.cam_pos       = glm::vec4(camera->m_position, 0.0f);
    }

    // -----------------------------------------------------------------------------------------------------------------------------------

    void update_camera()
    {
        dw::Camera* current = m_main_camera.get();

        float forward_delta = m_heading_speed * m_delta;
        float right_delta   = m_sideways_speed * m_delta;

        current->set_translation_delta(current->m_forward, forward_delta);
        current->set_translation_delta(current->m_right, right_delta);

        m_camera_x = m_mouse_delta_x * m_camera_sensitivity;
        m_camera_y = m_mouse_delta_y * m_camera_sensitivity;

        if (m_mouse_look)
        {
            // Activate Mouse Look
            current->set_rotatation_delta(glm::vec3((float)(m_camera_y),
                                                    (float)(m_camera_x),
                                                    (float)(0.0f)));
        }
        else
        {
            current->set_rotatation_delta(glm::vec3((float)(0),
                                                    (float)(0),
                                                    (float)(0)));
        }

        current->update();
        update_transforms(current);
    }

    // -----------------------------------------------------------------------------------------------------------------------------------

private:
    // General GPU resources.
    dw::gl::Shader::Ptr    m_mesh_vs;
    dw::gl::Shader::Ptr    m_mesh_fs;
    dw::gl::Shader::Ptr    m_triangle_vs;
    dw::gl::Shader::Ptr    m_clouds_fs;
    dw::gl::Shader::Ptr    m_shape_noise_cs;
    dw::gl::Shader::Ptr    m_detail_noise_cs;
    dw::gl::Program::Ptr   m_mesh_program;
    dw::gl::Program::Ptr   m_clouds_program;
    dw::gl::Program::Ptr   m_shape_noise_program;
    dw::gl::Program::Ptr   m_detail_noise_program;
    dw::gl::Buffer::Ptr    m_global_ubo;
    dw::gl::Texture2D::Ptr m_placeholder_texture;
    dw::gl::Texture3D::Ptr m_shape_noise_texture;
    dw::gl::Texture3D::Ptr m_detail_noise_texture;

    dw::Mesh::Ptr               m_plane;
    std::unique_ptr<dw::Camera> m_main_camera;

    float          m_sun_angle = 0.0f;
    glm::vec3      m_light_direction;
    GlobalUniforms m_global_uniforms;

    // Camera controls.
    bool  m_mouse_look         = false;
    float m_heading_speed      = 0.0f;
    float m_sideways_speed     = 0.0f;
    float m_camera_sensitivity = 0.05f;
    float m_camera_speed       = 0.05f;
    bool  m_debug_gui          = true;

    // Camera orientation.
    float m_camera_x;
    float m_camera_y;
};

DW_DECLARE_MAIN(VolumetricClouds)