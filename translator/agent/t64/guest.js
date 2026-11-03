// translator64: the 32-bit game runs translated inside a 64-bit app, so this agent (64-bit
// Frida) can't touch it directly. This module bends Frida's native API so the agent code
// written for the native 32-bit game keeps working.
//
// The game's whole 4 GB address space is one window in this process (libwst64's g_base).
// Every game pointer the agent sees is in HOST form, window base + guest address, so ordinary
// reads and writes just work; only the edges convert:
//
//   * readPointer/writePointer inside the window are 32-bit (the game's pointer size);
//   * NativeFunction on a window address calls the game (wst_gcall), Hook.attach/replace
//     there patch game code (wst_ghook); register values come back in host form too (with
//     toInt32/toUInt32 still giving the raw number, for int arguments);
//   * WstGuest.alloc/str hand out game memory (for things the game will read).
//
// Nothing outside the window is touched: Frida's Java bridge (ART's heap is below 4 GB too)
// and everything host keeps native behaviour.

globalThis.WST_T64 = true;

/** Replace a built-in (plain assignment, or redefine when Frida made it read-only). */
function over(obj, name, value) {
    try { obj[name] = value; } catch (_) {}
    if (obj[name] === value) return;
    try { Object.defineProperty(obj, name, { value, writable: true, configurable: true, enumerable: false }); } catch (e) {
        console.log("[windstock] t64: can't override " + name + ": " + e);
    }
}

const LIB = "libwst64.so";
const HostNF = globalThis.NativeFunction;
const HostNC = globalThis.NativeCallback;

const nf = (n, r, a) => new HostNF(Process.getModuleByName(LIB).getExportByName(n), r, a);
const _base = nf("wst_gbase", "pointer", [])();
const _call = nf("wst_gcall", "uint64", ["uint32", "pointer", "int"]);
const _sym = nf("wst_gsym", "uint32", ["pointer", "pointer"]);
const _module = nf("wst_gmodule", "int", ["pointer", "pointer", "pointer"]);
const _alloc = nf("wst_galloc", "uint32", ["uint32"]);
const _free = nf("wst_gfree", "void", ["uint32"]);
const _hook = nf("wst_ghook", "int", ["uint32", "pointer", "int"]);
const _orig = nf("wst_ghook_orig", "uint32", ["int"]);
const _unhook = nf("wst_gunhook", "void", ["int"]);
const hostMalloc = new HostNF(Module.getExportByName(null, "malloc"), "pointer", ["size_t"]);

const END = _base.add(ptr("0x100000000"));
export const base = _base;

/** Inside the game's window? */
export function isGuest(p) {
    return p instanceof NativePointer && p.compare(_base) >= 0 && p.compare(END) < 0;
}
/** A guest address (number) -> host form (null stays null). */
export const G = (v) => ((v >>> 0) === 0 ? ptr(0) : _base.add(v >>> 0));
/** Any pointer/number -> the game's 32-bit value. Small non-window values are plain numbers. */
export function toGuest(p) {
    if (p === null || p === undefined) return 0;
    if (typeof p === "number") return p >>> 0;
    if (typeof p === "boolean") return p ? 1 : 0;
    if (!(p instanceof NativePointer)) {
        if (p.handle instanceof NativePointer) p = p.handle;
        else p = ptr(p);
    }
    if (p.isNull()) return 0;
    if (isGuest(p)) return p.sub(_base).toUInt32();
    if (p.compare(ptr("0x100000000")) < 0) return p.toUInt32();     // an int passed as a pointer
    throw new Error("host pointer " + p + " handed to the game");
}
export const toHost = (p) => p;

/** A register value as a pointer: host form, but toInt32/toUInt32 give the raw number. */
export function regPtr(v) {
    v >>>= 0;
    if (v === 0) return ptr(0);
    const p = _base.add(v);
    try {
        p.toInt32 = () => v | 0;
        p.toUInt32 = () => v;
    } catch (_) {}
    return p;
}

// ---------------------------------------------------------------- memory
const P = NativePointer.prototype;
const hostReadPointer = P.readPointer, hostWritePointer = P.writePointer;
P.readPointer = function () {
    if (isGuest(this)) return G(this.readU32());
    return hostReadPointer.call(this);
};
P.writePointer = function (v) {
    if (isGuest(this)) { this.writeU32(toGuest(v)); return this; }
    hostWritePointer.call(this, v);
    return this;
};

/** Game memory, freed when the returned pointer is garbage-collected. */
export function galloc(n) {
    const g = _alloc(Math.max(1, n | 0));
    const p = G(g);
    Script.bindWeak(p, () => _free(g));
    return p;
}
export const gfree = (p) => _free(toGuest(p));

/** A NUL-terminated UTF-8 copy in game memory (freed with the pointer). */
export function gstr(s) {
    const p = galloc(utf8len(String(s)) + 1);
    p.writeUtf8String(String(s));
    return p;
}
const utf8len = (s) => unescape(encodeURIComponent(s)).length;

function hostStr(s) {
    s = String(s);
    const b = hostMalloc(utf8len(s) + 1);
    Script.bindWeak(b, () => {});      // (tiny, few: module/symbol names)
    b.writeUtf8String(s);
    return b;
}

// ---------------------------------------------------------------- calls into the game
const argWords = hostMalloc(4 * 64);
const f32 = new Float32Array(1), u32v = new Uint32Array(f32.buffer);
const f64 = new Float64Array(1), u32d = new Uint32Array(f64.buffer);
export const floatBits = (x) => { f32[0] = x; return u32v[0]; };
export const bitsFloat = (b) => { u32v[0] = b >>> 0; return f32[0]; };
const doubleWords = (x) => { f64[0] = x; return [u32d[0], u32d[1]]; };
const wordsDouble = (lo, hi) => { u32d[0] = lo >>> 0; u32d[1] = hi >>> 0; return f64[0]; };
const toU64 = (v) => (v instanceof Int64 || v instanceof UInt64) ? uint64(v.toString()) : uint64(Math.trunc(Number(v)));

/** The 32-bit words a value of Frida type `t` occupies in the game's ABI (softfp). */
export function wordsOf(t, v, words) {
    if (Array.isArray(t)) {                       // struct by value: its members in order
        for (let i = 0; i < t.length; i++) wordsOf(t[i], v[i], words);
        return;
    }
    switch (t) {
        case "double": { if (words.length & 1) words.push(0); words.push(...doubleWords(Number(v))); return; }
        case "int64": case "uint64": case "long": case "ulong": {
            if (words.length & 1) words.push(0);
            const u = toU64(v);
            words.push(u.and(0xffffffff).toNumber() >>> 0, u.shr(32).and(0xffffffff).toNumber() >>> 0);
            return;
        }
        case "float": words.push(floatBits(Number(v))); return;
        case "pointer": words.push(toGuest(v)); return;
        case "bool": words.push(v ? 1 : 0); return;
        default: words.push((typeof v === "boolean" ? +v : Number(v)) >>> 0); return;
    }
}

/** r0/r1 -> a value of Frida type `t`. */
export function fromWords(t, lo, hi) {
    switch (t) {
        case "void": return undefined;
        case "pointer": return regPtr(lo);
        case "float": return bitsFloat(lo);
        case "double": return wordsDouble(lo, hi);
        case "bool": return (lo & 0xff) !== 0 ? 1 : 0;
        case "int8": return (lo << 24) >> 24;
        case "uint8": return lo & 0xff;
        case "int16": return (lo << 16) >> 16;
        case "uint16": return lo & 0xffff;
        case "uint": case "uint32": return lo >>> 0;
        case "int64": case "long": return int64(uint64(hi >>> 0).shl(32).or(lo >>> 0).toString());
        case "uint64": case "ulong": return uint64(hi >>> 0).shl(32).or(lo >>> 0);
        default: return lo | 0;
    }
}

/** Call game code at `fn` with raw 32-bit words; returns [r0, r1]. */
export function callWords(fn, words) {
    for (let i = 0; i < words.length; i++) argWords.add(4 * i).writeU32(words[i] >>> 0);
    const r = _call(toGuest(fn), argWords, words.length);
    return [r.and(0xffffffff).toNumber() >>> 0, r.shr(32).toNumber() >>> 0];
}

function guestFunction(addr, ret, args) {
    const fn = toGuest(addr);
    const f = function (...vals) {
        const words = [];
        for (let i = 0; i < args.length; i++) wordsOf(args[i], vals[i], words);
        const [lo, hi] = callWords(fn, words);
        return fromWords(ret, lo, hi);
    };
    f.address = G(fn);
    return f;
}

over(globalThis, "NativeFunction", function (addr, ret, args, opts) {
    const p = ptr(addr);
    if (isGuest(p)) return guestFunction(p, ret, args || []);
    return new HostNF(p, ret, args, opts);
});

// ---------------------------------------------------------------- hooks
// One native hook per game address (wst_ghook), any number of listeners on it, like Frida.
// The single host callback: (id, kind, regs*) -> 0 run original / 1 return now / 2 run the
// original and call back (kind 1) on its return. regs: r0..r15, cpsr (17 words, host memory).
const sites = new Map();          // guest address -> site
const byId = new Map();           // hook id -> site
const frames = new Map();         // thread id -> stack of pending returns

export function regsView(regs) {
    return {
        r: (i) => regs.add(4 * i).readU32(),
        set: (i, v) => regs.add(4 * i).writeU32(toGuest(v)),
        stack: (k) => _base.add(regs.add(4 * 13).readU32() + 4 * k),   // k-th stack word (host form)
    };
}

function makeArgs(rv) {
    return new Proxy([], {
        get(t, k) {
            if (typeof k === "string" && /^\d+$/.test(k)) {
                const i = +k;
                return regPtr(i < 4 ? rv.r(i) : rv.stack(i - 4).readU32());
            }
            return t[k];
        },
        set(t, k, v) {
            if (typeof k === "string" && /^\d+$/.test(k)) {
                const i = +k;
                if (i < 4) rv.set(i, v); else rv.stack(i - 4).writeU32(toGuest(v));
                return true;
            }
            t[k] = v;
            return true;
        },
    });
}

function makeContext(rv) {
    const c = { pc: regPtr(rv.r(15)), sp: regPtr(rv.r(13)), lr: regPtr(rv.r(14)) };
    for (let i = 0; i < 13; i++) c["r" + i] = regPtr(rv.r(i));
    return c;
}

function retval(rv) {
    const ret = regPtr(rv.r(0));
    const replace = (v) => rv.set(0, typeof v === "number" || typeof v === "boolean" ? (+v >>> 0) : v);
    try { ret.replace = replace; } catch (_) {}
    return ret.replace ? ret : Object.assign(Object.create(null), { replace, toInt32: () => rv.r(0) | 0 });
}

const report = (e) => console.log("[windstock] hook threw: " + (e && e.stack ? e.stack : e));

const dispatch = new HostNC((id, kind, regs) => {
    const S = byId.get(id);
    if (!S) return 0;
    const rv = regsView(regs);
    const tid = Process.getCurrentThreadId();
    if (kind === 1) {
        const st = frames.get(tid);
        const fr = st && st.length ? st.pop() : null;
        if (!fr) return 0;
        const ret = retval(rv);
        for (const [L, inv] of fr) { try { L.onLeave.call(inv, ret); } catch (e) { report(e); } }
        return 0;
    }
    const leaving = [];
    if (S.list.length) {
        const args = makeArgs(rv), ra = regPtr(rv.r(14));
        for (const L of S.list.slice()) {
            const inv = { context: makeContext(rv), returnAddress: ra, threadId: tid, depth: 0 };
            if (L.onEnter) { try { L.onEnter.call(inv, args); } catch (e) { report(e); } }
            if (L.onLeave) leaving.push([L, inv]);
        }
    }
    if (S.replace) {
        let done = false;
        try { done = S.replace(rv); } catch (e) { report(e); }
        if (done) {
            const ret = retval(rv);
            for (const [L, inv] of leaving) { try { L.onLeave.call(inv, ret); } catch (e) { report(e); } }
            return 1;
        }
    }
    if (!leaving.length) return 0;
    let st = frames.get(tid);
    if (!st) frames.set(tid, st = []);
    st.push(leaving);
    return 2;
}, "int", ["int", "int", "pointer"]);

function siteFor(target) {
    const a = toGuest(target);
    let S = sites.get(a);
    if (!S) {
        const id = _hook(a, dispatch, 0);
        if (id < 0) throw new Error("cannot hook game code at " + G(a));
        S = { id, addr: a, list: [], replace: null };
        sites.set(a, S);
        byId.set(id, S);
    }
    return S;
}
function dropIfIdle(S) {
    if (S.list.length || S.replace) return;
    _unhook(S.id);
    sites.delete(S.addr);
    byId.delete(S.id);
}

/** Hook game code. `spec` = {onEnter, onLeave} (a listener) or {replace(regsView) -> bool}. */
export function hookGuest(target, spec) {
    const S = siteFor(target);
    if (spec.replace) {
        if (S.replace) throw new Error("game code at " + G(S.addr) + " is already replaced");
        S.replace = spec.replace;
        return { detach() { if (S.replace === spec.replace) { S.replace = null; dropIfIdle(S); } } };
    }
    const L = { onEnter: spec.onEnter, onLeave: spec.onLeave };
    S.list.push(L);
    return { detach() { const i = S.list.indexOf(L); if (i >= 0) { S.list.splice(i, 1); dropIfIdle(S); } } };
}
/** A callable address of a hooked function's original code. */
export const originalOf = (target) => { const S = sites.get(toGuest(target)); return S ? G(_orig(S.id)) : null; };

function t64Attach(target, cbs, data) {
    const p = ptr(target);
    if (!isGuest(p)) return Interceptor.attach(p, cbs, data);
    if (cbs === null || typeof cbs !== "object" || cbs instanceof CModule ||
        (typeof cbs.onEnter !== "function" && typeof cbs.onLeave !== "function"))
        throw new Error("native (CModule) listeners can't attach to translated code");
    return hookGuest(p, { onEnter: cbs.onEnter, onLeave: cbs.onLeave });
}

// A NativeCallback that may stand in for game code (Hook.replace): remembers its JS side.
over(globalThis, "NativeCallback", function (fn, ret, args, abi) {
    const host = new HostNC(fn, ret, args, abi);
    try { host.wstSpec = { fn, ret, args }; } catch (_) {}
    _specs.set(host.toString(), { fn, ret, args });
    return host;
});
const _specs = new Map();

const replaced = new Map();       // target -> listener
function t64Replace(target, cb, data) {
    const p = ptr(target);
    if (!isGuest(p)) return Interceptor.replace(p, cb, data);
    const spec = (cb && cb.wstSpec) || _specs.get(String(cb));
    if (!spec) throw new Error("Hook.replace on game code needs a NativeCallback");
    const l = hookGuest(p, { replace: (rv) => {
        let w = 0;
        const next = () => (w < 4 ? rv.r(w++) : rv.stack(w++ - 4).readU32());
        const vals = [];
        for (const t of spec.args) {
            if (t === "double" || t === "int64" || t === "uint64") {
                if (w & 1) w++;
                const lo = next(), hi = next();
                vals.push(fromWords(t, lo, hi));
            } else vals.push(fromWords(t, next(), 0));
        }
        const out = spec.fn(...vals);
        const ow = [];
        if (spec.ret !== "void") wordsOf(spec.ret, out, ow);
        if (ow.length > 0) rv.set(0, ow[0]);
        if (ow.length > 1) rv.set(1, ow[1]);
        return true;
    } });
    replaced.set(p.toString(), l);
    return l;
}
function t64Revert(target) {
    const p = ptr(target);
    if (!isGuest(p)) return Interceptor.revert(p);
    const l = replaced.get(p.toString());
    if (l) { l.detach(); replaced.delete(p.toString()); }
}

// ---------------------------------------------------------------- game modules
/** A game module's export (host form, Thumb bit kept), or null. */
export function gsym(lib, name) {
    const a = _sym(hostStr(lib), hostStr(name));
    return a ? G(a) : null;
}

export function gmodule(lib) {
    const o = hostMalloc(8);
    if (!_module(hostStr(lib), o, o.add(4))) return null;
    const b = o.readU32(), size = o.add(4).readU32();
    return {
        name: lib, base: G(b), size, path: lib,
        findExportByName: (n) => gsym(lib, n),
        getExportByName: (n) => { const a = gsym(lib, n); if (!a) throw new Error(n + " not in " + lib); return a; },
    };
}

// Frida's Interceptor.attach/replace can't be replaced (non-configurable), so the agent calls
// these through util.js's Hook: the game path for game code, Frida's for host code.
globalThis.WstHook = { attach: t64Attach, replace: t64Replace, revert: t64Revert,
                       detachAll: () => Interceptor.detachAll(), flush: () => Interceptor.flush() };
globalThis.WstGuest = { alloc: galloc, str: gstr, toGuest, isGuest, G };
