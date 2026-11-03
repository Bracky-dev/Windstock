// WSShop.m -- Windstock's in-game shop for the 0.67 iOS guest, as its own LiveContainer tweak.
//
// Independent of WSTweak.dylib (load it alongside, or on its own once the RPC redirect is
// otherwise working). Jitless: it never patches code, only overwrites the method_ptr of the
// static N2Iap* delegates in N2EntryPoints (data writes). The shop list and purchases go to
// the server as request 9071 / 9072 in the normal RPC envelope. The PTC auth ticket is
// captured by chaining onto N2ServerRefresh/ResetAuthToken_ (safe next to WSTweak's own wrap).
//
// Server address: baked (@SERVER@), override with env WS_SERVER or <guest Documents>/ws_server.txt.
// Offsets are VA-offsets of the 0.67.2 arm64 binary.
//
// Verified against an Il2CppDumper dump of that binary (2026-11-01):
//   * 0x3a60d18 holds the N2EntryPoints Il2CppClass*, its static_fields at +0x98,
//     and n2Api (the N2Api struct) at static_fields+0x190. So the IAP delegates sit
//     at 0x2e0 (GetIapState), 0x2e8 (GetPurchaseResult), 0x2f0 (GetSkusAndBalances),
//     0x2f8 (Initialize), 0x300 (ProcessEvents), 0x308 (PurchaseItem), 0x310
//     (RefreshSkusAndBalances) -- N2Api fields 0x150..0x180 plus that 0x190 base.
//   * A delegate's Invoke does `br [delegate+0x10]` (method_ptr) with x0 = target
//     (0 for these static wrappers), then the declared args, then MethodInfo last,
//     which is the signature these replacements use.
//   * The native structs the managed callbacks marshal out of are StoreItem
//     {char* sku; char* localCurrencyPrice; int isVendorItem; int canBePurchased;},
//     Balance {char* currency_type; int amount;}, PresentationData {char* key;
//     char* value;}, ItemQuantity {char* item; int quantity;} -- matched below.

#import <Foundation/Foundation.h>
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

#define HLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[WSShop] " fmt, ##__VA_ARGS__)

#define SLOT_N2EP_CLASS            0x3a60d18
#define CLASS_STATICFIELDS_OFF     0x98
#define REFRESH_DELEGATE_STATIC_OFF 0x290
#define RESET_DELEGATE_STATIC_OFF   0x298
#define SEND_DELEGATE_STATIC_OFF   0x2a0
#define DELEGATE_METHODPTR_OFF     0x10
#define IL2CPP_ARRAY_DATA          0x20
#define MAX_PAYLOADS 64
#define WS_DEFAULT_SERVER "@SERVER@"

static uintptr_t g_base;
static char      g_server[64] = WS_DEFAULT_SERVER;
static char      g_token[512];
static int       g_token_len;
static int       g_rpc_id = 900000;     // far from WSTweak's counter


// One-shot GET the server access log shows (device syslog is unavailable in LiveContainer).
static void ws_dbg(const char *tag, long a, long b) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;
    struct timeval tv = { 1, 0 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    struct sockaddr_in sa; memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET; sa.sin_port = htons(80);
    inet_pton(AF_INET, g_server, &sa.sin_addr);
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) == 0) {
        char req[256];
        int n = snprintf(req, sizeof req, "GET /wsdbg?t=shop_%s&a=%ld&b=%ld HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", tag, a, b);
        write(fd, req, n);
    }
    close(fd);
}

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
static uintptr_t ws_guest_base(void) {
    uint32_t n = _dyld_image_count();
    uintptr_t best = 0; size_t best_text = 0;
    for (uint32_t i = 0; i < n; i++) {
        const struct mach_header *h = _dyld_get_image_header(i);
        const char *nm = _dyld_get_image_name(i);
        if (!h) continue;
        size_t tvs = ws_image_text_vmsize(h);
        int is_lc = nm && (__builtin_strstr(nm, "LiveContainer") || __builtin_strstr(nm, "livecontainer"));
        int is_guest = nm && (__builtin_strstr(nm, "pokemongo") || __builtin_strstr(nm, "pokemon"));
        if (is_guest && !is_lc) return (uintptr_t)h;
        if (!is_lc && tvs > best_text) { best_text = tvs; best = (uintptr_t)h; }
    }
    return best;
}
static int ws_ptr_sane(void *p) {
    uintptr_t v = (uintptr_t)p;
    return v >= 0x100000000ULL && v < 0x800000000000ULL && (v & 7) == 0;
}

typedef struct { int n; uint8_t *data[MAX_PAYLOADS]; int len[MAX_PAYLOADS]; } reply_job;
// Collect every field-100 (wire 2) value of a ResponseEnvelope.
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

// ---- shop: Windstock's own IAP (replaces the native N2Iap* entry points) ----
// 0.67's shop is IapManager -> IapBindings -> N2Iap* native functions that talk to
// Niantic's store and never answer here. Same trick as N2ServerSend_: overwrite the
// method_ptr of the static N2Iap* delegates (data write, no JIT). The list and the
// purchases come from the server as request 9071 / 9072 in the normal RPC envelope.
#define IAP_GETSTATE_STATIC_OFF    0x2e0   // n2Api (0x190) + N2IapGetIapState (0x150)
#define IAP_GETRESULT_STATIC_OFF   0x2e8
#define IAP_GETSKUS_STATIC_OFF     0x2f0
#define IAP_INIT_STATIC_OFF        0x2f8
#define IAP_PROCESS_STATIC_OFF     0x300
#define IAP_PURCHASE_STATIC_OFF    0x308
#define IAP_REFRESH_STATIC_OFF     0x310
#define SHOP_LIST_RPC 9071
#define SHOP_BUY_RPC  9072
enum { IAP_READY = 3, IAP_BUSY = 2, IAP_REFRESHING = 4 };
enum { BUY_NONE = 1, BUY_FAILURE = 2, BUY_TOO_LOW = 3, BUY_IN_PROGRESS = 5, BUY_SUCCESS = 6 };
#define MAX_SHOP_ITEMS 64

typedef struct { char sku[96], item[64], category[24]; int price, count, sort; } shop_item;
static struct { shop_item items[MAX_SHOP_ITEMS]; int n, coins, stardust; } g_shop;
static volatile int32_t g_iap_state = IAP_READY, g_iap_result = BUY_NONE;
static volatile int32_t g_iap_event, g_iap_busy;     // event pending / worker running

// Blocking: POST one request, return a malloc'd copy of the first field-100 payload.
static int ws_rpc_call(int method, const uint8_t *body, size_t blen, uint8_t **out, int *outlen) {
    buf_t env = {0}, req = {0};
    bvarfield(&env, 3, (uint64_t)g_rpc_id++);
    bvarfield(&req, 1, (uint64_t)method);
    if (blen) bbytes(&req, 2, body, blen);
    bbytes(&env, 4, req.p, req.len);
    free(req.p);
    if (g_token_len > 0) {
        buf_t tok = {0}; bbytes(&tok, 1, g_token, (size_t)g_token_len);
        buf_t ai = {0}; bbytes(&ai, 1, "ptc", 3); bbytes(&ai, 2, tok.p, tok.len);
        bbytes(&env, 10, ai.p, ai.len);
        free(tok.p); free(ai.p);
    }
    uint8_t *resp = NULL; size_t rlen = 0, rcap = 0;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd >= 0) {
        struct timeval tv = { 5, 0 };
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        struct sockaddr_in sa; memset(&sa, 0, sizeof sa);
        sa.sin_family = AF_INET; sa.sin_port = htons(80);
        inet_pton(AF_INET, g_server, &sa.sin_addr);
        if (connect(fd, (struct sockaddr *)&sa, sizeof sa) == 0) {
            char head[256];
            int hn = snprintf(head, sizeof head,
                "POST /plfe/0/rpc HTTP/1.1\r\nHost: pgorelease.nianticlabs.com\r\n"
                "Content-Type: application/x-protobuf\r\nContent-Length: %zu\r\n"
                "Connection: close\r\n\r\n", env.len);
            write(fd, head, hn); write(fd, env.p, env.len);
            uint8_t chunk[4096]; ssize_t r;
            while ((r = read(fd, chunk, sizeof chunk)) > 0) {
                if (rlen + r > rcap) { rcap = rcap ? rcap * 2 : 8192; while (rcap < rlen + r) rcap *= 2; resp = realloc(resp, rcap); }
                memcpy(resp + rlen, chunk, r); rlen += r;
            }
        }
        close(fd);
    }
    free(env.p);
    int ok = 0;
    if (resp && rlen) {
        uint8_t *he = NULL;
        for (size_t k = 0; k + 3 < rlen; k++)
            if (resp[k]=='\r'&&resp[k+1]=='\n'&&resp[k+2]=='\r'&&resp[k+3]=='\n') { he = resp + k + 4; break; }
        if (he) {
            reply_job job; memset(&job, 0, sizeof job);
            parse_returns(he, (int)(rlen - (he - resp)), &job);
            if (job.n > 0) {
                *out = job.data[0]; *outlen = job.len[0]; ok = 1;
                for (int i = 1; i < job.n; i++) free(job.data[i]);
            }
        }
    }
    free(resp);
    return ok;
}

// Minimal protobuf walker: next field of a message. Returns 0 at the end.
typedef struct { const uint8_t *p; int n, i; } pbr;
static int pbr_next(pbr *r, int *field, uint64_t *v, const uint8_t **d, int *dl) {
    if (r->i >= r->n) return 0;
    uint64_t tag = 0; int sh = 0;
    while (r->i < r->n) { uint8_t b = r->p[r->i++]; tag |= (uint64_t)(b & 0x7f) << sh; sh += 7; if (!(b & 0x80)) break; }
    *field = (int)(tag >> 3); *d = NULL; *dl = 0; *v = 0;
    int wire = tag & 7;
    if (wire == 0 || wire == 2) {
        uint64_t x = 0; sh = 0;
        while (r->i < r->n) { uint8_t b = r->p[r->i++]; x |= (uint64_t)(b & 0x7f) << sh; sh += 7; if (!(b & 0x80)) break; }
        if (wire == 0) { *v = x; return 1; }
        if (r->i + (int)x > r->n) return 0;
        *d = r->p + r->i; *dl = (int)x; r->i += (int)x; return 1;
    }
    if (wire == 5) { r->i += 4; return 1; }
    if (wire == 1) { r->i += 8; return 1; }
    return 0;
}
static void cpystr(char *dst, size_t cap, const uint8_t *s, int n) {
    if (n >= (int)cap) n = (int)cap - 1;
    memcpy(dst, s, n); dst[n] = 0;
}

static void shop_fetch_list(void) {
    uint8_t *b = NULL; int bl = 0;
    if (!ws_rpc_call(SHOP_LIST_RPC, NULL, 0, &b, &bl)) { HLOG("shop: list failed"); ws_dbg("listfail", g_token_len, 0); return; }
    typeof(g_shop) *cat = calloc(1, sizeof *cat);
    pbr r = { b, bl, 0 }; int f; uint64_t v; const uint8_t *d; int dl;
    while (pbr_next(&r, &f, &v, &d, &dl)) {
        if (f == 1 && d && cat->n < MAX_SHOP_ITEMS) {
            shop_item *it = &cat->items[cat->n++];
            pbr q = { d, dl, 0 }; int qf; uint64_t qv; const uint8_t *qd; int qdl;
            while (pbr_next(&q, &qf, &qv, &qd, &qdl)) {
                if (qf == 1 && qd) cpystr(it->sku, sizeof it->sku, qd, qdl);
                else if (qf == 2) it->price = (int)qv;
                else if (qf == 3 && qd) cpystr(it->item, sizeof it->item, qd, qdl);
                else if (qf == 4) it->count = (int)qv;
                else if (qf == 5 && qd) cpystr(it->category, sizeof it->category, qd, qdl);
                else if (qf == 6) it->sort = (int)qv;
            }
        } else if (f == 7) cat->coins = (int)v;
        else if (f == 8) cat->stardust = (int)v;
    }
    memcpy(&g_shop, cat, sizeof g_shop);
    HLOG("shop: %d items, %d coins", cat->n, cat->coins);
    ws_dbg("list", cat->n, cat->coins);
    free(cat); free(b);
}

static void *shop_refresh_thread(void *arg) {
    shop_fetch_list();
    g_iap_state = IAP_READY;
    __atomic_store_n(&g_iap_event, 1, __ATOMIC_RELEASE);
    __atomic_store_n(&g_iap_busy, 0, __ATOMIC_RELEASE);
    return NULL;
}
static void shop_start_refresh(void) {
    if (__atomic_exchange_n(&g_iap_busy, 1, __ATOMIC_ACQ_REL)) return;
    g_iap_state = IAP_REFRESHING;
    pthread_t th;
    if (pthread_create(&th, NULL, shop_refresh_thread, NULL) == 0) pthread_detach(th);
    else __atomic_store_n(&g_iap_busy, 0, __ATOMIC_RELEASE);
}

static void *shop_buy_thread(void *arg) {
    char *sku = arg; buf_t b = {0};
    bbytes(&b, 1, sku, strlen(sku));
    uint8_t *r = NULL; int rl = 0; int res = BUY_FAILURE;
    if (ws_rpc_call(SHOP_BUY_RPC, b.p, b.len, &r, &rl)) {
        pbr q = { r, rl, 0 }; int f; uint64_t v; const uint8_t *d; int dl; int ok = 0; char why[64] = "";
        while (pbr_next(&q, &f, &v, &d, &dl)) {
            if (f == 1) ok = (int)v;
            else if (f == 2 && d) cpystr(why, sizeof why, d, dl);
        }
        res = ok ? BUY_SUCCESS : (strncmp(why, "need ", 5) == 0 ? BUY_TOO_LOW : BUY_FAILURE);
        HLOG("shop: buy %{public}s -> %{public}s %{public}s", sku, ok ? "ok" : "refused", why);
        free(r);
    } else HLOG("shop: buy %{public}s failed (no reply)", sku);
    free(b.p); free(sku);
    g_iap_result = res;
    __atomic_store_n(&g_iap_busy, 0, __ATOMIC_RELEASE);
    shop_start_refresh();
    return NULL;
}

// --- replacement N2Iap* delegates (managed calling convention: target first, MethodInfo last)
static int32_t my_iap_getstate(void *t, int32_t *out, void *mi)  { ws_dbg("getstate",0,0); if (out) *out = g_iap_state; return 0; }
static int32_t my_iap_getresult(void *t, int32_t *out, void *mi) { ws_dbg("getresult",0,0); if (out) *out = g_iap_result; return 0; }
static int32_t my_iap_init(void *t, void *mi)                    { ws_dbg("init",0,0); shop_start_refresh(); return 0; }
static int32_t my_iap_refresh(void *t, void *mi)                 { ws_dbg("refresh",0,0); shop_start_refresh(); return 0; }

typedef void (*cb1_fn)(void *);
typedef void (*evcb_fn)(int32_t, void *);
static int32_t my_iap_process(void *t, void *cb, int32_t *left, void *mi) {
    if (left) *left = 0;
    { static int c; if (c++ < 3) ws_dbg("process", c, g_iap_event); }
    if (cb && __atomic_exchange_n(&g_iap_event, 0, __ATOMIC_ACQ_REL)) {
        static uint8_t params[64];
        memset(params, 0, sizeof params);
        ((evcb_fn)cb)(0 /* STORE_REFRESH */, params);
    }
    return 0;
}

typedef struct { const char *a; const char *b; } sv_pair;       // StoreItem / PresentationData shape
static int32_t my_iap_getskus(void *t, void *storeCb, void *balCb, void *priceCb, void *grantedCb,
                              void *presCb, void *qtyCb, void *mi) {
    // The screen asks for the list ONCE, here. A background refresh raced it the
    // first time it was opened (empty shelves, then a refresh event nobody used),
    // so when the catalogue is still empty and we already hold the auth ticket,
    // fetch it inline. Costs one blocking round trip on the first draw only.
    if (g_shop.n == 0 && g_token_len > 0 && !g_iap_busy) shop_fetch_list();
    if (g_shop.n == 0) ws_dbg(g_token_len > 0 ? "getskus_empty" : "getskus_notoken", 0, 0);
    ws_dbg("getskus", g_shop.n, g_shop.coins);
    struct { const char *k; int32_t v; } bal;
    if (balCb) {
        bal.k = "POKECOIN";  bal.v = g_shop.coins;     ((cb1_fn)balCb)(&bal);
        bal.k = "STARDUST";  bal.v = g_shop.stardust;  ((cb1_fn)balCb)(&bal);
    }
    for (int i = 0; i < g_shop.n; i++) {
        shop_item *it = &g_shop.items[i];
        struct { const char *sku, *price; int32_t vendor, can; } si = { it->sku, "", 0, 1 };
        if (storeCb) ((cb1_fn)storeCb)(&si);
        bal.k = "POKECOIN"; bal.v = it->price;
        if (priceCb) ((cb1_fn)priceCb)(&bal);
        char sortbuf[16]; snprintf(sortbuf, sizeof sortbuf, "%d", it->sort);
        sv_pair pd = { "CATEGORY", it->category };
        if (presCb) ((cb1_fn)presCb)(&pd);
        sv_pair ps = { "SORT", sortbuf };
        if (presCb) ((cb1_fn)presCb)(&ps);
        struct { const char *item; int32_t q; } iq = { it->item, it->count };
        if (qtyCb) ((cb1_fn)qtyCb)(&iq);
    }
    return 0;
}

static int32_t my_iap_purchase(void *t, void *str, void *mi) {
    ws_dbg("purchase",0,0);
    char *sku = calloc(1, 128);
    if (ws_ptr_sane(str)) {
        int32_t len = *(int32_t *)((uint8_t *)str + 0x10);
        const uint16_t *ch = (const uint16_t *)((uint8_t *)str + 0x14);
        for (int i = 0; i < len && i < 127; i++) sku[i] = (char)ch[i];
    }
    g_iap_state = IAP_BUSY; g_iap_result = BUY_IN_PROGRESS;
    __atomic_store_n(&g_iap_busy, 1, __ATOMIC_RELEASE);
    pthread_t th;
    if (pthread_create(&th, NULL, shop_buy_thread, sku) == 0) pthread_detach(th);
    else { free(sku); g_iap_result = BUY_FAILURE; g_iap_state = IAP_READY; __atomic_store_n(&g_iap_busy, 0, __ATOMIC_RELEASE); }
    return 0;
}

// One hook per IAP delegate. The delegates are created together by LoadApiBindings,
// but they are only ASSIGNED when N2Api is filled, and a single "missing" used to
// end the install for good (silent empty shop), so each one is retried on its own
// until it lands.
typedef struct { uint32_t off; void *fn; const char *name; } hook_spec;
static const hook_spec g_iap_hooks[] = {
    { IAP_GETSTATE_STATIC_OFF,  (void *)my_iap_getstate,  "GetIapState" },
    { IAP_GETRESULT_STATIC_OFF, (void *)my_iap_getresult, "GetPurchaseResult" },
    { IAP_GETSKUS_STATIC_OFF,   (void *)my_iap_getskus,   "GetSkusAndBalances" },
    { IAP_INIT_STATIC_OFF,      (void *)my_iap_init,      "Initialize" },
    { IAP_PROCESS_STATIC_OFF,   (void *)my_iap_process,   "ProcessEvents" },
    { IAP_PURCHASE_STATIC_OFF,  (void *)my_iap_purchase,  "PurchaseItem" },
    { IAP_REFRESH_STATIC_OFF,   (void *)my_iap_refresh,   "RefreshSkusAndBalances" },
};
#define N_IAP_HOOKS ((int)(sizeof g_iap_hooks / sizeof g_iap_hooks[0]))
static int g_hooked;                       // bit i = g_iap_hooks[i] installed

// Returns 1 if this one is (now) hooked.
static int hook_one(void *sf, int i) {
    if (g_hooked & (1 << i)) return 1;
    const hook_spec *h = &g_iap_hooks[i];
    void *d = *(void **)((uint8_t *)sf + h->off);
    if (!ws_ptr_sane(d)) return 0;
    *(void **)((uint8_t *)d + DELEGATE_METHODPTR_OFF) = h->fn;
    g_hooked |= 1 << i;
    HLOG("shop: hooked %{public}s", h->name);
    ws_dbg("hook", i, 0);
    return 1;
}

static int ws_shop_install(void *sf) {
    int n = 0;
    for (int i = 0; i < N_IAP_HOOKS; i++) n += hook_one(sf, i);
    if (n == N_IAP_HOOKS)
        HLOG("shop: N2Iap* replaced (list %d, buy %d)", SHOP_LIST_RPC, SHOP_BUY_RPC);
    return n;
}


// ---- auth ticket capture: chain onto the refresh/reset delegates ----
typedef int32_t (*n2refresh_fn)(void *, void *, void *, int32_t);
static n2refresh_fn g_orig_refresh, g_orig_reset;
static void capture_token(void *token, int32_t tokenSize) {
    if (token && tokenSize > 0) {
        const uint8_t *tk; int tl;
        if (pb_find_field1_str((const uint8_t *)token + IL2CPP_ARRAY_DATA, tokenSize, &tk, &tl)
            && tl > 0 && tl < (int)sizeof g_token) {
            memcpy(g_token, tk, tl); g_token_len = tl;
            HLOG("auth token captured (%d chars)", tl);
            ws_dbg("token", tl, 0);
        }
    }
}
static int32_t my_n2_refresh(void *t, void *a, void *tok, int32_t n) {
    capture_token(tok, n);
    return g_orig_refresh ? g_orig_refresh(t, a, tok, n) : 0;
}
static int32_t my_n2_reset(void *t, void *a, void *tok, int32_t n) {
    capture_token(tok, n);
    return g_orig_reset ? g_orig_reset(t, a, tok, n) : 0;
}

// ---- install: poll until the N2 delegates exist (post-login), then hook ----
// N2Api (static field 0x190 of N2EntryPoints) is filled once by LoadApiBindings;
// the auth-token delegates and the IAP delegates are part of the same struct, but
// they are checked separately so one missing field cannot stop the others.
static int g_tries, g_auth_hooked;
static void ws_shop_try(void) {
    if (!g_base) return;
    void *klass = *(void **)(g_base + SLOT_N2EP_CLASS);
    void *sf = ws_ptr_sane(klass) ? *(void **)((uint8_t *)klass + CLASS_STATICFIELDS_OFF) : NULL;
    if (ws_ptr_sane(sf)) {
        // Each token delegate is picked up on its own: the send delegate being
        // absent must not stop us from getting an auth ticket.
        int auth = 0;
        if (!g_orig_refresh) {
            void *rf = *(void **)((uint8_t *)sf + REFRESH_DELEGATE_STATIC_OFF);
            if (ws_ptr_sane(rf)) {
                void **mp = (void **)((uint8_t *)rf + DELEGATE_METHODPTR_OFF);
                g_orig_refresh = (n2refresh_fn)*mp; *mp = (void *)my_n2_refresh;
                auth = 1;
            }
        } else auth++;
        if (!g_orig_reset) {
            void *rs = *(void **)((uint8_t *)sf + RESET_DELEGATE_STATIC_OFF);
            if (ws_ptr_sane(rs)) {
                void **mp = (void **)((uint8_t *)rs + DELEGATE_METHODPTR_OFF);
                g_orig_reset = (n2refresh_fn)*mp; *mp = (void *)my_n2_reset;
                auth = 1;
            }
        } else auth++;
        g_auth_hooked = (auth == 2);
        if (ws_shop_install(sf) == N_IAP_HOOKS) {
            ws_dbg("installed", g_tries, g_token_len);
            HLOG("installed, server=%{public}s", g_server);
            return;
        }
    }
    if (g_tries++ < 240)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ ws_shop_try(); });
    else
        { HLOG("gave up: klass=%p sf=%p hooked=%d", klass, sf, g_hooked);
          ws_dbg("gaveup", g_hooked, (long)(uintptr_t)sf); }
}

__attribute__((constructor))
static void ws_shop_init(void) {
    @autoreleasepool {
        NSString *host = nil;
        const char *env = getenv("WS_SERVER");
        if (env && *env) host = @(env);
        else {
            NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            host = [NSString stringWithContentsOfFile:[docs stringByAppendingPathComponent:@"ws_server.txt"]
                                             encoding:NSUTF8StringEncoding error:NULL];
        }
        host = [host stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (host.length) strlcpy(g_server, host.UTF8String, sizeof g_server);
        g_base = ws_guest_base();
        ws_dbg("loaded", (long)(g_base & 0xffffffff), 0);
        HLOG("guest base=%p server=%{public}s", (void *)g_base, g_server);
        ws_shop_try();
    }
}
