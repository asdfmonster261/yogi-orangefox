/*
 * minuitwrp_gl - draws the recovery GUI with the phone's own GPU driver.
 *
 * gpu_stage.sh copies the driver into RAM at early-boot. It is loaded here into the
 * sphal linker namespace, because it needs newer libraries than this recovery has.
 * The GUI is drawn into a canvas texture that keeps its contents between frames, as
 * the CPU path's buffer does (the GUI redraws only what changed), and each flip
 * copies the canvas into the DRM dumb buffer about to be shown, imported over
 * EGL_EXT_image_dma_buf_import. No gralloc is involved.
 */
#include "minuitwrp_gl.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <sys/system_properties.h>
#include <unistd.h>

#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

#define EGL_FUNCS(X)                                                                     \
    X(eglGetDisplay) X(eglInitialize) X(eglTerminate) X(eglBindAPI) X(eglChooseConfig) \
    X(eglCreateContext) X(eglDestroyContext) X(eglMakeCurrent) X(eglGetCurrentContext) \
    X(eglGetError) X(eglGetProcAddress) X(eglQueryString)

#define GL_FUNCS(X)                                                                       \
    X(glGetString) X(glGetError) X(glGenTextures) X(glDeleteTextures) X(glBindTexture)   \
    X(glTexImage2D) X(glTexParameteri) X(glPixelStorei) X(glGenFramebuffers)             \
    X(glDeleteFramebuffers) X(glBindFramebuffer) X(glFramebufferTexture2D)               \
    X(glCheckFramebufferStatus) X(glViewport) X(glClearColor) X(glClear) X(glFinish)     \
    X(glEnable) X(glDisable) X(glScissor) X(glBlendFunc) X(glCreateShader)               \
    X(glShaderSource) X(glCompileShader) X(glGetShaderiv) X(glGetShaderInfoLog)          \
    X(glDeleteShader) X(glCreateProgram) X(glAttachShader) X(glBindAttribLocation)       \
    X(glLinkProgram) X(glGetProgramiv) X(glDeleteProgram) X(glUseProgram)                \
    X(glGetUniformLocation) X(glUniform1i) X(glUniform2f) X(glUniform4f)                 \
    X(glVertexAttribPointer) X(glEnableVertexAttribArray) X(glDrawArrays) X(glReadPixels)

struct Api {
#define DECLARE(name) decltype(&::name) name = nullptr;
    EGL_FUNCS(DECLARE)
    GL_FUNCS(DECLARE)
#undef DECLARE
    PFNEGLCREATEIMAGEKHRPROC eglCreateImageKHR = nullptr;
    PFNEGLDESTROYIMAGEKHRPROC eglDestroyImageKHR = nullptr;
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC glEGLImageTargetTexture2DOES = nullptr;
} api;

enum Mode { kSolid, kTexture, kOpaque, kSwapped, kCoverage };

const char kVertexShader[] =
    "attribute vec2 a_pos;\n"
    "attribute vec2 a_uv;\n"
    "uniform vec2 u_size;\n"
    "uniform vec2 u_texsize;\n"
    "varying vec2 v_uv;\n"
    "void main() {\n"
    "    v_uv = a_uv / u_texsize;\n"
    "    gl_Position = vec4(a_pos / u_size * 2.0 - 1.0, 0.0, 1.0);\n"
    "}\n";

// The canvas is 2400 texels tall, more than mediump can address one by one.
const char kFragmentShader[] =
    "#ifdef GL_FRAGMENT_PRECISION_HIGH\n"
    "precision highp float;\n"
    "#else\n"
    "precision mediump float;\n"
    "#endif\n"
    "uniform sampler2D u_tex;\n"
    "uniform vec4 u_color;\n"
    "uniform int u_mode;\n"
    "varying vec2 v_uv;\n"
    "void main() {\n"
    "    if (u_mode == 0) {\n"
    "        gl_FragColor = u_color;\n"
    "        return;\n"
    "    }\n"
    "    vec4 c = texture2D(u_tex, v_uv);\n"
    "    if (u_mode == 1) gl_FragColor = c;\n"
    "    else if (u_mode == 2) gl_FragColor = vec4(c.rgb, 1.0);\n"
    "    else if (u_mode == 3) gl_FragColor = c.bgra;\n"
    "    else gl_FragColor = vec4(u_color.rgb, c.a);\n"
    "}\n";

struct Target {
    EGLImageKHR image = EGL_NO_IMAGE_KHR;
    GLuint tex = 0;
    GLuint fbo = 0;
};

struct Cached {
    GLuint tex;
    const void* data;
    int width, height, stride, format;
};

struct Texture {
    GLuint tex = 0;
    int width = 0, height = 0, format = 0;
};

struct State {
    bool active = false;
    void* egl = nullptr;
    void* gles = nullptr;
    EGLDisplay dpy = EGL_NO_DISPLAY;
    EGLContext ctx = EGL_NO_CONTEXT;
    int width = 0, height = 0;
    std::vector<Target> targets;
    GLuint canvas = 0, canvas_fbo = 0, program = 0;
    GLint u_size = -1, u_texsize = -1, u_color = -1, u_mode = -1, u_tex = -1;
    float color[4] = {1, 1, 1, 1};
    bool clip = false;
    GLenum first_error = GL_NO_ERROR;
    // gr_gl_forget can come from any thread; textures are deleted where GL is current.
    std::mutex lock;
    std::unordered_map<const void*, Cached> cache;
    std::vector<GLuint> doomed;
} g;

void* LoadVendor(const char* path) {
    using LoadSphal = void* (*)(const char*, int);
    static LoadSphal load_sphal = [] {
        void* vndksupport = dlopen("libvndksupport.so", RTLD_NOW | RTLD_LOCAL);
        return vndksupport ? reinterpret_cast<LoadSphal>(
                                     dlsym(vndksupport, "android_load_sphal_library"))
                           : nullptr;
    }();
    return load_sphal ? load_sphal(path, RTLD_NOW | RTLD_GLOBAL) : nullptr;
}

bool LoadApi() {
    if (api.eglGetDisplay) return true;
    char egl_name[PROP_VALUE_MAX] = {};
    if (__system_property_get("ro.hardware.egl", egl_name) <= 0) return false;
    const std::string egl = std::string("/vendor/lib64/egl/libEGL_") + egl_name + ".so";
    const std::string gles = std::string("/vendor/lib64/egl/libGLESv2_") + egl_name + ".so";
    if (access(egl.c_str(), F_OK) != 0) {
        printf("I:GPU: %s is not staged, drawing on the CPU\n", egl.c_str());
        return false;
    }
    g.egl = LoadVendor(egl.c_str());
    g.gles = g.egl ? LoadVendor(gles.c_str()) : nullptr;
    if (!g.egl || !g.gles) {
        printf("E:GPU: cannot load the %s driver: %s\n", egl_name, dlerror());
        return false;
    }
    Api loaded;
    bool ok = true;
#define LOAD(lib, name)                                                         \
    loaded.name = reinterpret_cast<decltype(loaded.name)>(dlsym(g.lib, #name)); \
    if (!loaded.name) {                                                         \
        printf("E:GPU: the driver has no %s\n", #name);                         \
        ok = false;                                                             \
    }
#define LOAD_EGL(name) LOAD(egl, name)
#define LOAD_GL(name) LOAD(gles, name)
    EGL_FUNCS(LOAD_EGL)
    GL_FUNCS(LOAD_GL)
#undef LOAD_GL
#undef LOAD_EGL
#undef LOAD
    if (!ok) return false;
    loaded.eglCreateImageKHR = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(
            loaded.eglGetProcAddress("eglCreateImageKHR"));
    loaded.eglDestroyImageKHR = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(
            loaded.eglGetProcAddress("eglDestroyImageKHR"));
    loaded.glEGLImageTargetTexture2DOES = reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(
            loaded.eglGetProcAddress("glEGLImageTargetTexture2DOES"));
    if (!loaded.eglCreateImageKHR || !loaded.eglDestroyImageKHR ||
        !loaded.glEGLImageTargetTexture2DOES) {
        printf("E:GPU: the driver has no EGLImage support\n");
        return false;
    }
    api = loaded;
    return true;
}

void Fail(const char* what) {
    printf("E:GPU: %s failed (EGL %#x), drawing on the CPU from now on\n", what,
           api.eglGetError ? api.eglGetError() : 0);
    g.active = false;
}

// Makes the context current on the calling thread, which is all the GL entry points need.
bool Begin() {
    if (!g.active) return false;
    if (api.eglGetCurrentContext() != g.ctx &&
        !api.eglMakeCurrent(g.dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, g.ctx)) {
        Fail("eglMakeCurrent");
        return false;
    }
    std::vector<GLuint> doomed;
    {
        std::lock_guard<std::mutex> l(g.lock);
        doomed.swap(g.doomed);
    }
    if (!doomed.empty()) api.glDeleteTextures(doomed.size(), doomed.data());
    return true;
}

// Lets go of the context, so the next frame may come from another thread.
void End() {
    const GLenum error = api.glGetError();
    if (error != GL_NO_ERROR && g.first_error == GL_NO_ERROR) {
        g.first_error = error;
        printf("E:GPU: GL error %#x\n", error);
    }
    api.eglMakeCurrent(g.dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
}

void Draw(Mode mode, float l, float t, float r, float b, float u0, float v0, float u1, float v1,
          bool blend) {
    const GLfloat pos[] = {l, t, r, t, l, b, r, b};
    const GLfloat uv[] = {u0, v0, u1, v0, u0, v1, u1, v1};
    if (blend)
        api.glEnable(GL_BLEND);
    else
        api.glDisable(GL_BLEND);
    api.glUniform1i(g.u_mode, mode);
    api.glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, pos);
    api.glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, uv);
    api.glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

// The texture holding a surface, uploaded on first use.
Texture Upload(const GGLSurface* s) {
    Texture result;
    if (!s || !s->data || s->width == 0 || s->height == 0) return result;
    std::lock_guard<std::mutex> l(g.lock);
    auto it = g.cache.find(s);
    if (it != g.cache.end()) {
        const Cached& c = it->second;
        if (c.data == s->data && c.width == static_cast<int>(s->width) &&
            c.height == static_cast<int>(s->height) && c.stride == static_cast<int>(s->stride) &&
            c.format == s->format) {
            result.tex = c.tex;
            result.width = c.width;
            result.height = c.height;
            result.format = c.format;
            return result;
        }
        // The same struct now describes another image.
        api.glDeleteTextures(1, &c.tex);
        g.cache.erase(it);
    }

    GLenum format, type;
    int bpp;
    switch (s->format) {
        case GGL_PIXEL_FORMAT_RGBA_8888:
        case GGL_PIXEL_FORMAT_RGBX_8888:
        case GGL_PIXEL_FORMAT_BGRA_8888:
            format = GL_RGBA, type = GL_UNSIGNED_BYTE, bpp = 4;
            break;
        case GGL_PIXEL_FORMAT_RGB_565:
            format = GL_RGB, type = GL_UNSIGNED_SHORT_5_6_5, bpp = 2;
            break;
        case GGL_PIXEL_FORMAT_A_8:
            format = GL_ALPHA, type = GL_UNSIGNED_BYTE, bpp = 1;
            break;
        default:
            return result;
    }
    const int w = s->width, h = s->height;
    const GLubyte* pixels = s->data;
    std::vector<GLubyte> packed;
    if (s->stride != w) {
        packed.resize(static_cast<size_t>(w) * h * bpp);
        for (int y = 0; y < h; ++y)
            memcpy(&packed[static_cast<size_t>(y) * w * bpp],
                   s->data + static_cast<size_t>(y) * s->stride * bpp, static_cast<size_t>(w) * bpp);
        pixels = packed.data();
    }
    GLuint tex = 0;
    api.glGenTextures(1, &tex);
    api.glBindTexture(GL_TEXTURE_2D, tex);
    api.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    api.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    api.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    api.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    api.glTexImage2D(GL_TEXTURE_2D, 0, format, w, h, 0, format, type, pixels);
    g.cache[s] = Cached{tex, s->data, w, h, static_cast<int>(s->stride), s->format};
    result.tex = tex;
    result.width = w;
    result.height = h;
    result.format = s->format;
    return result;
}

GLuint Compile(GLenum kind, const char* source) {
    GLuint shader = api.glCreateShader(kind);
    api.glShaderSource(shader, 1, &source, nullptr);
    api.glCompileShader(shader);
    GLint ok = 0;
    api.glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[512] = {};
        api.glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
        printf("E:GPU: shader: %s\n", log);
        api.glDeleteShader(shader);
        return 0;
    }
    return shader;
}

bool MakeTarget(GLuint tex, GLuint* fbo) {
    api.glGenFramebuffers(1, fbo);
    api.glBindFramebuffer(GL_FRAMEBUFFER, *fbo);
    api.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    return api.glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
}

void Release() {
    if (g.dpy == EGL_NO_DISPLAY) return;
    if (g.ctx != EGL_NO_CONTEXT &&
        api.eglMakeCurrent(g.dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, g.ctx)) {
        for (auto& c : g.cache) api.glDeleteTextures(1, &c.second.tex);
        if (!g.doomed.empty()) api.glDeleteTextures(g.doomed.size(), g.doomed.data());
        for (auto& t : g.targets) {
            if (t.fbo) api.glDeleteFramebuffers(1, &t.fbo);
            if (t.tex) api.glDeleteTextures(1, &t.tex);
        }
        if (g.canvas_fbo) api.glDeleteFramebuffers(1, &g.canvas_fbo);
        if (g.canvas) api.glDeleteTextures(1, &g.canvas);
        if (g.program) api.glDeleteProgram(g.program);
        api.eglMakeCurrent(g.dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }
    for (auto& t : g.targets)
        if (t.image != EGL_NO_IMAGE_KHR) api.eglDestroyImageKHR(g.dpy, t.image);
    if (g.ctx != EGL_NO_CONTEXT) api.eglDestroyContext(g.dpy, g.ctx);
    api.eglTerminate(g.dpy);
    g.cache.clear();
    g.doomed.clear();
    g.targets.clear();
    g.canvas = g.canvas_fbo = g.program = 0;
    g.ctx = EGL_NO_CONTEXT;
    g.dpy = EGL_NO_DISPLAY;
    g.active = false;
}

bool Start(const gr_gl_buffer* buffers, int count) {
    g.dpy = api.eglGetDisplay(EGL_DEFAULT_DISPLAY);
    EGLint major = 0, minor = 0;
    if (g.dpy == EGL_NO_DISPLAY || !api.eglInitialize(g.dpy, &major, &minor)) {
        printf("E:GPU: eglInitialize failed (%#x)\n", api.eglGetError());
        return false;
    }
    const char* extensions = api.eglQueryString(g.dpy, EGL_EXTENSIONS);
    if (!extensions || !strstr(extensions, "EGL_EXT_image_dma_buf_import") ||
        !strstr(extensions, "EGL_KHR_surfaceless_context")) {
        printf("E:GPU: the driver cannot import dma-bufs or run without a surface\n");
        return false;
    }
    api.eglBindAPI(EGL_OPENGL_ES_API);
    const EGLint config_attribs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_RED_SIZE, 8,
                                     EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE};
    EGLConfig config;
    EGLint configs = 0;
    if (!api.eglChooseConfig(g.dpy, config_attribs, &config, 1, &configs) || configs != 1) {
        printf("E:GPU: no GLES2 config\n");
        return false;
    }
    const EGLint context_attribs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    g.ctx = api.eglCreateContext(g.dpy, config, EGL_NO_CONTEXT, context_attribs);
    if (g.ctx == EGL_NO_CONTEXT ||
        !api.eglMakeCurrent(g.dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, g.ctx)) {
        printf("E:GPU: no context (%#x)\n", api.eglGetError());
        return false;
    }

    g.width = buffers[0].width;
    g.height = buffers[0].height;
    for (int i = 0; i < count; ++i) {
        const EGLint image_attribs[] = {EGL_WIDTH, buffers[i].width,
                                        EGL_HEIGHT, buffers[i].height,
                                        EGL_LINUX_DRM_FOURCC_EXT, static_cast<EGLint>(buffers[i].fourcc),
                                        EGL_DMA_BUF_PLANE0_FD_EXT, buffers[i].fd,
                                        EGL_DMA_BUF_PLANE0_OFFSET_EXT, 0,
                                        EGL_DMA_BUF_PLANE0_PITCH_EXT, buffers[i].pitch,
                                        EGL_NONE};
        Target t;
        t.image = api.eglCreateImageKHR(g.dpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, nullptr,
                                        image_attribs);
        g.targets.push_back(t);
        Target& target = g.targets.back();
        if (target.image == EGL_NO_IMAGE_KHR) {
            printf("E:GPU: cannot import scanout buffer %d (%#x)\n", i, api.eglGetError());
            return false;
        }
        api.glGenTextures(1, &target.tex);
        api.glBindTexture(GL_TEXTURE_2D, target.tex);
        api.glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, target.image);
        if (!MakeTarget(target.tex, &target.fbo)) {
            printf("E:GPU: cannot render into scanout buffer %d\n", i);
            return false;
        }
    }

    api.glGenTextures(1, &g.canvas);
    api.glBindTexture(GL_TEXTURE_2D, g.canvas);
    api.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    api.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    api.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    api.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    api.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, g.width, g.height, 0, GL_RGBA, GL_UNSIGNED_BYTE,
                     nullptr);
    if (!MakeTarget(g.canvas, &g.canvas_fbo)) {
        printf("E:GPU: cannot render into the canvas\n");
        return false;
    }

    const GLuint vs = Compile(GL_VERTEX_SHADER, kVertexShader);
    const GLuint fs = Compile(GL_FRAGMENT_SHADER, kFragmentShader);
    if (!vs || !fs) return false;
    g.program = api.glCreateProgram();
    api.glAttachShader(g.program, vs);
    api.glAttachShader(g.program, fs);
    api.glBindAttribLocation(g.program, 0, "a_pos");
    api.glBindAttribLocation(g.program, 1, "a_uv");
    api.glLinkProgram(g.program);
    api.glDeleteShader(vs);
    api.glDeleteShader(fs);
    GLint linked = 0;
    api.glGetProgramiv(g.program, GL_LINK_STATUS, &linked);
    if (!linked) {
        printf("E:GPU: cannot link the shaders\n");
        return false;
    }
    api.glUseProgram(g.program);
    g.u_size = api.glGetUniformLocation(g.program, "u_size");
    g.u_texsize = api.glGetUniformLocation(g.program, "u_texsize");
    g.u_color = api.glGetUniformLocation(g.program, "u_color");
    g.u_mode = api.glGetUniformLocation(g.program, "u_mode");
    g.u_tex = api.glGetUniformLocation(g.program, "u_tex");
    api.glUniform1i(g.u_tex, 0);
    api.glUniform2f(g.u_size, g.width, g.height);
    api.glUniform2f(g.u_texsize, 1, 1);
    api.glUniform4f(g.u_color, g.color[0], g.color[1], g.color[2], g.color[3]);
    api.glEnableVertexAttribArray(0);
    api.glEnableVertexAttribArray(1);
    api.glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    api.glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    api.glPixelStorei(GL_PACK_ALIGNMENT, 1);
    api.glViewport(0, 0, g.width, g.height);

    api.glBindFramebuffer(GL_FRAMEBUFFER, g.canvas_fbo);
    api.glClearColor(0, 0, 0, 1);
    api.glClear(GL_COLOR_BUFFER_BIT);
    api.glFinish();
    if (api.glGetError() != GL_NO_ERROR) {
        printf("E:GPU: setup left a GL error\n");
        return false;
    }
    printf("I:GPU: drawing with %s %s, EGL %d.%d, %dx%d\n",
           reinterpret_cast<const char*>(api.glGetString(GL_VENDOR)),
           reinterpret_cast<const char*>(api.glGetString(GL_RENDERER)), major, minor, g.width,
           g.height);
    return true;
}

}  // namespace

bool gr_gl_init(const gr_gl_buffer* buffers, int count) {
    bool ok = count > 0 && LoadApi();
    if (ok) {
        g.active = true;
        ok = Start(buffers, count);
        if (ok)
            End();
        else
            Release();
    }
    for (int i = 0; i < count; ++i) close(buffers[i].fd);
    return ok;
}

bool gr_gl_active() {
    return g.active;
}

void gr_gl_exit() {
    if (g.active) Release();
}

void gr_gl_color(unsigned char r, unsigned char g_, unsigned char b, unsigned char a) {
    g.color[0] = r / 255.0f;
    g.color[1] = g_ / 255.0f;
    g.color[2] = b / 255.0f;
    g.color[3] = a / 255.0f;
    if (!Begin()) return;
    api.glUniform4f(g.u_color, g.color[0], g.color[1], g.color[2], g.color[3]);
}

void gr_gl_clip(int x, int y, int w, int h) {
    g.clip = true;
    if (!Begin()) return;
    api.glEnable(GL_SCISSOR_TEST);
    api.glScissor(x, y, w > 0 ? w : 0, h > 0 ? h : 0);
}

void gr_gl_noclip() {
    g.clip = false;
    if (!Begin()) return;
    api.glDisable(GL_SCISSOR_TEST);
}

void gr_gl_clear(unsigned char r, unsigned char g_, unsigned char b, unsigned char a) {
    if (!Begin()) return;
    api.glDisable(GL_SCISSOR_TEST);
    api.glClearColor(r / 255.0f, g_ / 255.0f, b / 255.0f, a / 255.0f);
    api.glClear(GL_COLOR_BUFFER_BIT);
    if (g.clip) api.glEnable(GL_SCISSOR_TEST);
}

void gr_gl_fill(int l, int t, int r, int b) {
    if (!Begin()) return;
    Draw(kSolid, l, t, r, b, 0, 0, 0, 0, g.color[3] < 1.0f);
}

void gr_gl_line(int x0, int y0, int x1, int y1, int width) {
    if (!Begin()) return;
    const float dx = x1 - x0, dy = y1 - y0;
    const float length = sqrtf(dx * dx + dy * dy);
    if (length == 0 || width <= 0) return;
    const float nx = -dy / length * width / 2, ny = dx / length * width / 2;
    const GLfloat pos[] = {x0 + nx, y0 + ny, x0 - nx, y0 - ny, x1 + nx, y1 + ny, x1 - nx, y1 - ny};
    const GLfloat uv[8] = {};
    if (g.color[3] < 1.0f)
        api.glEnable(GL_BLEND);
    else
        api.glDisable(GL_BLEND);
    api.glUniform1i(g.u_mode, kSolid);
    api.glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, pos);
    api.glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, uv);
    api.glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

void gr_gl_blit(const GGLSurface* surface, int sx, int sy, int l, int t, int r, int b) {
    if (!Begin()) return;
    const Texture tex = Upload(surface);
    if (!tex.tex) return;
    Mode mode = kTexture;
    if (tex.format == GGL_PIXEL_FORMAT_RGBX_8888 || tex.format == GGL_PIXEL_FORMAT_RGB_565)
        mode = kOpaque;
    else if (tex.format == GGL_PIXEL_FORMAT_BGRA_8888)
        mode = kSwapped;
    else if (tex.format == GGL_PIXEL_FORMAT_A_8)
        mode = kCoverage;
    api.glBindTexture(GL_TEXTURE_2D, tex.tex);
    api.glUniform2f(g.u_texsize, tex.width, tex.height);
    Draw(mode, l, t, r, b, sx, sy, sx + (r - l), sy + (b - t), mode != kOpaque);
}

void gr_gl_text(const GGLSurface* surface, int l, int t, int r, int b) {
    if (!Begin()) return;
    const Texture tex = Upload(surface);
    if (!tex.tex) return;
    api.glBindTexture(GL_TEXTURE_2D, tex.tex);
    api.glUniform2f(g.u_texsize, tex.width, tex.height);
    Draw(kCoverage, l, t, r, b, 0, 0, r - l, b - t, true);
}

void gr_gl_forget(const void* surface) {
    std::lock_guard<std::mutex> l(g.lock);
    auto it = g.cache.find(surface);
    if (it == g.cache.end()) return;
    g.doomed.push_back(it->second.tex);
    g.cache.erase(it);
}

void gr_gl_read(void* dst, int stride) {
    if (!Begin()) return;
    std::vector<GLubyte> rgba(static_cast<size_t>(g.width) * g.height * 4);
    api.glReadPixels(0, 0, g.width, g.height, GL_RGBA, GL_UNSIGNED_BYTE, rgba.data());
    for (int y = 0; y < g.height; ++y)
        memcpy(static_cast<GLubyte*>(dst) + static_cast<size_t>(y) * stride,
               &rgba[static_cast<size_t>(y) * g.width * 4], static_cast<size_t>(g.width) * 4);
    End();
}

void gr_gl_present(int index) {
    if (!Begin()) return;
    if (index < 0 || index >= static_cast<int>(g.targets.size())) return;
    api.glBindFramebuffer(GL_FRAMEBUFFER, g.targets[index].fbo);
    api.glDisable(GL_SCISSOR_TEST);
    api.glBindTexture(GL_TEXTURE_2D, g.canvas);
    api.glUniform2f(g.u_texsize, g.width, g.height);
    Draw(kOpaque, 0, 0, g.width, g.height, 0, 0, g.width, g.height, false);
    // The buffer goes to the display as soon as this returns.
    api.glFinish();
    api.glBindFramebuffer(GL_FRAMEBUFFER, g.canvas_fbo);
    if (g.clip) api.glEnable(GL_SCISSOR_TEST);
    End();
}
