// il2hook.c -- jitless il2cpp RPC bypass for 0.67.2.
//
// Jitless: we never patch a code page. We locate the managed N2ServerSend_ /
// N2ServerRefreshAuthToken_ delegate objects and overwrite their method_ptr field
// (a write to an il2cpp DATA object -- allowed without RWX/JIT), so every
// delegate.Invoke lands in us instead of the native platform sender.
//
// What it does (the Android agent's job, done in-process as a static tweak):
//   * capture the PTC auth ticket from N2ServerRefreshAuthToken_(authId, token[], n)
//   * on N2ServerSend_(... methods[], bodies, sizes[] ...), grab the PLAIN request
//     bodies BEFORE the native platform layer wraps them into the rpc2 envelope,
//     build a plain RequestEnvelope protobuf, and POST it to the server on :80.
//
// Stage 2a: POST only -- we do NOT yet deliver the reply back into the client
// (that needs RpcManager.Recv + il2cpp object allocation, Stage 2b). Success here =
// the server log shows a real GetPlayer RPC with valid auth getting a 200.
//
// Offsets are VA-offsets from the 0.67.2 dump (VA = 0x100000000 + offset), applied
// to the GUEST pokemongo image base at runtime. Delegate static-field offsets and
// the 0x98/0x10/0x20 struct offsets were read from the disassembly of
// RpcBindings.Send (0x8EE790), AuthBindings.RefreshAuthToken (0x8E4588) and
// N2ServerSend_.Invoke (0x8ED9EC).

#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <dispatch/dispatch.h>
#include <os/log.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

#define HLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[WSHook] " fmt, ##__VA_ARGS__)

// --- baked offsets (VA-offsets in the 0.67.2 arm64 binary) ---
#define SLOT_N2EP_CLASS            0x3a60d18   // __DATA slot -> Il2CppClass* N2EntryPoints
#define CLASS_STATICFIELDS_OFF     0x98        // Il2CppClass.static_fields
#define SEND_DELEGATE_STATIC_OFF   0x2a0       // static_fields -> N2ServerSend_ delegate
#define REFRESH_DELEGATE_STATIC_OFF 0x290      // static_fields -> N2ServerRefreshAuthToken_ delegate
#define RESET_DELEGATE_STATIC_OFF   0x298      // static_fields -> N2ServerResetAuthToken_ delegate
#define DELEGATE_METHODPTR_OFF     0x10        // Il2CppDelegate.method_ptr
#define DELEGATE_TARGET_OFF        0x20        // Il2CppDelegate.target (the bound instance)
#define IL2CPP_ARRAY_DATA          0x20        // System.Array element data (64-bit)
#define IL2CPP_ARRAY_LEN           0x10        // System.Array length (64-bit)

// --- Stage 2b: reply delivery (all VA-offsets, runtime addr = g_base + off) ---
// il2cpp runtime functions (recovered from ByteString.CopyFrom disassembly, lldb-verified)
#define IL2_OBJECT_NEW             0x191ca8c   // Object* il2cpp_object_new(Il2CppClass*)
#define IL2_ARRAY_NEW              0x190839c   // Array*  NewSpecific(arrayClass, count)
#define IL2_ARRCLASS_INIT          0x190a398   // void    array-class init (arrayClass)
// managed method (lldb-verified entry): RpcManager.Recv(this, RpcResponse)
#define OFF_RpcManager_Recv        0x8fd9a4
// il2cpp metadata-usage initializer: init(uint32 usageIndex). RpcResponse and
// RepeatedField<ByteString> are only touched when a reply is built, so their
// TypeInfo slots start null; we replicate the game's own class-init (read the
// runtime-resolved usage index from the same __DATA slot Recv/get_Item use, then
// call init) to populate them before we allocate.
#define IL2_CLASSINIT              0x1916238
// OnRpcResponseEventHandler (0x8fda64) is the game's own RpcResponse builder; its
// prologue runs `ldr w0,[0x1031c1ec0]; bl 0x101916238` which resolves its whole
// metadata-usage block -- the block that object_news RpcResponse and references the
// RepeatedField<ByteString>. We make the exact same call.
#define USAGE_OnRpcResp            0x31c1ec0  // OnRpcResponseEventHandler block: resolves RpcResponse (page 0x1031c1000 + 0xec0)
#define USAGE_RpcRespEvtParams     0x31c1ee8  // RpcResponseEventParams..ctor block: news/resolves RepeatedField<ByteString> (0x1031c1000 + 0xee8)
// Il2CppClass* storage slots (metadata-verified)
#define SLOT_RpcResponse_CLASS     0x3a61200
#define SLOT_RpcManager_CLASS      0x3a611a0
#define SLOT_ByteString_CLASS      0x3a5ff70
#define SLOT_ByteArr_CLASS         0x3a5ce98   // byte[]
#define SLOT_ObjArr_CLASS          0x3a5cf10   // object[]  (backing for RepeatedField<ByteString>)
#define SLOT_RepeatedFieldBS_CLASS 0x3a60fd0   // RepeatedField<ByteString>
// field layouts (from lldb-verified getters/setters)
#define RPCRESP_RPCID_OFF          0x10        // RpcResponse.<RpcId>          int
#define RPCRESP_STATUS_OFF         0x14        // RpcResponse.<RpcStatus>      int (1 = success)
#define RPCRESP_PAYLOADS_OFF       0x18        // RpcResponse.<ActionPayloads> RepeatedField<ByteString>
#define RPCRESP_COUNT_OFF          0x20        // RpcResponse.<ActionCount>    int
#define REPFIELD_ARRAY_OFF         0x10        // RepeatedField<T>.array  T[]
#define REPFIELD_COUNT_OFF         0x18        // RepeatedField<T>.count  int
#define BYTESTRING_BYTES_OFF       0x10        // ByteString.bytes  byte[]
#define RPCMGR_RESPONSEEVENT_OFF   0x0         // RpcManager static Action<RpcResponse> RpcResponseEvent

#define MAX_PAYLOADS 64

static uintptr_t g_base;
static size_t    g_text_vmsize;
static char      g_server[64] = "127.0.0.1";
static char      g_token[512];
static int       g_token_len;

static inline int32_t arr_i32(void *arr, int i) {
    return arr ? *(int32_t *)((uint8_t *)arr + IL2CPP_ARRAY_DATA + (size_t)i * 4) : -1;
}

// ---- tiny growable byte buffer + protobuf encoders ----
typedef struct { uint8_t *p; size_t len, cap; } buf_t;
static void bput(buf_t *b, const void *d, size_t n) {
    if (b->len + n > b->cap) {
        size_t c = b->cap ? b->cap * 2 : 256;
        while (c < b->len + n) c *= 2;
        b->p = realloc(b->p, c); b->cap = c;
    }
    memcpy(b->p + b->len, d, n); b->len += n;
}
static void bvarint(buf_t *b, uint64_t v) {
    uint8_t t;
    do { t = v & 0x7f; v >>= 7; if (v) t |= 0x80; bput(b, &t, 1); } while (v);
}
static void btag(buf_t *b, int field, int wire) { bvarint(b, ((uint64_t)field << 3) | wire); }
static void bvarfield(buf_t *b, int field, uint64_t v) { btag(b, field, 0); bvarint(b, v); }
static void bbytes(buf_t *b, int field, const void *d, size_t n) {
    btag(b, field, 2); bvarint(b, n); bput(b, d, n);
}

// Find field 1 (wire type 2) in a protobuf message -> the auth ticket string.
static int pb_find_field1_str(const uint8_t *p, int n, const uint8_t **out, int *outlen) {
    int i = 0;
    while (i < n) {
        uint64_t tag = 0; int shift = 0;
        while (i < n && (p[i] & 0x80)) { tag |= (uint64_t)(p[i] & 0x7f) << shift; shift += 7; i++; }
        if (i < n) { tag |= (uint64_t)(p[i] & 0x7f) << shift; i++; }
        int field = tag >> 3, wire = tag & 7;
        if (wire == 2) {
            uint64_t len = 0; shift = 0;
            while (i < n && (p[i] & 0x80)) { len |= (uint64_t)(p[i] & 0x7f) << shift; shift += 7; i++; }
            if (i < n) { len |= (uint64_t)(p[i] & 0x7f) << shift; i++; }
            if (field == 1) { *out = p + i; *outlen = (int)len; return 1; }
            i += (int)len;
        } else if (wire == 0) {
            while (i < n && (p[i] & 0x80)) i++;
            i++;
        } else if (wire == 5) i += 4;
        else if (wire == 1) i += 8;
        else return 0;
    }
    return 0;
}

// ---- image / pointer helpers ----
static size_t ws_image_text_vmsize(const struct mach_header *h) {
    const uint8_t *p = (const uint8_t *)h + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *s = (const struct segment_command_64 *)p;
            if (__builtin_strcmp(s->segname, "__TEXT") == 0) return s->vmsize;
        }
        p += lc->cmdsize;
    }
    return 0;
}

// The guest pokemongo image: match by name, else the image with the biggest __TEXT
// (the 52 MB guest dwarfs LiveContainer and every system dylib).
static uintptr_t ws_guest_base(size_t *text_out) {
    uint32_t n = _dyld_image_count();
    uintptr_t best = 0; size_t best_text = 0;
    for (uint32_t i = 0; i < n; i++) {
        const struct mach_header *h = _dyld_get_image_header(i);
        const char *nm = _dyld_get_image_name(i);
        if (!h) continue;
        size_t tvs = ws_image_text_vmsize(h);
        int is_lc = nm && (__builtin_strstr(nm, "LiveContainer") || __builtin_strstr(nm, "livecontainer"));
        int is_guest = nm && (__builtin_strstr(nm, "pokemongo") || __builtin_strstr(nm, "pokemon"));
        if (is_guest && !is_lc) { if (text_out) *text_out = tvs; return (uintptr_t)h; }
        if (!is_lc && tvs > best_text) { best_text = tvs; best = (uintptr_t)h; }
    }
    if (text_out) *text_out = best_text;
    return best;
}

static int ws_ptr_sane(void *p) {
    uintptr_t v = (uintptr_t)p;
    return v >= 0x100000000ULL && v < 0x800000000000ULL && (v & 7) == 0;
}

// ---- Stage 2b: reply delivery into the client (jitless managed object build) ----
// il2cpp runtime entries, resolved against the guest image base.
typedef void *(*il2_object_new_fn)(void *klass);
typedef void *(*il2_array_new_fn)(void *arr_klass, uintptr_t count);
typedef void  (*il2_arrclass_init_fn)(void *arr_klass);
typedef void  (*recv_fn)(void *self, void *rpc_response, void *methodInfo);

static inline void *gp(uintptr_t off) { return (void *)(g_base + off); }         // code/func ptr
static inline void *gslot(uintptr_t off) {                                       // *(Il2CppClass**)
    return ws_ptr_sane((void *)(g_base + off)) ? *(void **)(g_base + off) : NULL;
}

// Best-effort debug oracle: a one-shot GET the server access-log will show (device
// syslog is unavailable, so the server log is our only window into delivery).
static void ws_dbg(const char *tag, long a, long b) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;
    struct timeval tv = { 1, 0 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    struct sockaddr_in sa; memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET; sa.sin_port = htons(80);
    inet_pton(AF_INET, g_server, &sa.sin_addr);
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) == 0) {
        char req[256];
        int n = snprintf(req, sizeof req,
            "GET /wsdbg?t=%s&a=%ld&b=%ld HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
            tag, a, b);
        write(fd, req, n);
    }
    close(fd);
}

// A ready reply, built on a worker thread, delivered on the il2cpp main thread.
typedef struct {
    int      rpcId;
    int      count;                 // action count from the original request
    int      n;                     // number of payloads parsed from the reply
    uint8_t *data[MAX_PAYLOADS];    // owned copies of each ResponseEnvelope field-100 value
    int      len[MAX_PAYLOADS];
} reply_job;

// Build the managed RpcResponse and hand it to RpcManager.Recv. Runs on the main
// (Unity/il2cpp) thread via dispatch_get_main_queue(), so the thread is il2cpp-
// attached and the GC world is in a safe state. Pure object_new + array_new + data
// writes (Boehm GC is conservative -> no write barriers needed); the only managed
// call is Recv itself.
// Replicate the game's lazy class-init: read the runtime-resolved metadata-usage
// index from the __DATA slot and hand it to the il2cpp initializer. Idempotent.
static void ws_force_classinit(void) {
    static int done;
    if (done) return;
    void (*init_fn)(uint32_t) = (void (*)(uint32_t))gp(IL2_CLASSINIT);
    init_fn(*(uint32_t *)(g_base + USAGE_OnRpcResp));
    init_fn(*(uint32_t *)(g_base + USAGE_RpcRespEvtParams));
    done = 1;
}

static void ws_deliver(reply_job *job) {
    ws_force_classinit();
    void *respK = gslot(SLOT_RpcResponse_CLASS);
    void *repfK = gslot(SLOT_RepeatedFieldBS_CLASS);
    void *bstrK = gslot(SLOT_ByteString_CLASS);
    void *bArrK = gslot(SLOT_ByteArr_CLASS);
    void *oArrK = gslot(SLOT_ObjArr_CLASS);
    void *mgrK  = gslot(SLOT_RpcManager_CLASS);
    if (!respK || !repfK || !bstrK || !bArrK || !oArrK || !mgrK) {
        ws_dbg("deliver_noclass", job->rpcId, (!respK) | (!repfK) << 1 | (!bstrK) << 2 |
               (!bArrK) << 3 | (!oArrK) << 4 | (!mgrK) << 5);
        goto done;
    }
    il2_object_new_fn    obj_new   = (il2_object_new_fn)gp(IL2_OBJECT_NEW);
    il2_array_new_fn     arr_new   = (il2_array_new_fn)gp(IL2_ARRAY_NEW);
    il2_arrclass_init_fn arr_init  = (il2_arrclass_init_fn)gp(IL2_ARRCLASS_INIT);

    // ActionPayloads backing array: object[] of the parsed ByteStrings.
    arr_init(oArrK);
    void *arr = arr_new(oArrK, (uintptr_t)job->n);
    if (!ws_ptr_sane(arr)) { ws_dbg("deliver_noarr", job->rpcId, 0); goto done; }
    arr_init(bArrK);
    for (int i = 0; i < job->n; i++) {
        void *ba = arr_new(bArrK, (uintptr_t)job->len[i]);   // new byte[len]
        if (!ws_ptr_sane(ba)) { ws_dbg("deliver_noba", job->rpcId, i); goto done; }
        if (job->len[i]) memcpy((uint8_t *)ba + IL2CPP_ARRAY_DATA, job->data[i], job->len[i]);
        void *bs = obj_new(bstrK);                           // new ByteString
        if (!ws_ptr_sane(bs)) { ws_dbg("deliver_nobs", job->rpcId, i); goto done; }
        *(void **)((uint8_t *)bs + BYTESTRING_BYTES_OFF) = ba;
        *(void **)((uint8_t *)arr + IL2CPP_ARRAY_DATA + (size_t)i * 8) = bs;
    }

    void *list = obj_new(repfK);                             // new RepeatedField<ByteString>
    if (!ws_ptr_sane(list)) { ws_dbg("deliver_nolist", job->rpcId, 0); goto done; }
    *(void **)((uint8_t *)list + REPFIELD_ARRAY_OFF) = arr;
    *(int32_t *)((uint8_t *)list + REPFIELD_COUNT_OFF) = job->n;

    void *res = obj_new(respK);                              // new RpcResponse
    if (!ws_ptr_sane(res)) { ws_dbg("deliver_nores", job->rpcId, 0); goto done; }
    *(int32_t *)((uint8_t *)res + RPCRESP_RPCID_OFF)   = job->rpcId;
    *(int32_t *)((uint8_t *)res + RPCRESP_STATUS_OFF)  = 1;          // RpcStatus.Success
    *(int32_t *)((uint8_t *)res + RPCRESP_COUNT_OFF)   = job->count;
    *(void  **)((uint8_t *)res + RPCRESP_PAYLOADS_OFF) = list;

    // Deliver via the static RpcResponseEvent delegate: its target is the live
    // RpcManager instance, and we invoke the real Recv on it.
    void *sf = *(void **)((uint8_t *)mgrK + CLASS_STATICFIELDS_OFF);
    void *deleg = (sf && ws_ptr_sane(sf)) ? *(void **)((uint8_t *)sf + RPCMGR_RESPONSEEVENT_OFF) : NULL;
    if (!ws_ptr_sane(deleg)) { ws_dbg("deliver_nodeleg", job->rpcId, (long)(uintptr_t)deleg); goto done; }
    void *inst = *(void **)((uint8_t *)deleg + DELEGATE_TARGET_OFF);
    if (!ws_ptr_sane(inst)) { ws_dbg("deliver_noinst", job->rpcId, 0); goto done; }
    ws_dbg("deliver_ok", job->rpcId, job->n);
    ((recv_fn)gp(OFF_RpcManager_Recv))(inst, res, NULL);
    HLOG("delivered reply #%d (%d payloads) to Recv", job->rpcId, job->n);

done:
    for (int i = 0; i < job->n; i++) free(job->data[i]);
    free(job);
}

// ---- plain POST of a RequestEnvelope to the server :80, then deliver the reply ----
typedef struct { buf_t env; int rpcId; int count; } post_arg;

// Collect every field-100 (wire 2) value of a ResponseEnvelope into the job.
static void parse_returns(const uint8_t *p, int n, reply_job *job) {
    int i = 0;
    while (i < n) {
        uint64_t tag = 0; int shift = 0;
        while (i < n && (p[i] & 0x80)) { tag |= (uint64_t)(p[i] & 0x7f) << shift; shift += 7; i++; }
        if (i >= n) break;
        tag |= (uint64_t)(p[i] & 0x7f) << shift; i++;
        int field = (int)(tag >> 3), wire = tag & 7;
        if (wire == 2) {
            uint64_t len = 0; shift = 0;
            while (i < n && (p[i] & 0x80)) { len |= (uint64_t)(p[i] & 0x7f) << shift; shift += 7; i++; }
            if (i >= n) break;
            len |= (uint64_t)(p[i] & 0x7f) << shift; i++;
            if ((int)len < 0 || i + (int)len > n) break;
            if (field == 100 && job->n < MAX_PAYLOADS) {
                int idx = job->n++;
                job->len[idx] = (int)len;
                job->data[idx] = malloc(len ? len : 1);
                memcpy(job->data[idx], p + i, len);
            }
            i += (int)len;
        } else if (wire == 0) {
            while (i < n && (p[i] & 0x80)) i++;
            i++;
        } else if (wire == 5) i += 4;
        else if (wire == 1) i += 8;
        else break;
    }
}

static void *post_thread(void *arg) {
    post_arg *pa = (post_arg *)arg;
    buf_t *env = &pa->env;
    uint8_t *body = NULL; size_t blen = 0, bcap = 0;   // raw HTTP response accumulator
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd >= 0) {
        struct sockaddr_in sa; memset(&sa, 0, sizeof sa);
        sa.sin_family = AF_INET; sa.sin_port = htons(80);
        inet_pton(AF_INET, g_server, &sa.sin_addr);
        if (connect(fd, (struct sockaddr *)&sa, sizeof sa) == 0) {
            char head[256];
            int hn = snprintf(head, sizeof head,
                "POST /plfe/0/rpc HTTP/1.1\r\nHost: pgorelease.nianticlabs.com\r\n"
                "Content-Type: application/x-protobuf\r\nContent-Length: %zu\r\n"
                "Connection: close\r\n\r\n", env->len);
            write(fd, head, hn);
            write(fd, env->p, env->len);
            // Connection: close -> read to EOF.
            uint8_t chunk[4096]; ssize_t r;
            while ((r = read(fd, chunk, sizeof chunk)) > 0) {
                if (blen + r > bcap) { bcap = (bcap ? bcap * 2 : 8192); while (bcap < blen + r) bcap *= 2; body = realloc(body, bcap); }
                memcpy(body + blen, chunk, r); blen += r;
            }
        } else {
            HLOG("POST connect(%s:80) failed", g_server);
        }
        close(fd);
    }

    if (body && blen) {
        // Split HTTP headers from the protobuf body; honour Content-Length if present.
        uint8_t *hdrend = NULL;
        for (size_t k = 0; k + 3 < blen; k++)
            if (body[k]=='\r'&&body[k+1]=='\n'&&body[k+2]=='\r'&&body[k+3]=='\n') { hdrend = body + k + 4; break; }
        char status[64] = ""; { int i=0; while (i<(int)blen && body[i]!='\r' && i<62) { status[i]=body[i]; i++; } status[i]=0; }
        if (hdrend) {
            size_t paylen = blen - (hdrend - body);
            reply_job *job = calloc(1, sizeof *job);
            job->rpcId = pa->rpcId; job->count = pa->count;
            parse_returns(hdrend, (int)paylen, job);
            HLOG("POST #%d -> %{public}s body=%zuB returns=%d", pa->rpcId, status, paylen, job->n);
            // Deliver on the il2cpp main thread.
            dispatch_async(dispatch_get_main_queue(), ^{ ws_deliver(job); });
        } else {
            HLOG("POST #%d -> %{public}s (no body)", pa->rpcId, status);
        }
    } else {
        HLOG("POST #%d -> no response", pa->rpcId);
    }

    free(body);
    free(env->p); free(pa);
    return NULL;
}

// ---- N2ServerSend_ hook: build plain envelope, POST it ----
typedef int32_t (*n2send_fn)(void *, int32_t, int32_t, int32_t, void *, uint8_t *, void *, int32_t *);
static n2send_fn g_orig_send;
static int g_rpc_id = 1;

static int32_t my_n2_send(void *target, int32_t timeoutMs, int32_t retryMs,
                          int32_t count, void *methods, uint8_t *bodies,
                          void *sizes, int32_t *out_result) {
    int rpcId = g_rpc_id++;
    char dbg[256]; int doff = 0;
    post_arg *pa = calloc(1, sizeof *pa);
    pa->rpcId = rpcId; pa->count = count;
    buf_t *env = &pa->env;
    bvarfield(env, 3, (uint64_t)rpcId);                 // RequestEnvelope.request_id
    size_t off = 0;
    for (int i = 0; i < count; i++) {
        int32_t m = arr_i32(methods, i);
        int32_t s = arr_i32(sizes, i);
        if (s < 0) s = 0;
        // field 4 (repeated Request) = { 1: method, 2: body }
        buf_t req = {0};
        bvarfield(&req, 1, (uint64_t)(uint32_t)m);
        if (s > 0) bbytes(&req, 2, bodies + off, (size_t)s);
        bbytes(env, 4, req.p, req.len);
        free(req.p);
        off += (size_t)s;
        if (doff < 200) doff += snprintf(dbg + doff, sizeof(dbg) - doff, "%s%d:%d", i ? "," : "", m, s);
    }
    if (g_token_len > 0) {
        // field 10 AuthInfo = { 1: "ptc", 2: { 1: token } }
        buf_t tok = {0}; bbytes(&tok, 1, g_token, (size_t)g_token_len);
        buf_t ai = {0}; bbytes(&ai, 1, "ptc", 3); bbytes(&ai, 2, tok.p, tok.len);
        bbytes(env, 10, ai.p, ai.len);
        free(tok.p); free(ai.p);
    }
    HLOG("Send #%d count=%d [%{public}s] token=%d env=%zuB", rpcId, count, dbg, g_token_len, env->len);
    if (out_result) *out_result = rpcId;
    pthread_t th; if (pthread_create(&th, NULL, post_thread, pa) == 0) pthread_detach(th);
    else { free(env->p); free(pa); }
    return 0;  // ApiError.Success
}

// ---- N2ServerRefreshAuthToken_ hook: capture the PTC ticket ----
typedef int32_t (*n2refresh_fn)(void *, void *, void *, int32_t);
static n2refresh_fn g_orig_refresh, g_orig_reset;

static void capture_token(void *token, int32_t tokenSize, const char *src) {
    if (token && tokenSize > 0) {
        const uint8_t *data = (const uint8_t *)token + IL2CPP_ARRAY_DATA;
        const uint8_t *tk; int tl;
        if (pb_find_field1_str(data, tokenSize, &tk, &tl) && tl > 0 && tl < (int)sizeof g_token) {
            memcpy(g_token, tk, tl); g_token_len = tl;
            HLOG("auth token captured via %{public}s (%d chars)", src, tl);
        }
    }
}
static int32_t my_n2_refresh(void *target, void *authId, void *token, int32_t tokenSize) {
    capture_token(token, tokenSize, "refresh");
    return g_orig_refresh(target, authId, token, tokenSize);
}
static int32_t my_n2_reset(void *target, void *authId, void *token, int32_t tokenSize) {
    capture_token(token, tokenSize, "reset");
    return g_orig_reset(target, authId, token, tokenSize);
}

// ---- install ----
static void *deleg_at(void *sf, uint32_t off) {
    void *d = *(void **)((uint8_t *)sf + off);
    return ws_ptr_sane(d) ? d : NULL;
}
static int g_tries;
static void ws_il2_try(void) {
    if (!g_base) return;
    void *klass = *(void **)(g_base + SLOT_N2EP_CLASS);
    void *sf = ws_ptr_sane(klass) ? *(void **)((uint8_t *)klass + CLASS_STATICFIELDS_OFF) : NULL;
    void *send = ws_ptr_sane(sf) ? deleg_at(sf, SEND_DELEGATE_STATIC_OFF) : NULL;
    if (send) {
        void *refresh = deleg_at(sf, REFRESH_DELEGATE_STATIC_OFF);
        void **smp = (void **)((uint8_t *)send + DELEGATE_METHODPTR_OFF);
        g_orig_send = (n2send_fn)(*smp);
        *smp = (void *)my_n2_send;
        if (refresh) {
            void **rmp = (void **)((uint8_t *)refresh + DELEGATE_METHODPTR_OFF);
            g_orig_refresh = (n2refresh_fn)(*rmp);
            *rmp = (void *)my_n2_refresh;
        }
        void *reset = deleg_at(sf, RESET_DELEGATE_STATIC_OFF);
        if (reset) {
            void **rmp = (void **)((uint8_t *)reset + DELEGATE_METHODPTR_OFF);
            g_orig_reset = (n2refresh_fn)(*rmp);
            *rmp = (void *)my_n2_reset;
        }
        HLOG("installed: send=%p refresh=%p reset=%p server=%{public}s",
             send, refresh, reset, g_server);
        return;
    }
    if (g_tries++ < 240)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ ws_il2_try(); });
    else
        HLOG("gave up: klass=%p sf=%p", klass, sf);
}

void ws_il2_init(const char *server) {
    if (server && *server) strlcpy(g_server, server, sizeof g_server);
    g_base = ws_guest_base(&g_text_vmsize);
    HLOG("guest base=%p text=%zuMB server=%{public}s", (void *)g_base, g_text_vmsize >> 20, g_server);
    ws_il2_try();
}
