// Full GLES 2.0 / 3.0 (+ common extension) forwarding table for the guest.
//
// libunity pulls every GL entrypoint through eglGetProcAddress. Each one is bound
// to a thunk running ONE generic forwarder, driven by a per-function signature
// string. The forwarder reads the armeabi-v7a softfp arguments (every arg is a
// 32-bit word in r0-r3/stack; 64-bit args take an aligned pair), converts them to
// host AAPCS64 (ints/pointers in x0-x7 then stack, floats in s0-s7) and calls the
// device's real libGLESv2/v3 entrypoint.
//
// Signature codes:  ret ':' args
//   i  32-bit int/enum/uint          l  GLintptr/GLsizeiptr (sign-extended)
//   f  float                         p  guest pointer -> host pointer (0 -> NULL)
//   A/E/U/K  pointer OR buffer offset: offset when an ARRAY / ELEMENT_ARRAY /
//            PIXEL_UNPACK / PIXEL_PACK buffer is bound, guest pointer otherwise
//   S  GLsync token                  q  64-bit (aligned register pair)
//   return: v void, i 32-bit, b GLboolean, S GLsync
// Functions whose arguments are arrays of guest pointers, or that hand back host
// pointers (strings, buffer mappings), are hand-written specials.
#include "cpu.h"
#include "guest.h"
#include "thunks_ctx.h"

#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <dlfcn.h>

#include <map>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace wst {

struct GLFn { const char* name; const char* sig; void* host; };

static GLFn kGL[] = {
    // ---- GLES 2.0 ----
    {"glActiveTexture","v:i"},{"glAttachShader","v:ii"},{"glBindAttribLocation","v:iip"},
    {"glBindBuffer","v:ii"},{"glBindFramebuffer","v:ii"},{"glBindRenderbuffer","v:ii"},
    {"glBindTexture","v:ii"},{"glBlendColor","v:ffff"},{"glBlendEquation","v:i"},
    {"glBlendEquationSeparate","v:ii"},{"glBlendFunc","v:ii"},{"glBlendFuncSeparate","v:iiii"},
    {"glBufferData","v:ilpi"},{"glBufferSubData","v:illp"},{"glCheckFramebufferStatus","i:i"},
    {"glClear","v:i"},{"glClearColor","v:ffff"},{"glClearDepthf","v:f"},{"glClearStencil","v:i"},
    {"glColorMask","v:iiii"},{"glCompileShader","v:i"},
    {"glCompressedTexImage2D","v:iiiiiiiU"},{"glCompressedTexSubImage2D","v:iiiiiiiiU"},
    {"glCopyTexImage2D","v:iiiiiiii"},{"glCopyTexSubImage2D","v:iiiiiiii"},
    {"glCreateProgram","i:"},{"glCreateShader","i:i"},{"glCullFace","v:i"},
    {"glDeleteBuffers","v:ip"},{"glDeleteFramebuffers","v:ip"},{"glDeleteProgram","v:i"},
    {"glDeleteRenderbuffers","v:ip"},{"glDeleteShader","v:i"},{"glDeleteTextures","v:ip"},
    {"glDepthFunc","v:i"},{"glDepthMask","v:i"},{"glDepthRangef","v:ff"},{"glDetachShader","v:ii"},
    {"glDisable","v:i"},{"glDisableVertexAttribArray","v:i"},{"glDrawArrays","v:iii"},
    {"glDrawElements","v:iiiE"},{"glEnable","v:i"},{"glEnableVertexAttribArray","v:i"},
    {"glFinish","v:"},{"glFlush","v:"},{"glFramebufferRenderbuffer","v:iiii"},
    {"glFramebufferTexture2D","v:iiiii"},{"glFrontFace","v:i"},{"glGenBuffers","v:ip"},
    {"glGenerateMipmap","v:i"},{"glGenFramebuffers","v:ip"},{"glGenRenderbuffers","v:ip"},
    {"glGenTextures","v:ip"},{"glGetActiveAttrib","v:iiipppp"},{"glGetActiveUniform","v:iiipppp"},
    {"glGetAttachedShaders","v:iipp"},{"glGetAttribLocation","i:ip"},{"glGetBooleanv","v:ip"},
    {"glGetBufferParameteriv","v:iip"},{"glGetError","i:"},{"glGetFloatv","v:ip"},
    {"glGetFramebufferAttachmentParameteriv","v:iiip"},{"glGetIntegerv","v:ip"},
    {"glGetProgramiv","v:iip"},{"glGetProgramInfoLog","v:iipp"},
    {"glGetRenderbufferParameteriv","v:iip"},{"glGetShaderiv","v:iip"},
    {"glGetShaderInfoLog","v:iipp"},{"glGetShaderPrecisionFormat","v:iipp"},
    {"glGetShaderSource","v:iipp"},{"glGetTexParameterfv","v:iip"},{"glGetTexParameteriv","v:iip"},
    {"glGetUniformfv","v:iip"},{"glGetUniformiv","v:iip"},{"glGetUniformLocation","i:ip"},
    {"glGetVertexAttribfv","v:iip"},{"glGetVertexAttribiv","v:iip"},{"glHint","v:ii"},
    {"glIsBuffer","b:i"},{"glIsEnabled","b:i"},{"glIsFramebuffer","b:i"},{"glIsProgram","b:i"},
    {"glIsRenderbuffer","b:i"},{"glIsShader","b:i"},{"glIsTexture","b:i"},{"glLineWidth","v:f"},
    {"glLinkProgram","v:i"},{"glPixelStorei","v:ii"},{"glPolygonOffset","v:ff"},
    {"glReadPixels","v:iiiiiiK"},{"glReleaseShaderCompiler","v:"},
    {"glRenderbufferStorage","v:iiii"},{"glSampleCoverage","v:fi"},{"glScissor","v:iiii"},
    {"glShaderBinary","v:ipipi"},{"glStencilFunc","v:iii"},{"glStencilFuncSeparate","v:iiii"},
    {"glStencilMask","v:i"},{"glStencilMaskSeparate","v:ii"},{"glStencilOp","v:iii"},
    {"glStencilOpSeparate","v:iiii"},{"glTexImage2D","v:iiiiiiiiU"},{"glTexParameterf","v:iif"},
    {"glTexParameterfv","v:iip"},{"glTexParameteri","v:iii"},{"glTexParameteriv","v:iip"},
    {"glTexSubImage2D","v:iiiiiiiiU"},
    {"glUniform1f","v:if"},{"glUniform1fv","v:iip"},{"glUniform1i","v:ii"},{"glUniform1iv","v:iip"},
    {"glUniform2f","v:iff"},{"glUniform2fv","v:iip"},{"glUniform2i","v:iii"},{"glUniform2iv","v:iip"},
    {"glUniform3f","v:ifff"},{"glUniform3fv","v:iip"},{"glUniform3i","v:iiii"},{"glUniform3iv","v:iip"},
    {"glUniform4f","v:iffff"},{"glUniform4fv","v:iip"},{"glUniform4i","v:iiiii"},{"glUniform4iv","v:iip"},
    {"glUniformMatrix2fv","v:iiip"},{"glUniformMatrix3fv","v:iiip"},{"glUniformMatrix4fv","v:iiip"},
    {"glUseProgram","v:i"},{"glValidateProgram","v:i"},
    {"glVertexAttrib1f","v:if"},{"glVertexAttrib1fv","v:ip"},{"glVertexAttrib2f","v:iff"},
    {"glVertexAttrib2fv","v:ip"},{"glVertexAttrib3f","v:ifff"},{"glVertexAttrib3fv","v:ip"},
    {"glVertexAttrib4f","v:iffff"},{"glVertexAttrib4fv","v:ip"},
    {"glVertexAttribPointer","v:iiiiiA"},{"glViewport","v:iiii"},
    // ---- GLES 3.0 ----
    {"glReadBuffer","v:i"},{"glDrawRangeElements","v:iiiiiE"},
    {"glTexImage3D","v:iiiiiiiiiU"},{"glTexSubImage3D","v:iiiiiiiiiiU"},
    {"glCopyTexSubImage3D","v:iiiiiiiii"},{"glCompressedTexImage3D","v:iiiiiiiiU"},
    {"glCompressedTexSubImage3D","v:iiiiiiiiiiU"},
    {"glGenQueries","v:ip"},{"glDeleteQueries","v:ip"},{"glIsQuery","b:i"},{"glBeginQuery","v:ii"},
    {"glEndQuery","v:i"},{"glGetQueryiv","v:iip"},{"glGetQueryObjectuiv","v:iip"},
    {"glDrawBuffers","v:ip"},
    {"glUniformMatrix2x3fv","v:iiip"},{"glUniformMatrix3x2fv","v:iiip"},{"glUniformMatrix2x4fv","v:iiip"},
    {"glUniformMatrix4x2fv","v:iiip"},{"glUniformMatrix3x4fv","v:iiip"},{"glUniformMatrix4x3fv","v:iiip"},
    {"glBlitFramebuffer","v:iiiiiiiiii"},{"glRenderbufferStorageMultisample","v:iiiii"},
    {"glFramebufferTextureLayer","v:iiiii"},
    {"glBindVertexArray","v:i"},{"glDeleteVertexArrays","v:ip"},{"glGenVertexArrays","v:ip"},
    {"glIsVertexArray","b:i"},{"glGetIntegeri_v","v:iip"},{"glBeginTransformFeedback","v:i"},
    {"glEndTransformFeedback","v:"},{"glBindBufferRange","v:iiill"},{"glBindBufferBase","v:iii"},
    {"glGetTransformFeedbackVarying","v:iiipppp"},{"glVertexAttribIPointer","v:iiiiA"},
    {"glGetVertexAttribIiv","v:iip"},{"glGetVertexAttribIuiv","v:iip"},
    {"glVertexAttribI4i","v:iiiii"},{"glVertexAttribI4ui","v:iiiii"},
    {"glVertexAttribI4iv","v:ip"},{"glVertexAttribI4uiv","v:ip"},{"glGetUniformuiv","v:iip"},
    {"glGetFragDataLocation","i:ip"},{"glUniform1ui","v:ii"},{"glUniform2ui","v:iii"},
    {"glUniform3ui","v:iiii"},{"glUniform4ui","v:iiiii"},{"glUniform1uiv","v:iip"},
    {"glUniform2uiv","v:iip"},{"glUniform3uiv","v:iip"},{"glUniform4uiv","v:iip"},
    {"glClearBufferiv","v:iip"},{"glClearBufferuiv","v:iip"},{"glClearBufferfv","v:iip"},
    {"glClearBufferfi","v:iifi"},{"glCopyBufferSubData","v:iilll"},
    {"glGetActiveUniformsiv","v:iipip"},{"glGetUniformBlockIndex","i:ip"},
    {"glGetActiveUniformBlockiv","v:iiip"},{"glGetActiveUniformBlockName","v:iiipp"},
    {"glUniformBlockBinding","v:iii"},{"glDrawArraysInstanced","v:iiii"},
    {"glDrawElementsInstanced","v:iiiEi"},
    {"glFenceSync","S:ii"},{"glIsSync","b:S"},{"glDeleteSync","v:S"},{"glClientWaitSync","i:Siq"},
    {"glWaitSync","v:Siq"},{"glGetInteger64v","v:ip"},{"glGetSynciv","v:Siipp"},
    {"glGetInteger64i_v","v:iip"},{"glGetBufferParameteri64v","v:iip"},
    {"glGenSamplers","v:ip"},{"glDeleteSamplers","v:ip"},{"glIsSampler","b:i"},{"glBindSampler","v:ii"},
    {"glSamplerParameteri","v:iii"},{"glSamplerParameteriv","v:iip"},{"glSamplerParameterf","v:iif"},
    {"glSamplerParameterfv","v:iip"},{"glGetSamplerParameteriv","v:iip"},
    {"glGetSamplerParameterfv","v:iip"},{"glVertexAttribDivisor","v:ii"},
    {"glBindTransformFeedback","v:ii"},{"glDeleteTransformFeedbacks","v:ip"},
    {"glGenTransformFeedbacks","v:ip"},{"glIsTransformFeedback","b:i"},
    {"glPauseTransformFeedback","v:"},{"glResumeTransformFeedback","v:"},
    {"glGetProgramBinary","v:iippp"},{"glProgramBinary","v:iipi"},{"glProgramParameteri","v:iii"},
    {"glInvalidateFramebuffer","v:iip"},{"glInvalidateSubFramebuffer","v:iipiiii"},
    {"glTexStorage2D","v:iiiii"},{"glTexStorage3D","v:iiiiii"},{"glGetInternalformativ","v:iiiip"},
    // ---- common extensions ----
    {"glBindVertexArrayOES","v:i"},{"glDeleteVertexArraysOES","v:ip"},{"glGenVertexArraysOES","v:ip"},
    {"glIsVertexArrayOES","b:i"},{"glDiscardFramebufferEXT","v:iip"},
    {"glRenderbufferStorageMultisampleEXT","v:iiiii"},{"glRenderbufferStorageMultisampleIMG","v:iiiii"},
    {"glFramebufferTexture2DMultisampleEXT","v:iiiiii"},{"glFramebufferTexture2DMultisampleIMG","v:iiiiii"},
    {"glGetProgramBinaryOES","v:iippp"},{"glProgramBinaryOES","v:iipi"},
    {"glTexStorage2DEXT","v:iiiii"},{"glDrawBuffersEXT","v:ip"},{"glDrawBuffersNV","v:ip"},
    {"glGenQueriesEXT","v:ip"},{"glDeleteQueriesEXT","v:ip"},{"glBeginQueryEXT","v:ii"},
    {"glEndQueryEXT","v:i"},{"glQueryCounterEXT","v:ii"},{"glGetQueryObjectuivEXT","v:iip"},
    {"glGetQueryObjectui64vEXT","v:iip"},{"glGetQueryivEXT","v:iip"},{"glIsQueryEXT","b:i"},
    {"glInsertEventMarkerEXT","v:ip"},{"glPushGroupMarkerEXT","v:ip"},{"glPopGroupMarkerEXT","v:"},
    {"glLabelObjectEXT","v:iiip"},{"glDrawArraysInstancedEXT","v:iiii"},
    {"glDrawElementsInstancedEXT","v:iiiEi"},{"glVertexAttribDivisorEXT","v:ii"},
    {"glBlitFramebufferNV","v:iiiiiiiiii"},{"glBlitFramebufferANGLE","v:iiiiiiiiii"},
    {"glTexImage3DOES","v:iiiiiiiiiU"},{"glTexSubImage3DOES","v:iiiiiiiiiiU"},
    {"glCompressedTexImage3DOES","v:iiiiiiiiU"},{"glCompressedTexSubImage3DOES","v:iiiiiiiiiiU"},
    {"glFramebufferTexture3DOES","v:iiiiii"},
};

static bool g_gles3 = false;
static std::unordered_map<std::string, GLFn*> g_byname;
static std::vector<GLFn*> g_byidx;       // svc index -> entry (lazily filled)
static std::mutex g_mu;
static void* g_libgl = nullptr;

static void* host_gl(const char* n) {
    void* f = g_libgl ? dlsym(g_libgl, n) : nullptr;
    if (!f) f = (void*)eglGetProcAddress(n);
    return f;
}

static GLFn* cur_fn() {
    u32 i = thunk_cur_index();
    {
        std::lock_guard<std::mutex> lk(g_mu);
        if (i < g_byidx.size() && g_byidx[i]) return g_byidx[i];
        const char* nm = thunk_cur_name();
        if (!strncmp(nm, "gl:", 3)) nm += 3;
        auto it = g_byname.find(nm);
        GLFn* f = it != g_byname.end() ? it->second : nullptr;
        if (i >= g_byidx.size()) g_byidx.resize(i + 1, nullptr);
        g_byidx[i] = f;
        return f;
    }
}

// ---- GLsync tokens ----
static std::vector<void*> g_syncs;
static u32 sync_tok(void* s) {
    if (!s) return 0;
    std::lock_guard<std::mutex> lk(g_mu);
    g_syncs.push_back(s);
    return 0xFD000000u | u32(g_syncs.size() - 1);
}
static void* sync_unh(u32 t) {
    if (t < 0xFD000000u) return nullptr;
    std::lock_guard<std::mutex> lk(g_mu);
    u32 i = t - 0xFD000000u;
    return i < g_syncs.size() ? g_syncs[i] : nullptr;
}

static bool buffer_bound(char code) {
    GLenum q = 0;
    switch (code) {
        case 'A': q = 0x8894; break;                       // ARRAY_BUFFER_BINDING
        case 'E': q = 0x8895; break;                       // ELEMENT_ARRAY_BUFFER_BINDING
        case 'U': if (!g_gles3) return false; q = 0x88EF; break;  // PIXEL_UNPACK_BUFFER_BINDING
        case 'K': if (!g_gles3) return false; q = 0x88ED; break;  // PIXEL_PACK_BUFFER_BINDING
    }
    GLint b = 0; glGetIntegerv(q, &b);
    return b != 0;
}

using HostFn = u64 (*)(u64, u64, u64, u64, u64, u64, u64, u64,
                       float, float, float, float, float, float, float, float,
                       u64, u64, u64, u64);

static int g_trace_left = 0;   // first N GL calls are logged (bring-up aid)

static void h_glfwd(Ctx& c) {
    GLFn* fn = cur_fn();
    if (!fn || !fn->host) {
        logf("[gl] call to unavailable %s", fn ? fn->name : thunk_cur_name());
        c.ret(0); return;
    }
    const char* s = fn->sig;
    char rc = s[0];
    s += 2;
    u64 x[12] = {0}; int nx = 0;
    float v[8] = {0}; int nv = 0;
    int gi = 0;
    for (; *s; ++s) {
        switch (*s) {
            case 'i': x[nx++] = c.arg(gi++); break;
            case 'l': x[nx++] = u64(s64(s32(c.arg(gi++)))); break;
            case 'f': { u32 b = c.arg(gi++); float f; memcpy(&f, &b, 4); v[nv++] = f; break; }
            case 'p': { u32 g = c.arg(gi++); x[nx++] = g ? u64(uintptr_t(g_base + g)) : 0; break; }
            case 'A': case 'E': case 'U': case 'K': {
                u32 g = c.arg(gi++);
                x[nx++] = (!g || buffer_bound(*s)) ? u64(g) : u64(uintptr_t(g_base + g));
                break;
            }
            case 'S': x[nx++] = u64(uintptr_t(sync_unh(c.arg(gi++)))); break;
            case 'q': gi = (gi + 1) & ~1; x[nx++] = u64(c.arg(gi)) | (u64(c.arg(gi + 1)) << 32); gi += 2; break;
        }
    }
    if (g_trace_left > 0) { --g_trace_left; logf("[gl] %s", fn->name); }
    u64 r = ((HostFn)fn->host)(x[0], x[1], x[2], x[3], x[4], x[5], x[6], x[7],
                               v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7],
                               x[8], x[9], x[10], x[11]);
    switch (rc) {
        case 'i': c.ret(u32(r)); break;
        case 'b': c.ret(u32(r) & 0xFF); break;
        case 'S': c.ret(sync_tok((void*)uintptr_t(r))); break;
        default:  c.ret(0); break;
    }
}

// =====================================================================
// specials
// =====================================================================
static std::map<std::pair<u32, u32>, gaddr> g_strs;
static gaddr cached_str(u32 name, u32 idx, const GLubyte* s) {
    std::lock_guard<std::mutex> lk(g_mu);
    auto k = std::make_pair(name, idx);
    auto it = g_strs.find(k);
    if (it != g_strs.end()) return it->second;
    gaddr g = gstrdup(s ? (const char*)s : "");
    g_strs[k] = g;
    return g;
}
static void h_glGetString(Ctx& c) {
    u32 n = c.arg(0);
    const GLubyte* s = glGetString(n);
    if (n == GL_VERSION && s) {
        g_gles3 = strstr((const char*)s, "OpenGL ES 3") != nullptr;
        logf("[gl] GL_VERSION \"%s\" renderer \"%s\"", s, glGetString(GL_RENDERER));
    }
    c.retp(s ? cached_str(n, 0xFFFFFFFF, s) : 0);
}
static void h_glGetStringi(Ctx& c) {
    using F = const GLubyte* (*)(GLenum, GLuint);
    static F f = (F)host_gl("glGetStringi");
    const GLubyte* s = f ? f(c.arg(0), c.arg(1)) : nullptr;
    c.retp(s ? cached_str(c.arg(0), c.arg(1), s) : 0);
}

// Arrays of guest char* -> host char*.
static std::vector<const char*> str_array(gaddr arr, u32 n) {
    std::vector<const char*> v(n);
    for (u32 i = 0; i < n; ++i) { u32 p = rd32(arr + i * 4); v[i] = p ? HS(p) : nullptr; }
    return v;
}
// ---- shaders ----
// Unity 5 ships GLSL ES 1.00 shaders; with native shadow maps their fragment shaders use
// GL_EXT_shadow_samplers (shadow2DEXT). The emulator's GLES compiler refuses that
// extension under "#version 100" ("extension is not supported"), so those programs never
// linked and shadowed materials drew nothing. Fallback, only when the host refuses a
// shader that way: rewrite the program's shaders to GLSL ES 3.00, where shadow samplers
// are core, and compile them again. A driver that accepts the original never gets here.
struct ShaderSrc { std::string src; bool upgraded = false; };
static std::mutex g_sh_mu;
static std::unordered_map<GLuint, ShaderSrc> g_sh;
static int g_shader_fail_logs = 0, g_upgrade_logs = 0;

static void re_all(std::string& s, const std::string& from, const std::string& to) {
    // whole-identifier replace
    auto ident = [](char ch) { return isalnum((unsigned char)ch) || ch == '_'; };
    for (size_t p = 0; (p = s.find(from, p)) != std::string::npos;) {
        bool l = p == 0 || !ident(s[p - 1]);
        bool r = p + from.size() >= s.size() || !ident(s[p + from.size()]);
        if (l && r) { s.replace(p, from.size(), to); p += to.size(); } else p += from.size();
    }
}
static std::string to_es300(const std::string& in, bool frag) {
    std::string out, body;
    bool has_frag_out = false;
    size_t p = 0;
    while (p < in.size()) {                          // drop #version / ES2-only #extension lines
        size_t q = in.find('\n', p); if (q == std::string::npos) q = in.size();
        std::string line = in.substr(p, q - p);
        std::string t = line.substr(line.find_first_not_of(" \t") == std::string::npos ? line.size() : line.find_first_not_of(" \t"));
        bool drop = t.rfind("#version", 0) == 0 ||
            (t.rfind("#extension", 0) == 0 &&
             (t.find("GL_EXT_shadow_samplers") != std::string::npos || t.find("GL_OES_standard_derivatives") != std::string::npos ||
              t.find("GL_EXT_shader_texture_lod") != std::string::npos || t.find("GL_EXT_frag_depth") != std::string::npos ||
              t.find("GL_EXT_draw_buffers") != std::string::npos));
        if (!drop) { body += line; body += '\n'; }
        p = q + 1;
    }
    if (frag) {
        re_all(body, "varying", "in");
        if (body.find("gl_FragColor") != std::string::npos || body.find("gl_FragData") != std::string::npos) has_frag_out = true;
        for (const char* d : {"gl_FragData[0]", "gl_FragData [0]"})
            for (size_t k; (k = body.find(d)) != std::string::npos;) body.replace(k, strlen(d), "wst_FragColor");
        re_all(body, "gl_FragColor", "wst_FragColor");
        re_all(body, "gl_FragDepthEXT", "gl_FragDepth");
    } else {
        re_all(body, "attribute", "in");
        re_all(body, "varying", "out");
    }
    re_all(body, "texture2DProjLodEXT", "textureProjLod");
    re_all(body, "texture2DLodEXT", "textureLod");
    re_all(body, "textureCubeLodEXT", "textureLod");
    re_all(body, "texture2DGradEXT", "textureGrad");
    re_all(body, "shadow2DProjEXT", "textureProj");
    re_all(body, "shadow2DEXT", "texture");
    re_all(body, "texture2DProj", "textureProj");
    re_all(body, "texture2D", "texture");
    re_all(body, "textureCube", "texture");
    out = "#version 300 es\n";
    if (frag && has_frag_out) out += "out mediump vec4 wst_FragColor;\n";
    return out + body;
}
static bool compile_ok(GLuint sh) { GLint ok = 0; glGetShaderiv(sh, GL_COMPILE_STATUS, &ok); return ok != 0; }
static bool upgrade_shader(GLuint sh) {          // caller holds g_sh_mu
    auto it = g_sh.find(sh);
    if (it == g_sh.end() || it->second.upgraded) return it != g_sh.end();
    GLint type = 0; glGetShaderiv(sh, GL_SHADER_TYPE, &type);
    std::string up = to_es300(it->second.src, type == GL_FRAGMENT_SHADER);
    const char* p = up.c_str();
    glShaderSource(sh, 1, &p, nullptr);
    glCompileShader(sh);
    it->second.upgraded = true;
    bool ok = compile_ok(sh);
    if (!ok && g_upgrade_logs < 6) {
        ++g_upgrade_logs;
        char log[1024] = {0}; glGetShaderInfoLog(sh, sizeof log - 1, nullptr, log);
        logf("[gl] ES3 rewrite of shader %u still fails: %s", sh, log);
    }
    return ok;
}

static void h_glShaderSource(Ctx& c) {
    u32 n = c.arg(1);
    auto v = str_array(c.argp(2), n);
    gaddr lens = c.argp(3);
    std::string all;
    for (u32 i = 0; i < n; ++i) {
        if (!v[i]) continue;
        int l = lens ? int(rd32(lens + i * 4)) : -1;
        all += l < 0 ? std::string(v[i]) : std::string(v[i], size_t(l));
    }
    { std::lock_guard<std::mutex> lk(g_sh_mu); g_sh[c.arg(0)] = ShaderSrc{all, false}; }
    glShaderSource(c.arg(0), GLsizei(n), v.data(), (const GLint*)H(lens));
    c.ret(0);
}
static void h_glCompileShader(Ctx& c) {
    GLuint sh = c.arg(0);
    glCompileShader(sh);
    if (compile_ok(sh)) { c.ret(0); return; }
    char log[1024] = {0}; glGetShaderInfoLog(sh, sizeof log - 1, nullptr, log);
    bool shadow = false;
    { std::lock_guard<std::mutex> lk(g_sh_mu); auto it = g_sh.find(sh);
      shadow = it != g_sh.end() && it->second.src.find("GL_EXT_shadow_samplers") != std::string::npos; }
    if (shadow) {
        std::lock_guard<std::mutex> lk(g_sh_mu);
        bool ok = upgrade_shader(sh);
        if (g_upgrade_logs < 6) { ++g_upgrade_logs; logf("[gl] shader %u: host refused GL_EXT_shadow_samplers -> GLSL ES 3.00 %s", sh, ok ? "OK" : "FAILED"); }
        c.ret(0); return;
    }
    if (g_shader_fail_logs < 12) {
        ++g_shader_fail_logs;
        GLint type = 0; glGetShaderiv(sh, GL_SHADER_TYPE, &type);
        char src[200] = {0}; glGetShaderSource(sh, sizeof src - 1, nullptr, src);
        for (char& ch : src) if (ch == '\n') ch = '|';
        logf("[gl] COMPILE FAILED (%s shader %u): %s  src: %.160s", type == GL_VERTEX_SHADER ? "vertex" : "fragment", sh, log, src);
    }
    c.ret(0);
}
static void h_glLinkProgram(Ctx& c) {
    GLuint pr = c.arg(0);
    {   // one upgraded shader drags the rest of the program to the same version
        GLuint sh[8]; GLsizei n = 0; glGetAttachedShaders(pr, 8, &n, sh);
        std::lock_guard<std::mutex> lk(g_sh_mu);
        bool any = false;
        for (GLsizei i = 0; i < n; ++i) { auto it = g_sh.find(sh[i]); if (it != g_sh.end() && it->second.upgraded) any = true; }
        if (any) for (GLsizei i = 0; i < n; ++i) upgrade_shader(sh[i]);
    }
    glLinkProgram(pr);
    GLint ok = 1; glGetProgramiv(pr, GL_LINK_STATUS, &ok);
    if (!ok && g_shader_fail_logs < 12) {
        ++g_shader_fail_logs;
        char log[1024] = {0}; glGetProgramInfoLog(pr, sizeof log - 1, nullptr, log);
        logf("[gl] LINK FAILED (program %u): %s", pr, log);
    }
    c.ret(0);
}
static void h_glTransformFeedbackVaryings(Ctx& c) {
    using F = void (*)(GLuint, GLsizei, const char* const*, GLenum);
    static F f = (F)host_gl("glTransformFeedbackVaryings");
    auto v = str_array(c.argp(2), c.arg(1));
    if (f) f(c.arg(0), GLsizei(c.arg(1)), v.data(), c.arg(3));
    c.ret(0);
}
static void h_glGetUniformIndices(Ctx& c) {
    using F = void (*)(GLuint, GLsizei, const char* const*, GLuint*);
    static F f = (F)host_gl("glGetUniformIndices");
    auto v = str_array(c.argp(2), c.arg(1));
    if (f) f(c.arg(0), GLsizei(c.arg(1)), v.data(), (GLuint*)H(c.argp(3)));
    c.ret(0);
}
static void h_zero_ptr_out(Ctx& c) {   // gl*Pointerv: (a, b, void** out) — not supported
    if (c.argp(2)) wr32(c.argp(2), 0);
    c.ret(0);
}
static void h_noop(Ctx& c) { c.ret(0); }

// ---- buffer mapping: host mappings live outside guest space, so the guest gets
// a shadow copy, written back on flush/unmap ----
struct Mapping { gaddr shadow; u8* host; u32 len; u32 access; };
static std::unordered_map<u32, Mapping> g_maps;   // target -> mapping
static constexpr u32 kMapRead = 1, kMapWrite = 2, kMapFlushExplicit = 0x10;

static gaddr make_mapping(u32 target, void* host, u32 len, u32 access) {
    if (!host) return 0;
    gaddr sh = gmalloc(len ? len : 4);
    if (access & kMapRead) memcpy(H(sh), host, len);
    std::lock_guard<std::mutex> lk(g_mu);
    g_maps[target] = {sh, (u8*)host, len, access};
    return sh;
}
static void h_glMapBufferRange(Ctx& c) {
    using F = void* (*)(GLenum, GLintptr, GLsizeiptr, GLbitfield);
    static F f = (F)host_gl("glMapBufferRange");
    u32 target = c.arg(0), len = c.arg(2), access = c.arg(3);
    void* h = f ? f(target, GLintptr(s32(c.arg(1))), GLsizeiptr(len), access) : nullptr;
    c.retp(make_mapping(target, h, len, access));
}
static void h_glMapBufferOES(Ctx& c) {
    using F = void* (*)(GLenum, GLenum);
    static F f = (F)host_gl("glMapBufferOES");
    u32 target = c.arg(0);
    GLint size = 0; glGetBufferParameteriv(target, GL_BUFFER_SIZE, &size);
    void* h = f ? f(target, c.arg(1)) : nullptr;
    c.retp(make_mapping(target, h, u32(size), kMapWrite));
}
static void h_glFlushMappedBufferRange(Ctx& c) {
    using F = void (*)(GLenum, GLintptr, GLsizeiptr);
    static F f = (F)host_gl("glFlushMappedBufferRange");
    u32 target = c.arg(0), off = c.arg(1), len = c.arg(2);
    {
        std::lock_guard<std::mutex> lk(g_mu);
        auto it = g_maps.find(target);
        if (it != g_maps.end() && off + len <= it->second.len)
            memcpy(it->second.host + off, H(it->second.shadow + off), len);
    }
    if (f) f(target, GLintptr(off), GLsizeiptr(len));
    c.ret(0);
}
static GLboolean unmap_common(u32 target, const char* sym) {
    using F = GLboolean (*)(GLenum);
    Mapping m{};
    bool have = false;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        auto it = g_maps.find(target);
        if (it != g_maps.end()) { m = it->second; have = true; g_maps.erase(it); }
    }
    if (have && (m.access & kMapWrite) && !(m.access & kMapFlushExplicit))
        memcpy(m.host, H(m.shadow), m.len);
    F f = (F)host_gl(sym);
    GLboolean r = f ? f(target) : GL_FALSE;
    if (have) gfree(m.shadow);
    return r;
}
static void h_glUnmapBuffer(Ctx& c)    { c.ret(unmap_common(c.arg(0), "glUnmapBuffer")); }
static void h_glUnmapBufferOES(Ctx& c) { c.ret(unmap_common(c.arg(0), "glUnmapBufferOES")); }

struct Special { const char* name; Handler fn; };
static const Special kSpecial[] = {
    {"glGetString", h_glGetString}, {"glGetStringi", h_glGetStringi},
    {"glShaderSource", h_glShaderSource},
    {"glCompileShader", h_glCompileShader},
    {"glLinkProgram", h_glLinkProgram},
    {"glTransformFeedbackVaryings", h_glTransformFeedbackVaryings},
    {"glGetUniformIndices", h_glGetUniformIndices},
    {"glGetVertexAttribPointerv", h_zero_ptr_out}, {"glGetBufferPointerv", h_zero_ptr_out},
    {"glGetBufferPointervOES", h_zero_ptr_out},
    {"glMapBufferRange", h_glMapBufferRange}, {"glMapBufferRangeEXT", h_glMapBufferRange},
    {"glMapBufferOES", h_glMapBufferOES},
    {"glFlushMappedBufferRange", h_glFlushMappedBufferRange},
    {"glFlushMappedBufferRangeEXT", h_glFlushMappedBufferRange},
    {"glUnmapBuffer", h_glUnmapBuffer}, {"glUnmapBufferOES", h_glUnmapBufferOES},
    {"glDebugMessageCallback", h_noop}, {"glDebugMessageCallbackKHR", h_noop},
    {"glDebugMessageControl", h_noop}, {"glDebugMessageControlKHR", h_noop},
};

// Called by eglGetProcAddress (real mode). Returns 0 when the name isn't a GL
// entrypoint we forward (caller falls back).
gaddr gl_fwd_proc(const char* name) {
    static bool inited = false;
    if (!inited) {
        inited = true;
        g_libgl = dlopen("libGLESv3.so", RTLD_NOW);
        if (!g_libgl) g_libgl = dlopen("libGLESv2.so", RTLD_NOW);
        for (auto& f : kGL) g_byname[f.name] = &f;
        if (getenv("WST_GLTRACE")) g_trace_left = atoi(getenv("WST_GLTRACE"));
    }
    // Thunks are keyed "gl:<name>" so they never alias a hand-written handler
    // registered under the bare name (gfx.cpp's headless/selftest subset).
    std::string key = std::string("gl:") + name;
    for (auto& s : kSpecial)
        if (!strcmp(s.name, name)) return make_thunk(key.c_str(), s.fn);
    auto it = g_byname.find(name);
    if (it == g_byname.end()) return 0;
    GLFn* f = it->second;
    if (!f->host) f->host = host_gl(name);
    if (!f->host) { logf("[gl] host lacks %s -> NULL", name); return 0; }
    return make_thunk(key.c_str(), h_glfwd);
}

void gl_set_trace(int n) { g_trace_left = n; }

}  // namespace wst
