// The libc / syscall / pthread / math / stdio surface libil2cpp imports.
// Everything operates on flat guest memory and forwards to the host where it
// can (real files, real pthread objects, host libm).
#include <map>
#include "cpu.h"
#include "thunks_ctx.h"
#include "elf.h"
#include "guest.h"

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <cmath>
#include <pthread.h>
#include <sched.h>
#include <semaphore.h>
#include <setjmp.h>
#include <stdarg.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/file.h>
#include <sys/sendfile.h>
#include <sys/socket.h>
#include <netdb.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>
#include <sys/select.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <sys/syscall.h>
#include <string>
#include <unordered_map>
#include <vector>

#include "dynarmic/interface/A32/a32.h"

namespace wst {

#define DEF(name) static void h_##name(Ctx& c)
static inline double darg(Ctx& c, int i) { u64 b = c.arg64(i); double d; memcpy(&d, &b, 8); return d; }
static inline void dret(Ctx& c, double d) { u64 b; memcpy(&b, &d, 8); c.ret64(b); }
static inline float farg(Ctx& c, int i) { u32 b = c.arg(i); float f; memcpy(&f, &b, 4); return f; }
static inline void fret(Ctx& c, float f) { u32 b; memcpy(&b, &f, 4); c.ret(b); }
static void set_errno() { wr32(guest_errno_addr(), u32(errno)); }

// ---------------- guest-varargs printf ----------------
// Reads conversions out of the AAPCS arg stream starting at slot `first`.
struct VA {
    Ctx& c; int i;
    u32 u() { return c.arg(i++); }
    u64 u64v() { i = (i + 1) & ~1; u64 v = c.arg64(i); i += 2; return v; }
    double dbl() { i = (i + 1) & ~1; u64 b = c.arg64(i); i += 2; double d; memcpy(&d, &b, 8); return d; }
};

static std::string gformat(const char* fmt, VA& va) {
    std::string out;
    char spec[64];
    for (const char* p = fmt; *p; ++p) {
        if (*p != '%') { out += *p; continue; }
        const char* start = p++;
        if (*p == '%') { out += '%'; continue; }
        bool islong = false, islonglong = false;
        while (*p && !strchr("diouxXeEfFgGaAcspn%", *p)) {
            if (*p == 'l') { if (islong) islonglong = true; islong = true; }
            ++p;
        }
        char conv = *p;
        size_t n = size_t(p - start + 1);
        if (n >= sizeof spec) n = sizeof spec - 1;
        memcpy(spec, start, n); spec[n] = 0;
        char buf[512];
        switch (conv) {
            case 'd': case 'i': case 'o': case 'u': case 'x': case 'X':
                if (islonglong) snprintf(buf, sizeof buf, spec, (long long)va.u64v());
                else { // normalise %l... to plain int width (guest long == 32-bit)
                    std::string s2(spec); size_t lp;
                    while ((lp = s2.find('l')) != std::string::npos) s2.erase(lp, 1);
                    snprintf(buf, sizeof buf, s2.c_str(), va.u());
                }
                out += buf; break;
            case 'e': case 'E': case 'f': case 'F': case 'g': case 'G': case 'a': case 'A':
                snprintf(buf, sizeof buf, spec, va.dbl()); out += buf; break;
            case 'c':
                snprintf(buf, sizeof buf, spec, int(va.u())); out += buf; break;
            case 'p':
                snprintf(buf, sizeof buf, "0x%x", va.u()); out += buf; break;
            case 's': {
                gaddr sp = va.u();
                const char* s = sp ? HS(sp) : "(null)";
                if (!strcmp(spec, "%s")) { out += s; break; }
                snprintf(buf, sizeof buf, spec, s); out += buf; break;
            }
            default: out += spec; break;
        }
    }
    return out;
}

// Same over an ARM va_list (a guest pointer to the packed argument words).
static std::string gvformat(const char* fmt, gaddr ap) {
    std::string out; char spec[64], buf[512];
    gaddr q = ap;
    auto nextw = [&]() { u32 v = rd32(q); q += 4; return v; };
    for (const char* p = fmt; *p; ++p) {
        if (*p != '%') { out += *p; continue; }
        const char* s0 = p++;
        if (*p == '%') { out += '%'; continue; }
        bool ll = false, l = false;
        while (*p && !strchr("diouxXeEfFgGaAcspn%", *p)) { if (*p == 'l') { if (l) ll = true; l = true; } ++p; }
        char cv = *p; size_t ln = size_t(p - s0 + 1); if (ln >= sizeof spec) ln = sizeof spec - 1;
        memcpy(spec, s0, ln); spec[ln] = 0;
        if (strchr("diuoxX", cv)) {
            if (ll) { q = (q + 7) & ~7u; u64 v = rd64(q); q += 8; snprintf(buf, sizeof buf, spec, (long long)v); }
            else { std::string s2(spec); size_t lp; while ((lp = s2.find('l')) != std::string::npos) s2.erase(lp, 1);
                   snprintf(buf, sizeof buf, s2.c_str(), nextw()); }
            out += buf;
        } else if (strchr("efgEFGaA", cv)) {
            q = (q + 7) & ~7u; u64 b = rd64(q); q += 8; double d; memcpy(&d, &b, 8);
            snprintf(buf, sizeof buf, spec, d); out += buf;
        } else if (cv == 'c') { snprintf(buf, sizeof buf, spec, int(nextw())); out += buf; }
        else if (cv == 'p') { snprintf(buf, sizeof buf, "0x%x", nextw()); out += buf; }
        else if (cv == 's') { gaddr sp = nextw(); const char* sv = sp ? HS(sp) : "(null)";
                              if (!strcmp(spec, "%s")) out += sv; else { snprintf(buf, sizeof buf, spec, sv); out += buf; } }
        else out += spec;
    }
    return out;
}

// ---------------- stdio ----------------
static void fs_fail(const char* what, const char* path) {
    static int n = 0;
    if (n++ < 200) logf("[fs] %s(%s) failed: %s", what, path ? path : "?", strerror(errno));
}

static std::mutex g_io_mu;
static std::unordered_map<gaddr, FILE*> g_files;   // guest token -> host FILE*
static gaddr g_sF = 0;                              // base of the __sF blob

static FILE* host_file(gaddr tok) {
    // Any pointer into the __sF blob is one of std{in,out,err}; route diagnostics
    // to stderr (we can't tell bionic's exact FILE stride, and it only matters
    // for log-style writes during init).
    if (g_sF && tok >= g_sF && tok < g_sF + 0x1000)
        return (tok == g_sF) ? stdin : stderr;
    std::lock_guard<std::mutex> lk(g_io_mu);
    auto it = g_files.find(tok);
    return it == g_files.end() ? nullptr : it->second;
}
static gaddr make_file_token(FILE* f) {
    if (!f) return 0;
    gaddr tok = gmalloc(8);
    std::lock_guard<std::mutex> lk(g_io_mu);
    g_files[tok] = f;
    return tok;
}

DEF(fopen)  { FILE* f = fopen(HS(c.argp(0)), HS(c.argp(1))); if (!f) { set_errno(); if (errno != ENOENT) fs_fail("fopen", HS(c.argp(0))); } c.retp(make_file_token(f)); }
DEF(fdopen) { FILE* f = fdopen(int(c.arg(0)), HS(c.argp(1))); c.retp(make_file_token(f)); }
DEF(fclose) { FILE* f = host_file(c.argp(0)); int r = f ? fclose(f) : -1;
              { std::lock_guard<std::mutex> lk(g_io_mu); g_files.erase(c.argp(0)); } if (c.argp(0)) gfree(c.argp(0)); c.ret(u32(r)); }
DEF(fread)  { FILE* f = host_file(c.argp(3)); c.ret(f ? u32(fread(H(c.argp(0)), c.arg(1), c.arg(2), f)) : 0); }
DEF(fwrite) { FILE* f = host_file(c.argp(3)); c.ret(f ? u32(fwrite(H(c.argp(0)), c.arg(1), c.arg(2), f)) : 0); }
DEF(fflush) { FILE* f = c.argp(0) ? host_file(c.argp(0)) : nullptr; c.ret(u32(f ? fflush(f) : 0)); }
DEF(fputc)  { FILE* f = host_file(c.argp(1)); c.ret(u32(f ? fputc(int(c.arg(0)), f) : -1)); }
DEF(fputs)  { FILE* f = host_file(c.argp(1)); c.ret(u32(f ? fputs(HS(c.argp(0)), f) : -1)); }
DEF(setvbuf){ c.ret(0); }
DEF(popen)  { FILE* f = popen(HS(c.argp(0)), HS(c.argp(1))); c.retp(make_file_token(f)); }
DEF(pclose) { FILE* f = host_file(c.argp(0)); c.ret(u32(f ? pclose(f) : -1)); }

DEF(snprintf) { VA va{c, 3}; std::string s = gformat(HS(c.argp(2)), va);
                char* d = reinterpret_cast<char*>(H(c.argp(0))); u32 n = c.arg(1);
                if (n) { u32 k = u32(s.size()) < n - 1 ? u32(s.size()) : n - 1; memcpy(d, s.data(), k); d[k] = 0; }
                c.ret(u32(s.size())); }
DEF(sprintf)  { VA va{c, 2}; std::string s = gformat(HS(c.argp(1)), va);
                memcpy(H(c.argp(0)), s.c_str(), s.size() + 1); c.ret(u32(s.size())); }
DEF(vsnprintf){ // (buf,n,fmt,va_list): va_list is a guest pointer to a packed arg area.
                gaddr ap = c.argp(3);
                const char* fmt = HS(c.argp(2));
                std::string out; char spec[64], buf[512];
                gaddr q = ap;
                auto nextw = [&](){ u32 v = rd32(q); q += 4; return v; };
                for (const char* p = fmt; *p; ++p) {
                    if (*p != '%') { out += *p; continue; }
                    const char* s0 = p++;
                    if (*p == '%') { out += '%'; continue; }
                    bool ll = false, l = false;
                    while (*p && !strchr("diouxXeEfFgGaAcspn%", *p)) { if (*p=='l'){ if(l) ll=true; l=true;} ++p; }
                    char cv = *p; size_t ln = size_t(p - s0 + 1); if (ln>=sizeof spec) ln=sizeof spec-1;
                    memcpy(spec,s0,ln); spec[ln]=0;
                    if (cv=='d'||cv=='i'||cv=='u'||cv=='o'||cv=='x'||cv=='X') {
                        if (ll) { q=(q+7)&~7u; u64 v=rd64(q); q+=8; snprintf(buf,sizeof buf,spec,(long long)v);}
                        else { std::string s2(spec); size_t lp; while((lp=s2.find('l'))!=std::string::npos) s2.erase(lp,1); snprintf(buf,sizeof buf,s2.c_str(),nextw()); }
                        out+=buf;
                    } else if (cv=='e'||cv=='f'||cv=='g'||cv=='E'||cv=='F'||cv=='G'||cv=='a'||cv=='A') {
                        q=(q+7)&~7u; u64 b=rd64(q); q+=8; double d; memcpy(&d,&b,8); snprintf(buf,sizeof buf,spec,d); out+=buf;
                    } else if (cv=='c') { snprintf(buf,sizeof buf,spec,int(nextw())); out+=buf; }
                    else if (cv=='p') { snprintf(buf,sizeof buf,"0x%x",nextw()); out+=buf; }
                    else if (cv=='s') { gaddr sp=nextw(); snprintf(buf,sizeof buf,spec, sp?HS(sp):"(null)"); out+=buf; }
                    else out+=spec;
                }
                char* d = reinterpret_cast<char*>(H(c.argp(0))); u32 n=c.arg(1);
                if (n){ u32 k=u32(out.size())<n-1?u32(out.size()):n-1; memcpy(d,out.data(),k); d[k]=0; }
                c.ret(u32(out.size())); }
DEF(vsprintf){ gaddr ap=c.argp(2); const char* fmt=HS(c.argp(1)); std::string out;
               char spec[64],buf[512]; gaddr q=ap;
               auto nextw=[&](){u32 v=rd32(q);q+=4;return v;};
               for(const char* p=fmt;*p;++p){ if(*p!='%'){out+=*p;continue;} const char* s0=p++;
                 if(*p=='%'){out+='%';continue;} bool ll=false,l=false;
                 while(*p&&!strchr("diouxXeEfFgGaAcspn%",*p)){if(*p=='l'){if(l)ll=true;l=true;}++p;}
                 char cv=*p; size_t ln=size_t(p-s0+1); if(ln>=sizeof spec)ln=sizeof spec-1; memcpy(spec,s0,ln); spec[ln]=0;
                 if(cv=='d'||cv=='i'||cv=='u'||cv=='o'||cv=='x'||cv=='X'){ if(ll){q=(q+7)&~7u;u64 v=rd64(q);q+=8;snprintf(buf,sizeof buf,spec,(long long)v);} else {std::string s2(spec);size_t lp;while((lp=s2.find('l'))!=std::string::npos)s2.erase(lp,1);snprintf(buf,sizeof buf,s2.c_str(),nextw());} out+=buf; }
                 else if(cv=='f'||cv=='g'||cv=='e'||cv=='E'||cv=='F'||cv=='G'){q=(q+7)&~7u;u64 b=rd64(q);q+=8;double d;memcpy(&d,&b,8);snprintf(buf,sizeof buf,spec,d);out+=buf;}
                 else if(cv=='c'){snprintf(buf,sizeof buf,spec,int(nextw()));out+=buf;}
                 else if(cv=='p'){snprintf(buf,sizeof buf,"0x%x",nextw());out+=buf;}
                 else if(cv=='s'){gaddr sp=nextw();snprintf(buf,sizeof buf,spec,sp?HS(sp):"(null)");out+=buf;}
                 else out+=spec; }
               memcpy(H(c.argp(0)),out.c_str(),out.size()+1); c.ret(u32(out.size())); }

// ---------------- raw file / syscalls ----------------
// ARM32 vs arm64 open() flags differ in four bits (the rest match).
static int host_oflags(u32 g) {
    int h = int(g & ~(0040000u | 0100000u | 0200000u | 0400000u));
    if (g & 0040000u) h |= O_DIRECTORY;
    if (g & 0100000u) h |= O_NOFOLLOW;
    if (g & 0200000u) h |= O_DIRECT;
    return h;   // 0400000 = O_LARGEFILE: implicit on arm64
}
DEF(open)   { int fd = open(HS(c.argp(0)), host_oflags(c.arg(1)), mode_t(c.arg(2))); if (fd<0) { set_errno(); if (errno != ENOENT) fs_fail("open", HS(c.argp(0))); } c.ret(u32(fd)); }
DEF(close)  { c.ret(u32(close(int(c.arg(0))))); }
DEF(read)   { ssize_t r = read(int(c.arg(0)), H(c.argp(1)), c.arg(2)); if(r<0) set_errno(); c.ret(u32(r)); }
DEF(write)  { ssize_t r = write(int(c.arg(0)), H(c.argp(1)), c.arg(2)); if(r<0) set_errno(); c.ret(u32(r)); }
DEF(lseek)  { off_t r = lseek(int(c.arg(0)), off_t(s32(c.arg(1))), int(c.arg(2))); if (r < 0) set_errno(); c.ret(u32(r)); }
DEF(ftruncate){ c.ret(u32(ftruncate(int(c.arg(0)), off_t(c.arg(1))))); }
DEF(fsync)  { c.ret(u32(fsync(int(c.arg(0))))); }
DEF(access) { int r = access(HS(c.argp(0)), int(c.arg(1))); if (r) set_errno(); c.ret(u32(r)); }
DEF(unlink) { c.ret(u32(unlink(HS(c.argp(0))))); }
DEF(rename) { c.ret(u32(rename(HS(c.argp(0)), HS(c.argp(1))))); }
DEF(mkdir)  { int r = mkdir(HS(c.argp(0)), mode_t(c.arg(1))); if (r) { set_errno(); if (errno != EEXIST) fs_fail("mkdir", HS(c.argp(0))); } c.ret(u32(r)); }
DEF(rmdir)  { c.ret(u32(rmdir(HS(c.argp(0))))); }
DEF(chdir)  { c.ret(u32(chdir(HS(c.argp(0))))); }
DEF(chmod)  { c.ret(u32(chmod(HS(c.argp(0)), mode_t(c.arg(1))))); }
DEF(getcwd) { char* r = getcwd(reinterpret_cast<char*>(H(c.argp(0))), c.arg(1)); c.retp(r ? c.argp(0) : 0); }
DEF(readlink){ ssize_t r = readlink(HS(c.argp(0)), reinterpret_cast<char*>(H(c.argp(1))), c.arg(2)); c.ret(u32(r)); }
DEF(dup2)   { c.ret(u32(dup2(int(c.arg(0)), int(c.arg(1))))); }
DEF(pipe)   { int fds[2]; int r = pipe(fds); if(!r){ wr32(c.argp(0),fds[0]); wr32(c.argp(0)+4,fds[1]); } c.ret(u32(r)); }
DEF(isatty) { c.ret(u32(isatty(int(c.arg(0))))); }
DEF(fcntl)  { c.ret(u32(fcntl(int(c.arg(0)), int(c.arg(1)), c.arg(2)))); }
DEF(ioctl)  { c.ret(u32(ioctl(int(c.arg(0)), c.arg(1), H(c.argp(2))))); }

// stat: bionic struct stat differs from host; fill the fields il2cpp reads
// (st_mode, st_size, st_mtime). We write a conservative bionic-arm layout.
static void write_bstat(gaddr dst, struct stat& st) {
    memset(H(dst), 0, 0x60);
    wr32(dst + 0x10, u32(st.st_mode));   // st_mode  (bionic arm: off 16)
    wr64(dst + 0x30, u64(st.st_size));   // st_size  (off 48)
    wr32(dst + 0x48, u32(st.st_mtime));  // st_mtime (off 72)
}
DEF(stat)   { struct stat st; int r = stat(HS(c.argp(0)), &st); if(!r) write_bstat(c.argp(1), st); else set_errno(); c.ret(u32(r)); }
DEF(lstat)  { struct stat st; int r = lstat(HS(c.argp(0)), &st); if(!r) write_bstat(c.argp(1), st); c.ret(u32(r)); }
DEF(fstat)  { struct stat st; int r = fstat(int(c.arg(0)), &st); if(!r) write_bstat(c.argp(1), st); c.ret(u32(r)); }

// opendir/readdir: host DIR* behind a guest token; readdir fills a guest dirent.
static std::unordered_map<gaddr, DIR*> g_dirs;
DEF(opendir){ DIR* d = opendir(HS(c.argp(0))); if(!d){ set_errno(); c.retp(0); return; } gaddr t=gmalloc(8); g_dirs[t]=d; c.retp(t); }
DEF(closedir){ auto it=g_dirs.find(c.argp(0)); int r=-1; if(it!=g_dirs.end()){ r=closedir(it->second); g_dirs.erase(it);} if(c.argp(0)) gfree(c.argp(0)); c.ret(u32(r)); }
DEF(readdir){ auto it=g_dirs.find(c.argp(0)); if(it==g_dirs.end()){ c.retp(0); return; }
              struct dirent* e = readdir(it->second); if(!e){ c.retp(0); return; }
              static thread_local gaddr buf=0; if(!buf) buf=gmalloc(0x120);
              memset(H(buf),0,0x120); wr64(buf, e->d_ino); wr32(buf+0x10, 0);
              char* nm = reinterpret_cast<char*>(H(buf+0x13)); strncpy(nm, e->d_name, 255);  // bionic d_name off 19
              c.retp(buf); }

DEF(mmap)   { gaddr want_at=c.argp(0); gaddr len=c.arg(1); int flags=int(c.arg(3)); int fd=int(c.arg(4)); u32 off=c.arg(5);
              gaddr g = 0;
              if ((flags & MAP_FIXED) && want_at && len) {
                  // MAP_FIXED: exactly there. Boehm GC returns heap pages this way
                  // (mmap(addr, PROT_NONE, MAP_FIXED)) and aborts on any other address.
                  // A range we already handed out is replaced by fresh zero pages in place
                  // (which also gives the memory back to the host); a free range is claimed.
                  if (va_is_mapped(want_at) || va_alloc_at(want_at, len)) {
                      ::mmap(H(want_at), (len + 0xFFF) & ~0xFFFu, PROT_READ | PROT_WRITE,
                             MAP_PRIVATE | MAP_FIXED | MAP_ANONYMOUS, -1, 0);
                      g = want_at;
                  } else { wr32(guest_errno_addr(), ENOMEM); c.retp(0xFFFFFFFFu); return; }
              } else {
                  g = va_alloc(len);
              }
              if (!g) { c.retp(0xFFFFFFFFu); return; }
              if (!(flags & MAP_ANONYMOUS) && fd >= 0) {
                  // Map the file straight into guest space (private, writable copy-on-write).
                  void* want = H(g);
                  void* r = ::mmap(want, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_FIXED, fd, off_t(off));
                  if (r != want) {   // fall back to a copy
                      ssize_t n = pread(fd, want, len, off_t(off)); (void)n;
                  }
              }
              c.retp(g); }
DEF(munmap) { gaddr a = c.argp(0); u32 len = c.arg(1);
              // Put plain zeroed anonymous memory back before returning the range to the allocator.
              if (a && len) ::mmap(H(a), len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_FIXED | MAP_ANONYMOUS, -1, 0);
              va_free(a, len); c.ret(0); }
DEF(mprotect){ c.ret(0); }   // JIT does not enforce guest page perms

// ---------------- env / misc ----------------
static std::unordered_map<std::string, gaddr> g_env;
// Guest environment seeds. WST_GUEST_ENV="K=V;K2=V2" (host env) adds more.
static void env_seed() {
    static bool done = false; if (done) return; done = true;
    if (const char* e = getenv("WST_GUEST_ENV")) {
        std::string all(e); size_t p = 0;
        while (p < all.size()) {
            size_t q = all.find(';', p); if (q == std::string::npos) q = all.size();
            std::string kv = all.substr(p, q - p); size_t eq = kv.find('=');
            if (eq != std::string::npos) { g_env[kv.substr(0, eq)] = gstrdup(kv.substr(eq + 1).c_str()); logf("[sys] guest env %s", kv.c_str()); }
            p = q + 1;
        }
    }
}
DEF(getenv) { env_seed(); auto it = g_env.find(HS(c.argp(0))); c.retp(it==g_env.end()?0:it->second); }
DEF(setenv) { g_env[HS(c.argp(0))] = gstrdup(HS(c.argp(1))); c.ret(0); }
DEF(unsetenv){ g_env.erase(HS(c.argp(0))); c.ret(0); }
DEF(sysconf){ long v=sysconf(int(c.arg(0))); if(v<0) v = int(c.arg(0))==0x27/*_SC_PAGESIZE?*/?4096:1; c.ret(u32(v)); }
DEF(uname)  {   // struct utsname = 6 fields x 65 bytes (sysname, nodename, release, version, machine, domainname)
    char* u = reinterpret_cast<char*>(H(c.argp(0)));
    memset(u, 0, 65 * 6);
    struct utsname h; ::uname(&h);
    strncpy(u + 0 * 65, "Linux", 64); strncpy(u + 1 * 65, "localhost", 64);
    strncpy(u + 2 * 65, h.release, 64); strncpy(u + 3 * 65, h.version, 64);
    strncpy(u + 4 * 65, "armv7l", 64);
    c.ret(0); }
DEF(exit)   {
    auto& R = c.jit()->Regs();
    logf("guest exit(%u) from %s", c.arg(0), describe_addr(R[14] & ~1u).c_str());
    int n = 0;
    for (u32 a = R[13]; a < R[13] + 0x2000 && n < 16 && va_is_mapped(a); a += 4)
        if (is_guest_code(rd32(a) & ~1u)) { logf("  stk %s", describe_addr(rd32(a) & ~1u).c_str()); ++n; }
    fatal("guest exit(%u)", c.arg(0)); }
DEF(atoi)   { c.ret(u32(atoi(HS(c.argp(0))))); }
DEF(atol)   { c.ret(u32(atol(HS(c.argp(0))))); }
DEF(strtoul){ char* e=nullptr; unsigned long v=strtoul(HS(c.argp(0)),&e,int(c.arg(2))); if(c.argp(1)) wr32(c.argp(1),G(e)); c.ret(u32(v)); }
DEF(strtod) { char* e=nullptr; double v=strtod(HS(c.argp(0)),&e); if(c.argp(1)) wr32(c.argp(1),G(e)); dret(c,v); }
DEF(strerror){ static thread_local gaddr b=0; if(!b) b=gmalloc(256); strncpy(reinterpret_cast<char*>(H(b)), strerror(int(c.arg(0))),255); c.retp(b); }
DEF(strcoll){ c.ret(u32(strcmp(HS(c.argp(0)),HS(c.argp(1))))); }
DEF(strxfrm){ const char* s=HS(c.argp(1)); u32 n=c.arg(2); u32 l=u32(strlen(s)); if(n){ u32 k=l<n-1?l:n-1; memcpy(H(c.argp(0)),s,k); reinterpret_cast<char*>(H(c.argp(0)))[k]=0;} c.ret(l); }
DEF(strlcpy){ const char* s=HS(c.argp(1)); u32 n=c.arg(2); u32 l=u32(strlen(s)); if(n){ u32 k=l<n-1?l:n-1; memcpy(H(c.argp(0)),s,k); reinterpret_cast<char*>(H(c.argp(0)))[k]=0;} c.ret(l); }
DEF(setlocale){ c.retp(0); }
DEF(prctl)  {   // PR_SET_NAME names the calling (host) thread
    if (c.arg(0) == 15 && c.argp(1)) { char n[16]; strncpy(n, HS(c.argp(1)), 15); n[15] = 0; pthread_setname_np(pthread_self(), n); }
    c.ret(0); }
// guest signals: signals.cpp
int sig_action(int sig, gaddr act, gaddr oldact);
gaddr sig_signal(int sig, gaddr h);
int sig_procmask(int how, gaddr set, gaddr oldset);
void sig_suspend(gaddr maskp);
void deliver_as_self(GuestThread* o);
DEF(raise)  { int r = sig_kill(cur_thread()->self, 0, int(c.arg(0))); if (!r) deliver_as_self(sig_owner(cur_thread())); c.ret(r ? u32(-1) : 0); }
DEF(tkill)  { int r = sig_kill(0, c.arg(0), int(c.arg(1))); if (r) { wr32(guest_errno_addr(), u32(r)); c.ret(u32(-1)); } else c.ret(0); }
DEF(kill)   { c.ret(0); }
DEF(sigaction){ int r = sig_action(int(c.arg(0)), c.argp(1), c.argp(2)); if (r) { wr32(guest_errno_addr(), u32(r)); c.ret(u32(-1)); } else c.ret(0); }
DEF(bsd_signal){ c.retp(sig_signal(int(c.arg(0)), c.argp(1))); }
DEF(sigsuspend){ sig_suspend(c.argp(0)); wr32(guest_errno_addr(), EINTR); c.ret(u32(-1)); }
DEF(pthread_sigmask){ c.ret(u32(sig_procmask(int(c.arg(0)), c.argp(1), c.argp(2)))); }
DEF(__google_potentially_blocking_region_begin){ c.ret(0); }
DEF(__google_potentially_blocking_region_end){ c.ret(0); }
DEF(__pthread_cleanup_push){ c.ret(0); }
DEF(__pthread_cleanup_pop){ c.ret(0); }

// ---------------- time ----------------
DEF(time)   { time_t t=time(nullptr); if(c.argp(0)) wr32(c.argp(0),u32(t)); c.ret(u32(t)); }
DEF(clock)  { c.ret(u32(clock())); }
DEF(difftime){ dret(c, difftime(time_t(c.arg(0)), time_t(c.arg(1)))); }
DEF(clock_getres){ struct timespec ts; int r=clock_getres(int(c.arg(0)),&ts); if(c.argp(1)){wr32(c.argp(1),u32(ts.tv_sec)); wr32(c.argp(1)+4,u32(ts.tv_nsec));} c.ret(u32(r)); }
DEF(nanosleep){ struct timespec req{ time_t(rd32(c.argp(0))), long(rd32(c.argp(0)+4)) }; int r=nanosleep(&req,nullptr); c.ret(u32(r)); }
DEF(usleep) { c.ret(u32(usleep(c.arg(0)))); }
DEF(gmtime) { time_t t=rd32(c.argp(0)); struct tm* r=gmtime(&t); static thread_local gaddr b=0; if(!b)b=gmalloc(64); memset(H(b),0,64);
              gaddr d=b; wr32(d,r->tm_sec);wr32(d+4,r->tm_min);wr32(d+8,r->tm_hour);wr32(d+12,r->tm_mday);wr32(d+16,r->tm_mon);wr32(d+20,r->tm_year);wr32(d+24,r->tm_wday);wr32(d+28,r->tm_yday);wr32(d+32,r->tm_isdst); c.retp(b); }
DEF(localtime){ time_t t=rd32(c.argp(0)); struct tm* r=localtime(&t); static thread_local gaddr b=0; if(!b)b=gmalloc(64); memset(H(b),0,64);
              gaddr d=b; wr32(d,r->tm_sec);wr32(d+4,r->tm_min);wr32(d+8,r->tm_hour);wr32(d+12,r->tm_mday);wr32(d+16,r->tm_mon);wr32(d+20,r->tm_year);wr32(d+24,r->tm_wday);wr32(d+28,r->tm_yday);wr32(d+32,r->tm_isdst); c.retp(b); }
DEF(mktime) { gaddr d=c.argp(0); struct tm tmv{}; tmv.tm_sec=rd32(d);tmv.tm_min=rd32(d+4);tmv.tm_hour=rd32(d+8);tmv.tm_mday=rd32(d+12);tmv.tm_mon=rd32(d+16);tmv.tm_year=rd32(d+20);tmv.tm_isdst=rd32(d+32); c.ret(u32(mktime(&tmv))); }
DEF(strftime){ gaddr d=c.argp(3); struct tm tmv{}; tmv.tm_sec=rd32(d);tmv.tm_min=rd32(d+4);tmv.tm_hour=rd32(d+8);tmv.tm_mday=rd32(d+12);tmv.tm_mon=rd32(d+16);tmv.tm_year=rd32(d+20);tmv.tm_wday=rd32(d+24);tmv.tm_yday=rd32(d+28);tmv.tm_isdst=rd32(d+32);
              size_t r=strftime(reinterpret_cast<char*>(H(c.argp(0))), c.arg(1), HS(c.argp(2)), &tmv); c.ret(u32(r)); }

// ---------------- math (softfp: double in r0:r1, float in r0) ----------------
#define M1(name)  DEF(name){ dret(c, ::name(darg(c,0))); }
#define M1F(name) DEF(name##f){ fret(c, ::name##f(farg(c,0))); }
#define M2(name)  DEF(name){ dret(c, ::name(darg(c,0), darg(c,2))); }
M1(acos) M1(asin) M1(atan) M1(cos) M1(sin) M1(tan) M1(cosh) M1(sinh) M1(tanh)
M1(exp) M1(log) M1(log10) M1(ceil) M1(floor) M1(sqrt) M1(exp2)
M1F(acos) M1F(asin) M1F(atan) M1F(cos) M1F(sin) M1F(tan) M1F(exp) M1F(log) M1F(ceil) M1F(floor) M1F(sqrt) M1F(exp2)
M1(round) M1(trunc)
M1(fabs) M1(rint) M1(nearbyint) M1(log2) M1(cbrt) M1(expm1) M1(log1p) M1(asinh) M1(acosh) M1(atanh)
M2(hypot) M2(fmax) M2(fmin) M2(copysign)
M1F(rint) M1F(log2) M1F(cbrt) M1F(sinh) M1F(cosh) M1F(tanh)
DEF(fmaxf) { fret(c, ::fmaxf(farg(c,0), farg(c,1))); }
DEF(fminf) { fret(c, ::fminf(farg(c,0), farg(c,1))); }
DEF(copysignf) { fret(c, ::copysignf(farg(c,0), farg(c,1))); }
DEF(hypotf) { fret(c, ::hypotf(farg(c,0), farg(c,1))); }
DEF(ldexpf) { fret(c, ::ldexpf(farg(c,0), int(c.arg(1)))); }
DEF(scalbn) { dret(c, ::scalbn(darg(c,0), int(c.arg(2)))); }
DEF(lrint)  { c.ret(u32(s32(::lrint(darg(c,0))))); }
DEF(lrintf) { c.ret(u32(s32(::lrintf(farg(c,0))))); }
M2(atan2) M2(pow) M2(fmod)
DEF(atan2f){ fret(c, ::atan2f(farg(c,0), farg(c,1))); }
DEF(powf)  { fret(c, ::powf(farg(c,0), farg(c,1))); }
DEF(fmodf) { fret(c, ::fmodf(farg(c,0), farg(c,1))); }
DEF(modf)  { double ip; double r=::modf(darg(c,0), &ip); u64 b; memcpy(&b,&ip,8); wr64(c.argp(2), b); dret(c,r); }
DEF(isnan) { c.ret(std::isnan(darg(c,0)) ? 1u : 0u); }

// ---------------- wide char (minimal) ----------------
DEF(wcslen) { const u16* s=HP<u16>(c.argp(0)); u32 n=0; while(s[n]) ++n; c.ret(n); }
DEF(btowc)  { c.ret(c.arg(0)); }
DEF(wctob)  { c.ret(c.arg(0)); }
DEF(towlower){ c.ret(u32(towlower(c.arg(0)))); }
DEF(towupper){ c.ret(u32(towupper(c.arg(0)))); }
DEF(iswctype){ c.ret(0); }
DEF(wctype) { c.ret(0); }
DEF(wmemset){ u16* d=HP<u16>(c.argp(0)); u16 v=u16(c.arg(1)); u32 n=c.arg(2); for(u32 i=0;i<n;++i) d[i]=v; c.retp(c.argp(0)); }
DEF(wmemcpy){ memcpy(H(c.argp(0)),H(c.argp(1)),c.arg(2)*2); c.retp(c.argp(0)); }
DEF(wmemmove){ memmove(H(c.argp(0)),H(c.argp(1)),c.arg(2)*2); c.retp(c.argp(0)); }
DEF(wmemcmp){ c.ret(u32(memcmp(H(c.argp(0)),H(c.argp(1)),c.arg(2)*2))); }
DEF(wmemchr){ const u16* s=HP<u16>(c.argp(0)); u16 v=u16(c.arg(1)); u32 n=c.arg(2); for(u32 i=0;i<n;++i) if(s[i]==v){c.retp(c.argp(0)+i*2);return;} c.retp(0); }
DEF(wcscoll){ c.ret(0); }
DEF(wcsxfrm){ c.ret(0); }
DEF(wcsftime){ c.ret(0); }
DEF(wcrtomb){ c.ret(1); }
DEF(mbrtowc){ c.ret(1); }

// ---------------- dl ----------------
// dlopen/dlsym over our own loader. A guest module's handle is its load base;
// host libraries (GLES, EGL, libc, ...) and NULL/RTLD_DEFAULT share the "global"
// handle 1, whose dlsym resolves guest exports first, then our host thunks.
static constexpr gaddr kDlGlobal = 1;
Module* guest_load_library(const std::string& so);   // driver.cpp
gaddr gfx_proc_address(const char* name);   // gfx.cpp
static std::string base_name(const char* p) { const char* s = strrchr(p, '/'); return s ? s + 1 : p; }
static Module* module_by_handle(gaddr h) {
    for (const char* n : {"libil2cpp.so", "libunity.so", "libmain.so", "libNianticLabsPlugin.so", "libvrunity.so", "libpgpplugin.so"})
        if (Module* m = elf_find(n)) if (m->base == h) return m;
    return nullptr;
}
DEF(dlopen) {
    const char* path = c.argp(0) ? HS(c.argp(0)) : nullptr;
    if (!path) { c.retp(kDlGlobal); return; }
    std::string bn = base_name(path);
    if (bn.find(".so") == std::string::npos) bn = "lib" + bn + ".so";
    if (Module* m = elf_find(bn)) { logf("[dl] dlopen(%s) -> guest %s", path, bn.c_str()); c.retp(m->base); return; }
    if (Module* m = guest_load_library(bn)) { logf("[dl] dlopen(%s) -> loaded guest %s", path, bn.c_str()); c.retp(m->base); return; }
    logf("[dl] dlopen(%s) -> host/global", path);
    c.retp(kDlGlobal);
}
// 60 fps: the game sets Application.targetFrameRate = 30 (and vSync) through Unity's
// internal calls. libunity registers those with il2cpp_add_internal_call, which it gets
// from dlsym -- so it gets our wrapper, which swaps the two setters for ours.
static gaddr g_add_icall = 0, g_set_fps = 0, g_set_vsync = 0;
// 60 by default: Unity 5.3 falls back to its mobile default of 30 for a target above the
// display rate (1000 measured a flat 30.0). WST_FPS overrides.
static int target_fps() { const char* e = getenv("WST_FPS"); int v = e ? atoi(e) : 60; return v > 0 ? v : 60; }
DEF(wst_set_target_fps) {
    static int n = 0;
    if (n++ < 4) logf("[fps] game asked targetFrameRate=%d -> %d", int(c.arg(0)), target_fps());
    call_guest(g_set_fps, {u32(target_fps())});
    // the quality level's own vSyncCount (2 = every other vblank = 30 fps) never goes
    // through the setter, and Unity paces it itself off Choreographer vsync times
    if (g_set_vsync) call_guest(g_set_vsync, {0});
    c.ret(0); }
DEF(wst_set_vsync) {
    static int n = 0;
    if (n++ < 4) logf("[fps] game asked vSyncCount=%d -> 0", int(c.arg(0)));
    call_guest(g_set_vsync, {0}); c.ret(0); }
DEF(wst_add_icall) {
    const char* n = c.argp(0) ? HS(c.argp(0)) : "";
    u32 fn = c.arg(1);
    if (!strcmp(n, "UnityEngine.Application::set_targetFrameRate")) { g_set_fps = fn; fn = make_thunk("wst_set_target_fps", h_wst_set_target_fps); }
    else if (!strcmp(n, "UnityEngine.QualitySettings::set_vSyncCount")) { g_set_vsync = fn; fn = make_thunk("wst_set_vsync", h_wst_set_vsync); }
    call_guest(g_add_icall, {c.argp(0), fn});
    if (fn != c.arg(1)) logf("[fps] icall %s wrapped", n);
    c.ret(0);
}
DEF(dlsym) {
    gaddr h = c.argp(0);
    const char* name = HS(c.argp(1));
    gaddr v = 0;
    if (Module* m = module_by_handle(h)) {
        m->find(name, &v);
    } else {
        for (const char* n : {"libil2cpp.so", "libunity.so", "libmain.so", "libNianticLabsPlugin.so", "libvrunity.so", "libpgpplugin.so"})
            if (Module* m2 = elf_find(n)) if (m2->find(name, &v)) break;
        if (!v) v = gfx_proc_address(name);   // GL (forwarded) / EGL / other host thunks
        if (!v && have_handler(name)) v = thunk_for_import(name, false);
    }
    if (v && !strcmp(name, "il2cpp_add_internal_call")) { g_add_icall = v; v = make_thunk("wst_add_icall", h_wst_add_icall); }
    if (!v) logf("[dl] dlsym(%08x, %s) -> NULL", h, name);
    c.retp(v);
}
DEF(dlclose){ c.ret(0); }
// dladdr (0.71's il2cpp): which guest module holds an address. Dl_info is 4 words:
// dli_fname, dli_fbase, dli_sname, dli_saddr; no symbol lookup (sname/saddr = 0).
DEF(dladdr) {
    gaddr a = c.argp(0), info = c.argp(1);
    for (const char* n : {"libil2cpp.so", "libunity.so", "libmain.so", "libNianticLabsPlugin.so", "libvrunity.so", "libpgpplugin.so"})
        if (Module* m = elf_find(n)) if (a >= m->base && a - m->base < m->span) {
            static std::map<std::string, gaddr> names;
            gaddr& fn = names[n]; if (!fn) fn = gstrdup((std::string("/data/app/lib/") + n).c_str());
            if (info) { wr32(info, fn); wr32(info + 4, m->base); wr32(info + 8, 0); wr32(info + 12, 0); }
            c.ret(1); return;
        }
    c.ret(0);
}

// ---------------- pthread (real objects keyed by guest address) ----------------
// Guest mutexes are recursive-tolerant and owner-tracked so a condition wait can
// fully release a mutex held several times by the waiter and restore the count.
struct GMutex {
    std::mutex mu; std::condition_variable cv; int owner = 0; int count = 0;
    void lock() { int me = gettid(); std::unique_lock<std::mutex> l(mu);
                  if (owner == me) { ++count; return; }
                  cv.wait(l, [&] { return owner == 0; }); owner = me; count = 1; }
    bool try_lock() { int me = gettid(); std::lock_guard<std::mutex> l(mu);
                      if (owner == me) { ++count; return true; }
                      if (owner) return false; owner = me; count = 1; return true; }
    void unlock() { std::lock_guard<std::mutex> l(mu);
                    if (owner != gettid()) return;
                    if (--count <= 0) { owner = 0; count = 0; cv.notify_one(); } }
    int release_all() { std::lock_guard<std::mutex> l(mu); int n = count; owner = 0; count = 0; cv.notify_one(); return n; }
    void reacquire(int n) { int me = gettid(); std::unique_lock<std::mutex> l(mu);
                            cv.wait(l, [&] { return owner == 0; }); owner = me; count = n > 0 ? n : 1; }
};
struct GMutexWaitLock {   // BasicLockable view used by condition_variable_any
    GMutex* m; int saved = 0;
    void unlock() { saved = m->release_all(); }
    void lock() { m->reacquire(saved); }
};
static std::mutex g_pt_mu;
static std::unordered_map<gaddr, GMutex*> g_mutex;
static std::unordered_map<gaddr, std::condition_variable_any*> g_cond;
static std::unordered_map<gaddr, sem_t*> g_sem;

static GMutex* get_mutex(gaddr a) {
    std::lock_guard<std::mutex> lk(g_pt_mu);
    auto& m = g_mutex[a];
    if (!m) m = new GMutex();
    return m;
}
DEF(pthread_mutex_init)   { c.ret(0); }
DEF(pthread_mutex_destroy){ c.ret(0); }   // keep the object: a re-init at the same address reuses it
DEF(pthread_mutex_lock)   { get_mutex(c.argp(0))->lock(); c.ret(0); }
DEF(pthread_mutex_trylock){ c.ret(get_mutex(c.argp(0))->try_lock() ? 0 : 16); }
DEF(pthread_mutex_unlock) { get_mutex(c.argp(0))->unlock(); c.ret(0); }
DEF(pthread_mutexattr_init){ c.ret(0); }
DEF(pthread_mutexattr_destroy){ c.ret(0); }
DEF(pthread_mutexattr_settype){ c.ret(0); }

static std::condition_variable_any* get_cond(gaddr a) {
    std::lock_guard<std::mutex> lk(g_pt_mu);
    auto& cv = g_cond[a]; if(!cv) cv = new std::condition_variable_any(); return cv;
}
static int cond_wait_for(gaddr cond, gaddr mtx, std::chrono::nanoseconds d) {
    auto* cv = get_cond(cond); GMutexWaitLock wl{get_mutex(mtx)};
    if (d.count() <= 0) return 110;   // ETIMEDOUT
    return cv->wait_for(wl, d) == std::cv_status::timeout ? 110 : 0;
}
DEF(pthread_cond_init)   { c.ret(0); }
DEF(pthread_cond_destroy){ c.ret(0); }
DEF(pthread_cond_signal) { get_cond(c.argp(0))->notify_one(); c.ret(0); }
DEF(pthread_cond_broadcast){ get_cond(c.argp(0))->notify_all(); c.ret(0); }
DEF(pthread_cond_wait)   { auto* cv = get_cond(c.argp(0)); GMutexWaitLock wl{get_mutex(c.argp(1))}; cv->wait(wl); c.ret(0); }
DEF(pthread_cond_timedwait_relative_np){
    long sec = rd32(c.argp(2)), ns = rd32(c.argp(2) + 4);
    c.ret(u32(cond_wait_for(c.argp(0), c.argp(1), std::chrono::seconds(sec) + std::chrono::nanoseconds(ns)))); }

static sem_t* get_sem(gaddr a){ std::lock_guard<std::mutex> lk(g_pt_mu); auto& s=g_sem[a]; return s; }
DEF(sem_init){ std::lock_guard<std::mutex> lk(g_pt_mu); sem_t* s=new sem_t; sem_init(s,0,c.arg(2)); g_sem[c.argp(0)]=s; c.ret(0); }
DEF(sem_destroy){ std::lock_guard<std::mutex> lk(g_pt_mu); auto it=g_sem.find(c.argp(0)); if(it!=g_sem.end()){ sem_destroy(it->second); delete it->second; g_sem.erase(it);} c.ret(0); }
struct SemStat { std::atomic<u32> posts{0}, waits{0}, lost{0}; };
static std::unordered_map<gaddr, SemStat*> g_semstat;
static SemStat* semstat(gaddr a) { std::lock_guard<std::mutex> lk(g_pt_mu); auto& p = g_semstat[a]; if (!p) p = new SemStat(); return p; }
void sem_stats_dump() {
    std::string out;
    std::lock_guard<std::mutex> lk(g_pt_mu);
    for (auto& kv : g_semstat) {
        int v = -1; auto it = g_sem.find(kv.first); if (it != g_sem.end() && it->second) sem_getvalue(it->second, &v);
        char b[96]; snprintf(b, sizeof b, "%08x:p%u/w%u/lost%u/v%d ", kv.first, kv.second->posts.load(), kv.second->waits.load(), kv.second->lost.load(), v);
        out += b;
    }
    logf("[prof] sems: %s", out.c_str());
}
DEF(sem_post){ sem_t* s=get_sem(c.argp(0)); SemStat* st = semstat(c.argp(0)); st->posts++; if(s) sem_post(s); else st->lost++; c.ret(0); }
DEF(sem_wait){ sem_t* s=get_sem(c.argp(0)); semstat(c.argp(0))->waits++; if(s) while (sem_wait(s) != 0 && errno == EINTR) {} c.ret(0); }
DEF(sem_getvalue){ sem_t* s=get_sem(c.argp(0)); int v=0; if(s) sem_getvalue(s,&v); wr32(c.argp(1),u32(v)); c.ret(0); }

DEF(pthread_create){ gaddr th=c.argp(0), start=c.argp(2), arg=c.argp(3); gaddr handle=0;
    int r=spawn_guest_thread(start, arg, 1<<20, &handle); if(th) wr32(th, handle); c.ret(u32(r)); }
DEF(pthread_detach){ c.ret(0); }
DEF(pthread_join){ c.ret(0); }        // PoC: don't block on joins during init
DEF(pthread_attr_init){ c.ret(0); }
DEF(pthread_attr_destroy){ c.ret(0); }
DEF(pthread_attr_setdetachstate){ c.ret(0); }
DEF(pthread_attr_getdetachstate){ wr32(c.argp(1),0); c.ret(0); }
DEF(pthread_attr_setstacksize){ c.ret(0); }
DEF(pthread_attr_getstack){ GuestThread* gt=cur_thread(); wr32(c.argp(1),gt->stack_lo); wr32(c.argp(2),gt->stack_size); c.ret(0); }
DEF(pthread_getattr_np){ c.ret(0); }

// ---------------- setjmp / longjmp (within one call_guest frame) ----------------
// jmp_buf layout (ours): r4-r11, sp(r13), lr-as-resume-pc, cpsr.
DEF(setjmp) {
    auto* R = &c.jit()->Regs()[0];
    gaddr b = c.argp(0);
    for (int i = 4; i <= 11; ++i) wr32(b + (i - 4) * 4, R[i]);
    wr32(b + 32, R[13]);                 // sp
    wr32(b + 36, R[14]);                 // resume at return address
    wr32(b + 40, c.jit()->Cpsr());
    c.ret(0);
}
DEF(longjmp) {
    auto& R = c.jit()->Regs();
    gaddr b = c.argp(0); u32 val = c.arg(1); if (!val) val = 1;
    for (int i = 4; i <= 11; ++i) R[i] = rd32(b + (i - 4) * 4);
    R[13] = rd32(b + 32);
    u32 pc = rd32(b + 36);
    c.jit()->SetCpsr(rd32(b + 40));
    R[0] = val;
    R[15] = pc & ~1u;
    // returning from the SVC handler resumes at the restored PC
}

// ---------------- sockets: real host sockets ----------------
// sockaddr_in/in6, pollfd, fd_set and the SOL_SOCKET constants have the same layout and
// values on ARM32 and arm64, so most calls pass straight through; timeval (two longs)
// and the pointer-carrying structs (addrinfo, msghdr, hostent) are converted.
//
// Windstock: like the Android agent's redirect.js, names under Niantic's / Pokémon's
// domains resolve to 127.0.0.1, and plain-HTTP connects there on port 80 go to WsNet's
// relay (Java), which carries them over the pinned TLS link to the Windstock server.
static constexpr u16 kRelayPort = 18080;          // WsNet.RELAY_PORT
static bool ws_host(const char* n) {
    if (!n) return false;
    std::string h(n); for (char& ch : h) ch = char(tolower(ch));
    while (!h.empty() && h.back() == '.') h.pop_back();
    if (h == "bracky.playit.plus") return true;
    for (const char* d : {"nianticlabs.com", "pokemon.com", "zendesk.com"}) {
        std::string s(d);
        if (h == s || (h.size() > s.size() && h.compare(h.size() - s.size() - 1, s.size() + 1, "." + s) == 0)) return true;
    }
    return false;
}
static int g_net_logs = 0;
#define NETLOG(...) do { if (g_net_logs++ < 60) logf(__VA_ARGS__); } while (0)
static inline void sret(Ctx& c, long r) { if (r < 0) set_errno(); c.ret(u32(r)); }

DEF(socket)   { int fd = socket(int(c.arg(0)), int(c.arg(1)), int(c.arg(2)));
                { static int n = 0; if (n++ < 40) logf("[net] socket(%u,%u,%u) -> %d", c.arg(0), c.arg(1), c.arg(2), fd); }
                sret(c, fd); }
DEF(bind)     { sret(c, bind(int(c.arg(0)), (sockaddr*)H(c.argp(1)), socklen_t(c.arg(2)))); }
DEF(listen)   { sret(c, listen(int(c.arg(0)), int(c.arg(1)))); }
DEF(accept)   { sret(c, accept(int(c.arg(0)), c.argp(1) ? (sockaddr*)H(c.argp(1)) : nullptr, c.argp(2) ? (socklen_t*)H(c.argp(2)) : nullptr)); }
DEF(connect) {
    int fd = int(c.arg(0)); socklen_t len = socklen_t(c.arg(2));
    sockaddr_storage sa{}; memcpy(&sa, H(c.argp(1)), std::min<size_t>(len, sizeof sa));
    u8* b = (u8*)&sa; u16 fam = u16(b[0] | (b[1] << 8));
    const u8* ip = fam == AF_INET ? b + 4 : nullptr;
    static const u8 mapped[12] = {0,0,0,0,0,0,0,0,0,0,0xff,0xff};
    if (fam == AF_INET6 && memcmp(b + 8, mapped, 12) == 0) ip = b + 20;
    u16 port = u16((b[2] << 8) | b[3]);
    { static int dn = 0; if (dn++ < 40) logf("[net] connect fd=%d fam=%u %u.%u.%u.%u:%u rpc=%s", fd, fam,
        ip ? ip[0] : 0, ip ? ip[1] : 0, ip ? ip[2] : 0, ip ? ip[3] : 0, port, getenv("WST_RPC_HOST") ? getenv("WST_RPC_HOST") : "-"); }
    if (ip && ip[0] == 127 && ip[1] == 0 && ip[2] == 0 && ip[3] == 1 && port == 80) {
        b[2] = u8(kRelayPort >> 8); b[3] = u8(kRelayPort);
        NETLOG("[net] connect 127.0.0.1:80 -> relay :%u", kRelayPort);
    } else if (ip && ip[0] == 127 && ip[1] == 0 && ip[2] == 0 && ip[3] == 1 && port == 443) {
        // 0.71+: the Niantic plugin opens its own TLS socket for /plfe/rpc (0.35 went
        // through NiaNet in Java). Send it straight to the server WsNet names (WST_RPC_HOST).
        in_addr a{};
        if (const char* h = getenv("WST_RPC_HOST")) if (inet_pton(AF_INET, h, &a) == 1) {
            memcpy((u8*)ip, &a, 4);
            static int n = 0; if (n++ < 8) logf("[net] connect 127.0.0.1:443 -> %s:443", h);
        }
    }
    int r = connect(fd, (sockaddr*)&sa, len);
    if (r < 0 && errno != EINPROGRESS && ip) NETLOG("[net] connect %u.%u.%u.%u:%u failed: %s", ip[0], ip[1], ip[2], ip[3], port, strerror(errno));
    sret(c, r);
}
DEF(send)     { sret(c, send(int(c.arg(0)), H(c.argp(1)), c.arg(2), int(c.arg(3)))); }
DEF(recv)     { sret(c, recv(int(c.arg(0)), H(c.argp(1)), c.arg(2), int(c.arg(3)))); }
DEF(sendto)   { u32 to = c.arg(4), tl = c.arg(5);
                sret(c, sendto(int(c.arg(0)), H(c.argp(1)), c.arg(2), int(c.arg(3)), to ? (sockaddr*)H(to) : nullptr, socklen_t(tl))); }
DEF(recvfrom) { u32 fr = c.arg(4), fl = c.arg(5);
                sret(c, recvfrom(int(c.arg(0)), H(c.argp(1)), c.arg(2), int(c.arg(3)), fr ? (sockaddr*)H(fr) : nullptr, fl ? (socklen_t*)H(fl) : nullptr)); }
// struct msghdr (ARM32): name, namelen, iov, iovlen, control, controllen, flags -- 7 words
static ssize_t msg_io(Ctx& c, bool out) {
    gaddr m = c.argp(1);
    u32 niov = rd32(m + 12); gaddr giov = rd32(m + 8);
    std::vector<iovec> iov(niov);
    for (u32 i = 0; i < niov; ++i) { iov[i].iov_base = H(rd32(giov + i * 8)); iov[i].iov_len = rd32(giov + i * 8 + 4); }
    msghdr h{};
    h.msg_name = rd32(m) ? H(rd32(m)) : nullptr; h.msg_namelen = rd32(m + 4);
    h.msg_iov = iov.data(); h.msg_iovlen = niov;
    h.msg_control = nullptr; h.msg_controllen = 0;      // no ancillary data (cmsg layouts differ)
    ssize_t r = out ? sendmsg(int(c.arg(0)), &h, int(c.arg(2))) : recvmsg(int(c.arg(0)), &h, int(c.arg(2)));
    if (!out) { wr32(m + 4, h.msg_namelen); wr32(m + 20, 0); wr32(m + 24, u32(h.msg_flags)); }
    return r;
}
DEF(sendmsg)  { sret(c, msg_io(c, true)); }
DEF(recvmsg)  { sret(c, msg_io(c, false)); }
DEF(getsockname) { sret(c, getsockname(int(c.arg(0)), (sockaddr*)H(c.argp(1)), (socklen_t*)H(c.argp(2)))); }
DEF(getpeername) { sret(c, getpeername(int(c.arg(0)), (sockaddr*)H(c.argp(1)), (socklen_t*)H(c.argp(2)))); }
static bool is_timeo(int lvl, int opt) { return lvl == SOL_SOCKET && (opt == SO_RCVTIMEO || opt == SO_SNDTIMEO); }
DEF(setsockopt) {
    int fd = int(c.arg(0)), lvl = int(c.arg(1)), opt = int(c.arg(2)); gaddr v = c.argp(3); u32 len = c.arg(4);
    if (is_timeo(lvl, opt) && v) {
        timeval tv{ long(int32_t(rd32(v))), long(int32_t(rd32(v + 4))) };
        sret(c, setsockopt(fd, lvl, opt, &tv, sizeof tv)); return;
    }
    sret(c, setsockopt(fd, lvl, opt, v ? H(v) : nullptr, socklen_t(len)));
}
DEF(getsockopt) {
    int fd = int(c.arg(0)), lvl = int(c.arg(1)), opt = int(c.arg(2)); gaddr v = c.argp(3), lp = c.arg(4);
    if (is_timeo(lvl, opt) && v && lp) {
        timeval tv{}; socklen_t l = sizeof tv; int r = getsockopt(fd, lvl, opt, &tv, &l);
        if (r == 0) { wr32(v, u32(tv.tv_sec)); wr32(v + 4, u32(tv.tv_usec)); wr32(lp, 8); }
        sret(c, r); return;
    }
    sret(c, getsockopt(fd, lvl, opt, v ? H(v) : nullptr, lp ? (socklen_t*)H(lp) : nullptr));
}
DEF(shutdown) { sret(c, shutdown(int(c.arg(0)), int(c.arg(1)))); }
DEF(sendfile) { u32 off = c.argp(2); off_t o = off ? off_t(int32_t(rd32(off))) : 0;
                ssize_t r = sendfile(int(c.arg(0)), int(c.arg(1)), off ? &o : nullptr, c.arg(3)); if (off) wr32(off, u32(o)); sret(c, r); }

// getaddrinfo -> a guest addrinfo chain (bionic ARM32 order: flags, family, socktype,
// protocol, addrlen, canonname, addr, next = 32 bytes), each node one gmalloc block.
DEF(getaddrinfo) {
    const char* node = c.argp(0) ? HS(c.argp(0)) : nullptr;
    const char* serv = c.argp(1) ? HS(c.argp(1)) : nullptr;
    addrinfo hints{}, *hp = nullptr;
    if (c.argp(2)) { gaddr g = c.argp(2); hints.ai_flags = int(rd32(g)); hints.ai_family = int(rd32(g + 4));
                     hints.ai_socktype = int(rd32(g + 8)); hints.ai_protocol = int(rd32(g + 12)); hp = &hints; }
    std::string name = node ? node : "";
    // AI_NUMERICHOST asks "is this already an address?" -- for a hostname the answer stays no
    bool redirect = node && ws_host(node) && !(hp && (hp->ai_flags & AI_NUMERICHOST));
    // 0.63: the agent carries /plfe/rpc itself (N2ServerSend bypass); the plugin's own HTTPS engine
    // corrupts the heap under translation, so fail its port-443 lookup right away.
    if (redirect && serv && !strcmp(serv, "443") && getenv("WST_BLOCK_NATIVE_RPC")) {
        NETLOG("[net] getaddrinfo(%s):443 blocked (WST_BLOCK_NATIVE_RPC)", node);
        c.ret(u32(EAI_FAIL)); return;
    }
    if (redirect) { NETLOG("[net] getaddrinfo(%s) -> 127.0.0.1", node); name = "127.0.0.1";
                    if (hp && hp->ai_family == AF_INET6) hp->ai_family = AF_UNSPEC;
                    // 0.71+: the Niantic plugin's own HTTPS (port 443) won't use a loopback answer;
                    // give it the server WsNet names instead.
                    const char* rh = getenv("WST_RPC_HOST");
                    if (rh && serv && !strcmp(serv, "443")) { name = rh; NETLOG("[net]   :443 -> %s", rh); } }
    addrinfo* res = nullptr;
    int r = getaddrinfo(node ? name.c_str() : nullptr, serv, hp, &res);
    if (r != 0) { if (node) NETLOG("[net] getaddrinfo(%s) failed: %s", node, gai_strerror(r)); c.ret(u32(r)); return; }
    gaddr head = 0, prev = 0;
    for (addrinfo* a = res; a; a = a->ai_next) {
        u32 al = u32(a->ai_addrlen), cl = a->ai_canonname ? u32(strlen(a->ai_canonname) + 1) : 0;
        gaddr g = gmalloc(32 + al + cl);
        memset(H(g), 0, 32 + al + cl);
        wr32(g, u32(a->ai_flags)); wr32(g + 4, u32(a->ai_family)); wr32(g + 8, u32(a->ai_socktype));
        wr32(g + 12, u32(a->ai_protocol)); wr32(g + 16, al);
        if (cl) { memcpy(H(g + 32 + al), a->ai_canonname, cl); wr32(g + 20, g + 32 + al); }
        if (al) { memcpy(H(g + 32), a->ai_addr, al); wr32(g + 24, g + 32); }
        if (prev) wr32(prev + 28, g); else head = g;
        prev = g;
    }
    if (redirect) { static int n = 0; if (n++ < 20) logf("[net]   from %s", describe_addr(c.jit()->Regs()[14]).c_str());
                    if (serv && !strcmp(serv, "443")) { extern void svc_trace_thread(int); svc_trace_thread(400); } }
    if (redirect) { static int n = 0; if (n++ < 20) logf("[net]   hints fl=%x fam=%d st=%d pr=%d serv=%s -> fam=%d st=%d len=%u%s",
        hp ? hp->ai_flags : -1, hp ? hp->ai_family : -1, hp ? hp->ai_socktype : -1, hp ? hp->ai_protocol : -1, serv ? serv : "-",
        res ? res->ai_family : -1, res ? res->ai_socktype : -1, res ? u32(res->ai_addrlen) : 0, res && res->ai_next ? " (+more)" : ""); }
    freeaddrinfo(res);
    wr32(c.argp(3), head);
    c.ret(0);
}
DEF(freeaddrinfo) { for (gaddr g = c.argp(0); g;) { gaddr n = rd32(g + 28); gfree(g); g = n; } c.ret(0); }
DEF(getnameinfo) {
    u32 hl = c.arg(4), sv = c.arg(5), sl = c.arg(6), fl = c.arg(7);
    int r = getnameinfo((sockaddr*)H(c.argp(0)), socklen_t(c.arg(1)), c.argp(2) ? (char*)H(c.argp(2)) : nullptr, c.arg(3),
                        sv ? (char*)H(sv) : nullptr, sl, int(fl));
    (void)hl; c.ret(u32(r));
}
DEF(gethostname){ strncpy(reinterpret_cast<char*>(H(c.argp(0))),"localhost",c.arg(1)); c.ret(0); }
DEF(inet_addr){ c.ret(u32(inet_addr(HS(c.argp(0))))); }
DEF(inet_ntop){ const char* r = inet_ntop(int(c.arg(0)), H(c.argp(1)), (char*)H(c.argp(2)), socklen_t(c.arg(3))); if (!r) set_errno(); c.retp(r ? c.argp(2) : 0); }
DEF(inet_pton){ int r = inet_pton(int(c.arg(0)), HS(c.argp(1)), H(c.argp(2))); if (r < 0) set_errno(); c.ret(u32(r)); }
DEF(poll){ int r = poll((pollfd*)H(c.argp(0)), nfds_t(c.arg(1)), int(c.arg(2))); if (r < 0) set_errno(); c.ret(u32(r)); }
DEF(writev){ gaddr iov=c.argp(1); int n=int(c.arg(2)); ssize_t tot=0; for(int i=0;i<n;++i){ gaddr base=rd32(iov+i*8); u32 len=rd32(iov+i*8+4); ssize_t r=write(int(c.arg(0)),H(base),len); if(r<0){c.ret(u32(-1));return;} tot+=r;} c.ret(u32(tot)); }
DEF(sched_yield){ sched_yield(); c.ret(0); }
DEF(fscanf){ c.ret(u32(-1)); }     // EOF; il2cpp rarely needs it during init
DEF(sscanf){ c.ret(0); }
DEF(utime){ c.ret(0); }
DEF(bsearch_real){ c.retp(0); }

// ---------------- extra libc surface libunity pulls in ----------------
// Most are straight host forwards over flat guest memory; a few (qsort/bsearch,
// div, SHA1) re-enter guest code or compute directly.

// stdio
DEF(printf)   { VA va{c, 1}; std::string s = gformat(HS(c.argp(0)), va); fputs(s.c_str(), stdout); c.ret(u32(s.size())); }
DEF(vprintf)  { gaddr ap = c.argp(1); const char* fmt = HS(c.argp(0)); std::string out;
                // va_list is a guest pointer to a packed 32-bit arg area.
                for (const char* p = fmt; *p; ++p) {
                    if (*p != '%') { out += *p; continue; }
                    // delegate to gformat-style handling is awkward over a packed list; keep it simple:
                    out += *p;
                }
                fputs(out.c_str(), stdout); c.ret(u32(out.size())); }
DEF(fprintf)  { FILE* f = host_file(c.argp(0)); VA va{c, 2}; std::string s = gformat(HS(c.argp(1)), va);
                if (f) fputs(s.c_str(), f); c.ret(u32(s.size())); }
DEF(fgets)    { FILE* f = host_file(c.argp(2)); if (!f) { c.retp(0); return; }
                char* r = fgets(reinterpret_cast<char*>(H(c.argp(0))), int(c.arg(1)), f); c.retp(r ? c.argp(0) : 0); }
DEF(fseek)    { FILE* f = host_file(c.argp(0)); c.ret(u32(f ? fseek(f, long(s32(c.arg(1))), int(c.arg(2))) : -1)); }
DEF(ftell)    { FILE* f = host_file(c.argp(0)); c.ret(u32(f ? ftell(f) : -1)); }
DEF(getc)     { FILE* f = host_file(c.argp(0)); c.ret(u32(f ? getc(f) : -1)); }
DEF(putc)     { FILE* f = host_file(c.argp(1)); c.ret(u32(f ? putc(int(c.arg(0)), f) : -1)); }
DEF(putchar)  { c.ret(u32(putchar(int(c.arg(0))))); }
DEF(puts)     { c.ret(u32(puts(HS(c.argp(0))))); }
DEF(ungetc)   { FILE* f = host_file(c.argp(1)); c.ret(u32(f ? ungetc(int(c.arg(0)), f) : -1)); }
DEF(clearerr) { FILE* f = host_file(c.argp(0)); if (f) clearerr(f); c.ret(0); }
DEF(ferror)   { FILE* f = host_file(c.argp(0)); c.ret(u32(f ? ferror(f) : 0)); }
DEF(perror)   { const char* s = c.argp(0) ? HS(c.argp(0)) : nullptr; if (s && *s) fprintf(stderr, "%s: ", s);
                fprintf(stderr, "%s\n", strerror(int(rd32(guest_errno_addr())))); c.ret(0); }

// string / mem
DEF(strcasecmp)  { c.ret(u32(strcasecmp(HS(c.argp(0)), HS(c.argp(1))))); }
DEF(strncasecmp) { c.ret(u32(strncasecmp(HS(c.argp(0)), HS(c.argp(1)), c.arg(2)))); }
DEF(strcasestr)  { char* p = strcasestr(const_cast<char*>(HS(c.argp(0))), HS(c.argp(1))); c.retp(p ? G(p) : 0); }
DEF(strpbrk)     { char* p = strpbrk(const_cast<char*>(HS(c.argp(0))), HS(c.argp(1))); c.retp(p ? G(p) : 0); }
DEF(strsep)      { gaddr pp = c.argp(0); if (!pp || !rd32(pp)) { c.retp(0); return; }
                   char* sp = reinterpret_cast<char*>(H(rd32(pp)));
                   char* tok = strsep(&sp, HS(c.argp(1)));
                   wr32(pp, sp ? G(sp) : 0); c.retp(tok ? G(tok) : 0); }
DEF(strtok)      { static thread_local char* saved = nullptr;
                   char* s = c.argp(0) ? reinterpret_cast<char*>(H(c.argp(0))) : nullptr;
                   char* tok = strtok_r(s, HS(c.argp(1)), &saved); c.retp(tok ? G(tok) : 0); }
DEF(strtoull)    { char* e = nullptr; unsigned long long v = strtoull(HS(c.argp(0)), &e, int(c.arg(2)));
                   if (c.argp(1)) wr32(c.argp(1), G(e)); c.ret64(v); }
DEF(memmem)      { void* p = memmem(H(c.argp(0)), c.arg(1), H(c.argp(2)), c.arg(3)); c.retp(p ? G(p) : 0); }

// wide-char (Android wchar_t == our existing 16-bit convention in wmem*)
DEF(wcscat) { u16* d = HP<u16>(c.argp(0)); const u16* s = HP<u16>(c.argp(1)); u32 n = 0; while (d[n]) ++n;
              u32 i = 0; do { d[n + i] = s[i]; } while (s[i++]); c.retp(c.argp(0)); }
DEF(wcscpy) { u16* d = HP<u16>(c.argp(0)); const u16* s = HP<u16>(c.argp(1)); u32 i = 0; do { d[i] = s[i]; } while (s[i++]); c.retp(c.argp(0)); }
DEF(wcscmp) { const u16* a = HP<u16>(c.argp(0)); const u16* b = HP<u16>(c.argp(1)); u32 i = 0;
              while (a[i] && a[i] == b[i]) ++i; c.ret(u32(int(a[i]) - int(b[i]))); }
DEF(wcsncmp){ const u16* a = HP<u16>(c.argp(0)); const u16* b = HP<u16>(c.argp(1)); u32 n = c.arg(2);
              for (u32 i = 0; i < n; ++i) { if (a[i] != b[i]) { c.ret(u32(int(a[i]) - int(b[i]))); return; } if (!a[i]) break; } c.ret(0); }
DEF(wcsncpy){ u16* d = HP<u16>(c.argp(0)); const u16* s = HP<u16>(c.argp(1)); u32 n = c.arg(2);
              u32 i = 0; for (; i < n && s[i]; ++i) d[i] = s[i]; for (; i < n; ++i) d[i] = 0; c.retp(c.argp(0)); }
DEF(wcsncat){ u16* d = HP<u16>(c.argp(0)); const u16* s = HP<u16>(c.argp(1)); u32 n = c.arg(2);
              u32 e = 0; while (d[e]) ++e; u32 i = 0; for (; i < n && s[i]; ++i) d[e + i] = s[i]; d[e + i] = 0; c.retp(c.argp(0)); }
DEF(wcstol) { c.ret(0); }
DEF(wcstod) { dret(c, 0.0); }
DEF(wprintf){ c.ret(0); }
DEF(swscanf){ c.ret(0); }
DEF(getwc)  { c.ret(u32(-1)); }
DEF(putwc)  { c.ret(c.arg(0)); }
DEF(ungetwc){ c.ret(c.arg(0)); }

// math
DEF(fabsf)   { fret(c, fabsf(farg(c, 0))); }
DEF(log10f)  { fret(c, log10f(farg(c, 0))); }
DEF(roundf)  { fret(c, roundf(farg(c, 0))); }
DEF(truncf)  { fret(c, truncf(farg(c, 0))); }
DEF(__isfinitef) { c.ret(std::isfinite(farg(c, 0)) ? 1u : 0u); }
DEF(frexp)   { int e = 0; double m = frexp(darg(c, 0), &e); if (c.argp(2)) wr32(c.argp(2), u32(e)); dret(c, m); }
DEF(ldexp)   { dret(c, ldexp(darg(c, 0), int(c.arg(2)))); }
DEF(modff)   { float ip; float r = modff(farg(c, 0), &ip); if (c.argp(1)) wr32(c.argp(1), [&]{ u32 b; memcpy(&b, &ip, 4); return b; }()); fret(c, r); }
DEF(div)     { int num = int(c.arg(0)), den = int(c.arg(1)); c.ret(u32(den ? num / den : 0)); c.jit()->Regs()[1] = u32(den ? num % den : 0); }  // div_t{quot,rem} in r0,r1
DEF(lrand48) { c.ret(u32(lrand48())); }
DEF(srand48) { srand48(long(c.arg(0))); c.ret(0); }

// sort / search with a guest comparator
DEF(qsort) {
    gaddr base = c.argp(0); u32 nmemb = c.arg(1), size = c.arg(2); gaddr cmp = c.argp(3);
    if (nmemb < 2 || !size) { c.ret(0); return; }
    std::vector<u32> idx(nmemb); for (u32 i = 0; i < nmemb; ++i) idx[i] = i;
    std::stable_sort(idx.begin(), idx.end(), [&](u32 a, u32 b) {
        return int(call_guest(cmp, {base + a * size, base + b * size})) < 0; });
    std::vector<u8> tmp(size_t(nmemb) * size);
    memcpy(tmp.data(), H(base), tmp.size());
    for (u32 i = 0; i < nmemb; ++i) memcpy(H(base + i * size), tmp.data() + size_t(idx[i]) * size, size);
    c.ret(0);
}
DEF(bsearch) {
    gaddr key = c.argp(0), base = c.argp(1); u32 nmemb = c.arg(2), size = c.arg(3); gaddr cmp = c.argp(4);
    long lo = 0, hi = long(nmemb) - 1;
    while (lo <= hi) {
        long mid = (lo + hi) / 2; gaddr e = base + u32(mid) * size;
        int r = int(call_guest(cmp, {key, e}));
        if (r == 0) { c.retp(e); return; }
        if (r < 0) hi = mid - 1; else lo = mid + 1;
    }
    c.retp(0);
}

// SHA1 (ours — tiny, used by Unity's crash/analytics hashing during startup)
namespace { struct SHA1 { u32 h[5]; u64 len; u8 buf[64]; u32 n;
    static u32 rol(u32 v, int b) { return (v << b) | (v >> (32 - b)); }
    void init() { h[0]=0x67452301; h[1]=0xEFCDAB89; h[2]=0x98BADCFE; h[3]=0x10325476; h[4]=0xC3D2E1F0; len=0; n=0; }
    void block(const u8* p) { u32 w[80];
        for (int i=0;i<16;++i) w[i]=(p[i*4]<<24)|(p[i*4+1]<<16)|(p[i*4+2]<<8)|p[i*4+3];
        for (int i=16;i<80;++i) w[i]=rol(w[i-3]^w[i-8]^w[i-14]^w[i-16],1);
        u32 a=h[0],b=h[1],cc=h[2],d=h[3],e=h[4];
        for (int i=0;i<80;++i){ u32 f,k;
            if(i<20){f=(b&cc)|(~b&d);k=0x5A827999;} else if(i<40){f=b^cc^d;k=0x6ED9EBA1;}
            else if(i<60){f=(b&cc)|(b&d)|(cc&d);k=0x8F1BBCDC;} else {f=b^cc^d;k=0xCA62C1D6;}
            u32 t=rol(a,5)+f+e+k+w[i]; e=d; d=cc; cc=rol(b,30); b=a; a=t; }
        h[0]+=a; h[1]+=b; h[2]+=cc; h[3]+=d; h[4]+=e; }
    void update(const u8* p, u32 l) { len += l;
        while (l) { u32 take = 64 - n; if (take > l) take = l; memcpy(buf + n, p, take); n += take; p += take; l -= take;
            if (n == 64) { block(buf); n = 0; } } }
    void final(u8 out[20]) { u64 bits = len * 8; u8 pad = 0x80; update(&pad, 1);
        u8 zero = 0; while (n != 56) update(&zero, 1);
        u8 lb[8]; for (int i=0;i<8;++i) lb[i]=u8(bits >> (56 - i*8)); update(lb, 8);
        for (int i=0;i<5;++i){ out[i*4]=u8(h[i]>>24); out[i*4+1]=u8(h[i]>>16); out[i*4+2]=u8(h[i]>>8); out[i*4+3]=u8(h[i]); } } };
}
DEF(SHA1Init)   { SHA1* s = HP<SHA1>(c.argp(0)); s->init(); c.ret(0); }
DEF(SHA1Update) { SHA1* s = HP<SHA1>(c.argp(0)); s->update(reinterpret_cast<const u8*>(H(c.argp(1))), c.arg(2)); c.ret(0); }
DEF(SHA1Final)  { // bionic order is SHA1Final(digest, ctx)
                  SHA1* s = HP<SHA1>(c.argp(1)); u8 out[20]; s->final(out); memcpy(H(c.argp(0)), out, 20); c.ret(0); }

// logging
DEF(__android_log_vprint) {
    std::string m = gvformat(c.argp(2) ? HS(c.argp(2)) : "", c.argp(3));
    logf("[guest:%s] %s", c.argp(1) ? HS(c.argp(1)) : "", m.c_str()); c.ret(0); }

// process / ids / net — stubbed to benign failures (not reached during init)
DEF(getuid)   { c.ret(0); }
DEF(getpwuid) { c.retp(0); }
DEF(fork)     { c.ret(u32(-1)); }
DEF(execl)    { c.ret(u32(-1)); }
DEF(waitpid)  { c.ret(u32(-1)); }
DEF(ptrace)   { c.ret(0); }
DEF(dlerror)  { c.retp(0); }
// hostent (ARM32): name, aliases, addrtype, length, addr_list -- in one thread-local block
DEF(gethostbyname){
    const char* n = HS(c.argp(0));
    std::string name = n; if (ws_host(n)) { NETLOG("[net] gethostbyname(%s) -> 127.0.0.1", n); name = "127.0.0.1"; }
    addrinfo hints{}, *res = nullptr; hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(name.c_str(), nullptr, &hints, &res) != 0 || !res) { c.retp(0); return; }
    static thread_local gaddr b = 0; if (!b) b = gmalloc(512);
    memset(H(b), 0, 512);
    u32 ip = ((sockaddr_in*)res->ai_addr)->sin_addr.s_addr; freeaddrinfo(res);
    strncpy((char*)H(b + 64), n, 255);
    wr32(b + 40, ip);                       // the address
    wr32(b + 32, b + 40); wr32(b + 36, 0);  // addr_list = {&addr, NULL}
    wr32(b + 28, 0);                        // aliases = {NULL}
    wr32(b, b + 64); wr32(b + 4, b + 28); wr32(b + 8, AF_INET); wr32(b + 12, 4); wr32(b + 16, b + 32);
    c.retp(b);
}
DEF(gai_strerror) { static thread_local gaddr b = 0; if (!b) b = gmalloc(128); strncpy(reinterpret_cast<char*>(H(b)), gai_strerror(int(c.arg(0))), 127); c.retp(b); }
DEF(inet_aton){ c.ret(u32(inet_aton(HS(c.argp(0)), (in_addr*)H(c.argp(1))))); }
DEF(inet_ntoa){ static thread_local gaddr b = 0; if (!b) b = gmalloc(16); in_addr a; a.s_addr = c.arg(0); strcpy(reinterpret_cast<char*>(H(b)), inet_ntoa(a)); c.retp(b); }
DEF(select) {   // fd_set bitmaps are identical; timeval is two 32-bit longs on the guest
    gaddr tv = c.arg(4); timeval t{}, *tp = nullptr;
    if (tv) { t.tv_sec = long(int32_t(rd32(tv))); t.tv_usec = long(int32_t(rd32(tv + 4))); tp = &t; }
    auto fs = [&](int i) { return c.argp(i) ? (fd_set*)H(c.argp(i)) : nullptr; };
    int r = select(int(c.arg(0)), fs(1), fs(2), fs(3), tp);
    if (r < 0) set_errno();
    if (tv) { wr32(tv, u32(t.tv_sec)); wr32(tv + 4, u32(t.tv_usec)); }
    c.ret(u32(r));
}
DEF(sleep)    { usleep(c.arg(0) * 1000000u); c.ret(0); }
DEF(statfs)   { if (c.argp(1)) memset(H(c.argp(1)), 0, 64); c.ret(0); }
DEF(truncate) { c.ret(u32(truncate(HS(c.argp(0)), off_t(c.arg(1))))); }
// Raw syscall(): the guest numbers are ARM EABI. futex works directly on the
// guest word (it is real host memory); timeouts are 32-bit timespecs.
DEF(syscall)  {
    u32 nr = c.arg(0);
    switch (nr) {
    case 240: {   // futex(uaddr, op, val, timeout*, uaddr2, val3)
        int op = int(c.arg(2)); int cmd = op & 0x7f;
        struct timespec ts, *tp = nullptr;
        if ((cmd == 0 || cmd == 9) && c.argp(4)) { ts.tv_sec = s32(rd32(c.argp(4))); ts.tv_nsec = s32(rd32(c.argp(4) + 4)); tp = &ts; }
        long r = ::syscall(SYS_futex, H(c.argp(1)), op, c.arg(3), tp,
                           c.argp(5) ? H(c.argp(5)) : nullptr, c.arg(6));
        if (r < 0) { set_errno(); c.ret(u32(-1)); } else c.ret(u32(r));
        return;
    }
    case 224: c.ret(u32(gettid())); return;        // gettid
    case 20:  c.ret(u32(getpid())); return;        // getpid
    case 158: sched_yield(); c.ret(0); return;     // sched_yield
    default: {
        static bool seen[512];
        if (nr < 512 && !seen[nr]) { seen[nr] = true; logf("[sys] unhandled syscall(%u) -> 0", nr); }
        c.ret(0); return;
    }
    }
}
DEF(sched_get_priority_max) { c.ret(99); }
DEF(sched_get_priority_min) { c.ret(1); }

// pthread extras
DEF(pthread_equal)   { c.ret(c.arg(0) == c.arg(1) ? 1u : 0u); }
// Never returns to the caller (Unity tail-calls it at the end of its thread wrapper, so
// returning ran whatever code came next). On a thread we started, the guest call simply
// ends -- the host thread then returns from its trampoline. Deeper (guest code entered
// from a host callback) there is no clean way out, so the thread is parked.
DEF(pthread_exit) {
    GuestThread* gt = cur_thread();
    gt->retval = c.arg(0);
    if (gt->depth == 1 && gt->start_fn) { c.ret(c.arg(0)); c.halt_return(); return; }
    logf("[thr] pthread_exit at depth %d: parking tid %u", gt->depth, gt->tid);
    for (;;) pause();
}
DEF(pthread_setname_np)      {
    // Only the calling thread can be mapped to its host thread; that is the common use.
    if (c.argp(1) && c.argp(0) == cur_thread()->self) { char n[16]; strncpy(n, HS(c.argp(1)), 15); n[15] = 0; pthread_setname_np(pthread_self(), n); }
    else if (c.argp(1)) logf("[sys] pthread_setname_np(other thread %08x, %s)", c.argp(0), HS(c.argp(1)));
    c.ret(0); }
DEF(pthread_getschedparam)   { if (c.argp(2)) wr32(c.argp(2), 0); c.ret(0); }
DEF(pthread_setschedparam)   { c.ret(0); }
DEF(pthread_attr_setschedparam)  { c.ret(0); }
DEF(pthread_attr_setschedpolicy) { c.ret(0); }
DEF(pthread_cond_timedwait)  {
    if (!c.argp(2)) { auto* cv = get_cond(c.argp(0)); GMutexWaitLock wl{get_mutex(c.argp(1))}; cv->wait(wl); c.ret(0); return; }
    // absolute CLOCK_REALTIME timespec -> relative wait
    long sec = rd32(c.argp(2)), ns = rd32(c.argp(2) + 4);
    struct timespec now; clock_gettime(CLOCK_REALTIME, &now);
    auto d = std::chrono::seconds(sec - now.tv_sec) + std::chrono::nanoseconds(ns - now.tv_nsec);
    c.ret(u32(cond_wait_for(c.argp(0), c.argp(1), std::chrono::duration_cast<std::chrono::nanoseconds>(d)))); }

// monotonic-clock variant (bionic LP32 extension)
DEF(pthread_cond_timedwait_monotonic_np) {
    if (!c.argp(2)) { auto* cv = get_cond(c.argp(0)); GMutexWaitLock wl{get_mutex(c.argp(1))}; cv->wait(wl); c.ret(0); return; }
    long sec = rd32(c.argp(2)), ns = rd32(c.argp(2) + 4);
    struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
    auto d = std::chrono::seconds(sec - now.tv_sec) + std::chrono::nanoseconds(ns - now.tv_nsec);
    c.ret(u32(cond_wait_for(c.argp(0), c.argp(1), std::chrono::duration_cast<std::chrono::nanoseconds>(d)))); }
DEF(lround)    { c.ret(u32(s32(lround(darg(c, 0))))); }
DEF(remainder) { dret(c, remainder(darg(c, 0), darg(c, 2))); }
DEF(strtoll)   { char* e = nullptr; const char* p = HS(c.argp(0)); long long v = strtoll(p, &e, int(c.arg(2)));
                 if (c.argp(1)) wr32(c.argp(1), c.argp(0) + u32(e - p)); c.ret64(u64(v)); }
DEF(fgetc)     { FILE* f = host_file(c.argp(0)); c.ret(u32(f ? fgetc(f) : -1)); }
DEF(rewind)    { FILE* f = host_file(c.argp(0)); if (f) rewind(f); c.ret(0); }
DEF(lseek64)   { off_t r = lseek(int(c.arg(0)), off_t(s64(c.arg64(2))), int(c.arg(4))); if (r < 0) set_errno(); c.ret64(u64(r)); }
DEF(fchmod)    { int r = fchmod(int(c.arg(0)), mode_t(c.arg(1))); if (r < 0) set_errno(); c.ret(u32(r)); }
DEF(fchown)    { c.ret(0); }
DEF(flock)     { int r = flock(int(c.arg(0)), int(c.arg(1))); if (r < 0) set_errno(); c.ret(u32(r)); }
DEF(geteuid)   { c.ret(0); }
DEF(getrusage) { if (c.argp(1)) memset(H(c.argp(1)), 0, 72); c.ret(0); }   // LP32 struct rusage
DEF(mremap)    { wr32(guest_errno_addr(), ENOMEM); c.ret(u32(-1)); }   // MAP_FAILED: callers fall back to copy
DEF(system)    { c.ret(u32(-1)); }
DEF(utimes)    { c.ret(0); }

// Full guest-varargs Android log (overrides the verbatim one in thunks.cpp) so
// Unity's own error/assert messages (logged as __android_log_print(prio,tag,"%s",msg))
// are readable — essential for diagnosing engine failures.
DEF(android_log_print_va) {
    const char* tag = c.argp(1) ? HS(c.argp(1)) : "";
    const char* fmt = c.argp(2) ? HS(c.argp(2)) : "";
    VA va{c, 3};
    std::string s = gformat(fmt, va);
    logf("[guest:%s] %s", tag, s.c_str());
    c.ret(u32(s.size()));
}

static gaddr d_sF_sys() { g_sF = va_alloc(0x1000); return g_sF; }

void sys_init() {
    register_handler("__android_log_print", h_android_log_print_va);
    register_data("__sF", d_sF_sys);   // override the zeroed blob from thunks_init
#define R(n) register_handler(#n, h_##n)
    R(fopen); R(fdopen); R(fclose); R(fread); R(fwrite); R(fflush); R(fputc); R(fputs);
    R(setvbuf); R(popen); R(pclose); R(snprintf); R(sprintf); R(vsnprintf); R(vsprintf);
    R(open); R(close); R(read); R(write); R(lseek); R(ftruncate); R(fsync); R(access);
    R(unlink); R(rename); R(mkdir); R(rmdir); R(chdir); R(chmod); R(getcwd); R(readlink);
    R(dup2); R(pipe); R(isatty); R(fcntl); R(ioctl); R(stat); R(lstat); R(fstat);
    R(opendir); R(closedir); R(readdir); R(mmap); R(munmap); R(mprotect);
    R(getenv); R(setenv); R(unsetenv); R(sysconf); R(uname); R(exit); R(atoi); R(atol);
    R(strtoul); R(strtod); R(strerror); R(strcoll); R(strxfrm); R(strlcpy); R(setlocale);
    R(prctl); R(raise); R(tkill); R(kill); R(sigaction); R(bsd_signal); R(sigsuspend); R(pthread_sigmask);
    register_handler("__google_potentially_blocking_region_begin", h___google_potentially_blocking_region_begin);
    register_handler("__google_potentially_blocking_region_end", h___google_potentially_blocking_region_end);
    register_handler("__pthread_cleanup_push", h___pthread_cleanup_push);
    register_handler("__pthread_cleanup_pop", h___pthread_cleanup_pop);
    R(time); R(clock); R(difftime); R(clock_getres); R(nanosleep); R(usleep);
    R(gmtime); R(localtime); R(mktime); R(strftime);
    R(acos); R(asin); R(atan); R(cos); R(sin); R(tan); R(cosh); R(sinh); R(tanh);
    R(exp); R(log); R(log10); R(ceil); R(floor); R(sqrt); R(exp2);
    R(acosf); R(asinf); R(atanf); R(cosf); R(sinf); R(tanf); R(expf); R(logf); R(ceilf); R(floorf); R(sqrtf); R(exp2f);
    R(round); R(trunc); R(fabs); R(rint); R(nearbyint); R(log2); R(cbrt); R(expm1); R(log1p); R(asinh); R(acosh); R(atanh); R(hypot); R(fmax); R(fmin); R(copysign); R(rintf); R(log2f); R(cbrtf); R(sinhf); R(coshf); R(tanhf); R(fmaxf); R(fminf); R(copysignf); R(hypotf); R(ldexpf); R(scalbn); R(lrint); R(lrintf); R(atan2); R(pow); R(fmod); R(atan2f); R(powf); R(fmodf); R(modf); R(isnan);
    R(wcslen); R(btowc); R(wctob); R(towlower); R(towupper); R(iswctype); R(wctype);
    R(wmemset); R(wmemcpy); R(wmemmove); R(wmemcmp); R(wmemchr); R(wcscoll); R(wcsxfrm); R(wcsftime); R(wcrtomb); R(mbrtowc);
    R(dlopen); R(dlsym); R(dlclose); R(dladdr);
    R(pthread_mutex_init); R(pthread_mutex_destroy); R(pthread_mutex_lock); R(pthread_mutex_trylock); R(pthread_mutex_unlock);
    R(pthread_mutexattr_init); R(pthread_mutexattr_destroy); R(pthread_mutexattr_settype);
    R(pthread_cond_init); R(pthread_cond_destroy); R(pthread_cond_signal); R(pthread_cond_broadcast); R(pthread_cond_wait);
    register_handler("pthread_cond_timedwait_relative_np", h_pthread_cond_timedwait_relative_np);
    R(sem_init); R(sem_destroy); R(sem_post); R(sem_wait); R(sem_getvalue);
    R(pthread_create); R(pthread_detach); R(pthread_join);
    R(pthread_attr_init); R(pthread_attr_destroy); R(pthread_attr_setdetachstate); R(pthread_attr_getdetachstate);
    R(pthread_attr_setstacksize); R(pthread_attr_getstack); R(pthread_getattr_np);
    R(setjmp); register_handler("sigsetjmp", h_setjmp);
    register_handler("longjmp", h_longjmp); register_handler("siglongjmp", h_longjmp);
    register_handler("_setjmp", h_setjmp); register_handler("_longjmp", h_longjmp);
    R(socket); R(bind); R(connect); R(listen); R(accept); R(send); R(sendto); R(sendmsg);
    R(recvfrom); R(recvmsg); R(getsockname); R(getpeername); R(getsockopt); R(setsockopt);
    R(shutdown); R(getaddrinfo); R(getnameinfo); R(sendfile); R(freeaddrinfo); R(gethostname);
    R(inet_addr); R(inet_ntop); R(inet_pton); R(poll); R(writev); R(sched_yield); R(fscanf); R(sscanf); R(utime);
    // --- Phase 3 additions (libunity's libc surface) ---
    R(printf); R(vprintf); R(fprintf); R(fgets); R(fseek); R(ftell); R(getc); R(putc);
    R(putchar); R(puts); R(ungetc); R(clearerr); R(ferror); R(perror);
    R(strcasecmp); R(strncasecmp); R(strcasestr); R(strpbrk); R(strsep); R(strtok); R(strtoull); R(memmem);
    R(wcscat); R(wcscpy); R(wcscmp); R(wcsncmp); R(wcsncpy); R(wcsncat); R(wcstol); R(wcstod);
    R(wprintf); R(swscanf); R(getwc); R(putwc); R(ungetwc);
    R(fabsf); R(log10f); R(roundf); R(truncf); R(frexp); R(ldexp); R(modff); R(div); R(lrand48); R(srand48);
    register_handler("__isfinitef", h___isfinitef);
    R(qsort); R(bsearch);
    R(SHA1Init); R(SHA1Update); R(SHA1Final);
    register_handler("__android_log_vprint", h___android_log_vprint);
    R(pthread_cond_timedwait_monotonic_np); R(lround); R(remainder); R(strtoll); R(fgetc); R(rewind);
    R(lseek64); R(fchmod); R(fchown); R(flock); R(geteuid); R(getrusage); R(mremap); R(system); R(utimes);
    R(getuid); R(getpwuid); R(fork); R(execl); R(waitpid); R(ptrace); R(dlerror);
    R(gethostbyname); R(gai_strerror); R(inet_aton); R(inet_ntoa); R(recv); R(select);
    R(sleep); R(statfs); R(truncate); R(syscall); R(sched_get_priority_max); R(sched_get_priority_min);
    R(pthread_equal); R(pthread_exit); R(pthread_setname_np);
    R(pthread_getschedparam); R(pthread_setschedparam);
    R(pthread_attr_setschedparam); R(pthread_attr_setschedpolicy); R(pthread_cond_timedwait);
#undef R
}

}  // namespace wst
