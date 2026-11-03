import "frida-il2cpp-bridge";
const log = (m) => console.log("[agent] " + m);
const SERVER = "192.168.111.10";
const PLAIN_PORT = 80;
const HOST = "pgorelease.nianticlabs.com";

// ---- protobuf helpers
const vi = (n) => { const o = []; n >>>= 0; while (n > 0x7f) { o.push((n & 0x7f) | 0x80); n >>>= 7; } o.push(n); return o; };
const fvar = (num, n) => [...vi(num << 3), ...vi(n)];
const fld = (num, bytes) => [...vi((num << 3) | 2), ...vi(bytes.length), ...bytes];
const utf8 = (s) => Array.from(unescape(encodeURIComponent(s)), (c) => c.charCodeAt(0));
function readVarint(b, i) { let r = 0, s = 0; for (;;) { const x = b[i++]; r += (x & 0x7f) * Math.pow(2, s); if (!(x & 0x80)) break; s += 7; } return [r, i]; }
/** field number -> list of {wt, v (number | Uint8Array)} */
function decode(b) {
    const out = new Map();
    let i = 0;
    while (i < b.length) {
        let tag; [tag, i] = readVarint(b, i);
        const num = Math.floor(tag / 8), wt = tag & 7;
        let v;
        if (wt === 0) [v, i] = readVarint(b, i);
        else if (wt === 1) { v = b.slice(i, i + 8); i += 8; }
        else if (wt === 5) { v = b.slice(i, i + 4); i += 4; }
        else if (wt === 2) { let n; [n, i] = readVarint(b, i); v = b.slice(i, i + n); i += n; }
        else throw new Error("bad wire type " + wt);
        if (!out.has(num)) out.set(num, []);
        out.get(num).push({ wt, v });
    }
    return out;
}
const bytesOf = (p, n) => new Uint8Array(p.readByteArray(n));
const ptr_ = (x) => (x instanceof NativePointer ? x : x.handle);
const arrData = (arr) => arr.handle.add(Il2Cpp.Array.headerSize);

// ---- state
let authToken = null;               // "PTC.a...." string, from N2Server*AuthToken
let nextRpcId = 1;
const done = [];                    // finished requests waiting for the main thread

function captureToken(a) {          // (authId, byte[] token, tokenSize): AuthToken{1: contents}
    try {
        const f = decode(bytesOf(arrData(a[1]), a[2])).get(1);
        if (f) { authToken = String.fromCharCode(...f[0].v); log("auth token captured (" + authToken.length + " chars)"); }
    } catch (e) { log("token parse failed: " + e); }
}

// The player's position, from the requests that carry it (GET_MAP_OBJECTS 3/4, FORT_SEARCH
// 2/3, ENCOUNTER 3/4): the native plugin used to put it in the envelope (7/8/9), and the
// server places raid drops, eggs' walking distance and buddy candy from it.
let lastPos = null;
const POS_FIELDS = { 106: [3, 4], 101: [2, 3], 102: [3, 4], 142: [1, 2], 144: [3, 4], 145: [3, 4] };
const f64 = (u8) => new DataView(u8.buffer, u8.byteOffset, 8).getFloat64(0, true);
const d64 = (num, v) => {
    const b = new Uint8Array(8); new DataView(b.buffer).setFloat64(0, v, true);
    return [...vi((num << 3) | 1), ...b];
};
function notePosition(method, body) {
    const pf = POS_FIELDS[method];
    if (!pf || !body.length) return;
    try {
        const f = decode(body), la = f.get(pf[0]), lo = f.get(pf[1]);
        if (la && lo && la[0].wt === 1 && lo[0].wt === 1) {
            const lat = f64(la[0].v), lng = f64(lo[0].v);
            if (lat || lng) lastPos = [lat, lng];
        }
    } catch (_) {}
}

function buildEnvelope(rpcId, reqs) {
    for (const r of reqs) notePosition(r.method, r.body);
    let e = fvar(3, rpcId);
    for (const r of reqs) e = e.concat(fld(4, fvar(1, r.method).concat(fld(2, Array.from(r.body)))));
    if (lastPos) e = e.concat(d64(7, lastPos[0]), d64(8, lastPos[1]), d64(9, 5.0));
    if (authToken) e = e.concat(fld(10, fld(1, utf8("ptc")).concat(fld(2, fld(1, utf8(authToken))))));
    return e;
}

// Wi-Fi blips and server restarts: retry before reporting a failure, because a failed RPC
// leaves 0.71's request queue stalled.
async function post(envelope) {
    for (let attempt = 1; ; attempt++) {
        try { return await postOnce(envelope); }
        catch (e) {
            if (attempt >= 5) throw e;
            log("post attempt " + attempt + " failed (" + e + "), retrying");
            await new Promise((r) => setTimeout(r, 1500 * attempt));
        }
    }
}

async function postOnce(envelope) {
    const head = utf8("POST /plfe/0/rpc HTTP/1.1\r\nHost: " + HOST + "\r\nContent-Type: application/x-protobuf\r\n" +
        "Content-Length: " + envelope.length + "\r\nConnection: close\r\n\r\n");
    const conn = await Socket.connect({ family: "ipv4", host: SERVER, port: PLAIN_PORT });
    await conn.output.writeAll(new Uint8Array(head.concat(envelope)).buffer);
    let buf = new Uint8Array(0), hdrEnd = -1, need = -1;
    for (;;) {
        const chunk = await conn.input.read(65536);
        if (chunk.byteLength === 0) break;
        const c = new Uint8Array(chunk);
        const n = new Uint8Array(buf.length + c.length); n.set(buf); n.set(c, buf.length); buf = n;
        if (hdrEnd < 0) {
            for (let i = 0; i + 3 < buf.length; i++) {
                if (buf[i] === 13 && buf[i + 1] === 10 && buf[i + 2] === 13 && buf[i + 3] === 10) { hdrEnd = i + 4; break; }
            }
            if (hdrEnd >= 0) {
                const h = String.fromCharCode(...buf.slice(0, hdrEnd));
                const m = /content-length:\s*(\d+)/i.exec(h);
                need = m ? parseInt(m[1], 10) : -1;
                const st = /^HTTP\/1\.\d (\d+)/.exec(h);
                if (!st || st[1] !== "200") throw new Error("HTTP " + (st ? st[1] : "?"));
            }
        }
        if (hdrEnd >= 0 && need >= 0 && buf.length - hdrEnd >= need) break;
    }
    try { conn.close(); } catch (_) {}
    if (hdrEnd < 0) throw new Error("no HTTP response");
    return buf.slice(hdrEnd);
}

Il2Cpp.perform(() => {
    const imgs = Il2Cpp.domain.assemblies.map((a) => a.image);
    const find = (name) => { for (const i of imgs) { const k = i.tryClass(name); if (k) return k; } throw new Error("class " + name); };
    const tryFind = (...ns) => { for (const n of ns) for (const i of imgs) { const k = i.tryClass(n); if (k) return k; } return null; };
    const ep = find("Niantic.Platform.Ditto.Bindings.N2EntryPoints");
    const Mgr = find("Niantic.Platform.Ditto.Rpc.RpcManager");
    const RespK = find("Niantic.Platform.Ditto.Rpc.RpcResponse");
    const ByteString = find("Google.Protobuf.ByteString");
    const Plugin = tryFind("Niantic.Platform.Ditto.Plugin.DittoPlugin", "Niantic.Platform.Ditto.DittoPlugin",
        "Niantic.Platform.Ditto.Plugin.NianticPlugin", "Niantic.Platform.Ditto.NianticPlugin", "Niantic.Platform.Plugin.NianticPlugin");
    if (!Plugin) throw new Error("NianticPlugin not found");
    const byteK = Il2Cpp.corlib.class("System.Byte");
    const Recv = Mgr.method("Recv", 1);
    const mgrInst = () => Mgr.field("thisInstance").value;

    // -- token capture (call through to the original)
    for (const n of ["N2ServerResetAuthToken_", "N2ServerRefreshAuthToken_"]) {
        const m = ep.nested(n).method("Invoke");
        m.implementation = function (...a) { captureToken(a); return this.method("Invoke").invoke(...a); };
    }

    // -- the bypass: replace the native send
    const send = ep.nested("N2ServerSend_").method("Invoke");
    send.implementation = function (timeoutMs, retryMs, count, methods, bodies, sizes, dbg, dbgSize, outId) {
        const rpcId = nextRpcId++;
        const reqs = [];
        let off = 0;
        const base = ptr_(bodies);
        for (let i = 0; i < count; i++) {
            const sz = sizes.get(i);
            reqs.push({ method: methods.get(i), body: sz > 0 ? bytesOf(base.add(off), sz) : new Uint8Array(0) });
            off += sz;
        }
        ptr_(outId).writeS32(rpcId);
        log("Send #" + rpcId + " methods=[" + reqs.map((r) => r.method + ":" + r.body.length).join(",") + "]");
        post(buildEnvelope(rpcId, reqs)).then((body) => {
            const f = decode(body);
            const returns = (f.get(100) || []).map((x) => x.v);
            const status = f.get(1) ? f.get(1)[0].v : 0;
            log("reply #" + rpcId + " status=" + status + " returns=" + returns.length + " (" + body.length + " B)");
            done.push({ rpcId, status: 1, payloads: returns, count: reqs.length });
        }).catch((e) => {
            log("request #" + rpcId + " failed: " + e);
            done.push({ rpcId, status: 5, payloads: [], count: reqs.length });
        });
        return 0;                                        // ApiError.SUCCESS
    };
    log("Send bypass armed -> http://" + SERVER + ":" + PLAIN_PORT + "/plfe/0/rpc");

    // -- delivery: every frame, hand finished replies to RpcManager.Recv
    const upd = Plugin.methods.find((m) => !m.isStatic && m.parameterCount === 0 && /^(Update|OnUpdate)$/.test(m.name));
    if (!upd) throw new Error("no Update on " + Plugin.fullName);
    upd.implementation = function () {
        while (done.length) {
            const d = done.shift();
            try {
                const res = RespK.new();
                res.method("set_RpcId").invoke(d.rpcId);
                res.method("set_ActionCount").invoke(d.count);
                res.method("set_RpcStatus").invoke(d.status);
                let list = res.method("get_ActionPayloads").invoke();
                if (!list || list.isNull()) {
                    list = res.method("get_ActionPayloads").returnType.class.new();
                    res.method("set_ActionPayloads").invoke(list);
                }
                for (const p of d.payloads) {
                    const arr = Il2Cpp.array(byteK, p.length);
                    if (p.length) arrData(arr).writeByteArray(p.buffer.slice(p.byteOffset, p.byteOffset + p.length));
                    list.method("Add", 1).invoke(ByteString.method("CopyFrom", 1).invoke(arr));
                }
                if (Recv.isStatic) Recv.invoke(res);
                else mgrInst().method("Recv", 1).invoke(res);
            } catch (e) { log("deliver #" + d.rpcId + " failed: " + (e.stack || e)); }
        }
        return this.method(upd.name).invoke();
    };
    log("Update tick armed (" + Plugin.fullName + "." + upd.name + ")");

    // -- shop: 0.71's store goes through the native IAP plugin (IapManager), which talks to
    // Niantic's store and never answers here. IapManager is replaced: the item list and the
    // purchases come from the server with two Windstock request numbers (9071 / 9072) in the
    // normal RPC envelope. Every replacement swallows its own errors -- an exception thrown
    // out of a replaced method aborts the game.
    try { installShop(find); } catch (e) { log("shop: not installed: " + (e.stack || e)); }

    // -- battle HP trace (logging only): what the client does with the boss's health
    const HP_TRACE = false;
    if (HP_TRACE) {
        const fmt = (x) => (x === null || x === undefined) ? "null" : (x.isNull && x.isNull()) ? "NULL"
            : (typeof x === "object" && x.class) ? x.class.name : String(x);
        let n = 0;
        const trace = (cls, name, argc) => {
            try {
                const m = find(cls).method(name, argc);
                m.implementation = function (...a) {
                    const r = this.method(name, argc).invoke(...a);
                    if (n++ < 400) log("hp " + find(cls).name + "." + name + "(" + a.map(fmt).join(", ") + ")"
                        + (r === undefined ? "" : " -> " + fmt(r)) + (this.class ? " on " + this.class.name : ""));
                    return r;
                };
            } catch (e) { log("hp trace " + cls + "." + name + " failed: " + e); }
        };
        const SS = "Niantic.Holoholo.Battle.BattleSyncedStats";
        trace(SS, "SetCanonicalHealth", 2);
        trace(SS, "AddHealthDelta", 3);
        trace("Niantic.Holoholo.Battle.BattlePokemon", "set_Health", 1);
    }
    // -- raid catch trace (logging only): why the bonus challenge goes back to the map
    const CATCH_TRACE = true;
    if (CATCH_TRACE) {
        const fmt = (x) => (x === null || x === undefined) ? "null" : (x.isNull && x.isNull()) ? "NULL"
            : (typeof x === "object" && x.class) ? (x.class.name === "String" ? "\"" + x.content + "\"" : x.class.name) : String(x);
        const trace = (cls, name, argc) => {
            try {
                const m = find(cls).method(name, argc);
                m.implementation = function (...a) {
                    log("catch " + name + "(" + a.map(fmt).join(", ") + ")");
                    let r;
                    try { r = this.method(name, argc).invoke(...a); }
                    catch (e) { log("catch " + name + " threw " + e); throw e; }
                    if (r !== undefined) log("catch " + name + " -> " + fmt(r));
                    return r;
                };
            } catch (e) { log("catch trace " + cls + "." + name + " failed: " + e); }
        };
        // which attack effect has no model / prefab (it throws every frame and jams the battle)
        try {
            const fx = find("Niantic.Holoholo.FX.PokemonParticleService").method("SpawnPokemonAttackFx", 4);
            let n = 0;
            fx.implementation = function (name, atk, def, actor) {
                try { return this.method("SpawnPokemonAttackFx", 4).invoke(name, atk, def, actor); }
                catch (e) {
                    if (n++ < 6) log("fx " + (name && !name.isNull() ? name.content : "null") + " attacker=" + fmt(atk)
                        + " defender=" + fmt(def) + " actor=" + fmt(actor) + ": " + e);
                    return null;            // swallow: a missing effect must not stop the battle
                }
            };
        } catch (e) { log("fx trace failed: " + e); }
        // ...and a battle Pokemon whose effect was skipped throws in OnDestroy when the raid
        // scene closes; that error aborted the catch screen's setup (no balls, camera in the
        // Pokemon's face). Cleanup errors are swallowed.
        try {
            const od = find("Niantic.Holoholo.Battle.BattlePokemon").method("OnDestroy", 0);
            let n = 0;
            od.implementation = function () {
                try { return this.method("OnDestroy", 0).invoke(); }
                catch (e) { if (n++ < 3) log("BattlePokemon.OnDestroy error swallowed: " + e); }
            };
        } catch (e) { log("OnDestroy guard failed: " + e); }
    }
    // -- gym trace (logging only, native onEnter -- nothing is replaced): which way the
    // after-a-faint screen went, so a battle that stops early can be read from logcat.
    const GYM_TRACE = false;   // a hooked method that throws aborts the game: on only while chasing a bug
    if (GYM_TRACE) {
        const watch = (cls, name, argc, what) => {
            try {
                const m = find(cls).method(name, argc);
                Interceptor.attach(m.virtualAddress, {
                    onEnter(args) {
                        let extra = "";
                        try { if (what) extra = " " + what(args); } catch (e) { extra = " (" + e + ")"; }
                        log("gym " + find(cls).name + "." + name + extra);
                    }
                });
            } catch (e) { log("gym trace " + cls + "." + name + " failed: " + e); }
        };
        const RS = "Niantic.Holoholo.Gym.Battle.GymBattleResultsState";
        const CG = "Niantic.Holoholo.Gym.Battle.GymBattleContinueGuiController";
        watch(RS, "ShowGymBattleContinueGui", 0);
        watch(RS, "ShowGymBattleVictory", 0);
        watch(RS, "ShowGymBattleDefeat", 0);
        // leaveBattle (0x7C) is what Finish() reads: 1 = Leave was chosen
        watch(RS, "Finish", 0, (a) => "leaveBattle=" + a[0].add(0x7C).readU8());
        watch(CG, "ContinueToNextBattle", 0);
        watch(CG, "LeaveBattle", 0);
        watch(CG, "Initialize", 2, (a) => "countdown=" + a[2].toInt32() + "s");
        // the next battle: exit 0 leave gym / 1 leave battle / 2 continue
        watch("Niantic.Holoholo.Gym.GymBattleState", "ExitBattleResultsState", 2,
            (a) => "exit=" + a[2].toInt32());
        watch("Niantic.Holoholo.Gym.GymBattleState", "RequestNextBattleWhenReady", 1);
        watch("Niantic.Holoholo.Gym.GymState", "RefreshGymDetails", 1);
        // GetDefender(long id) on the gym's defender list: null here ends the run
        try {
            const GS = find("Niantic.Holoholo.Gym.GymState");
            const gd = GS.method("GetDefender", 1);
            Interceptor.attach(gd.virtualAddress, {
                onEnter(a) {
                    // ARM32: `this` in r0, the 64-bit id in the r2:r3 pair
                    this.id = uint64(a[2].toUInt32()).add(uint64(a[3].toUInt32()).shl(32)).toString();
                    let ids = [];
                    try {
                        const st = new Il2Cpp.Object(a[0]);
                        const list = st.method("get_GymDefenders").invoke();
                        if (list && !list.isNull()) {
                            const n = list.method("get_Count").invoke();
                            for (let i = 0; i < n; i++) {
                                const d = list.method("get_Item").invoke(i);
                                ids.push(d.method("get_MotivatedPokemon").invoke().method("get_Pokemon").invoke()
                                    .method("get_Id").invoke().toString());
                            }
                        } else ids = ["list null"];
                    } catch (e) { ids = ["(" + e + ")"]; }
                    this.ids = ids.join(",");
                },
                onLeave(r) { log("gym GetDefender(" + this.id + ") in [" + this.ids + "] -> " + (r.isNull() ? "NULL" : "found")); }
            });
        } catch (e) { log("gym trace GetDefender failed: " + e); }
        watch("Niantic.Holoholo.Gym.GymRootState", "BattleError", 0);
        // the win screen's steps, in order: the last one logged is where it stops
        const RSm = ["EnterState", "ExitState", "Initialize", "ExecuteState", "ShowDefenderCpDrain",
                     "ShowRewardsAndContinueMenu", "MakeDefenderDramaticallyFaint", "SpawnCpDrainToast",
                     "SpawnGymBadgeProgressAndXpGainToast", "CalculateDefenderMotivationChange",
                     "GetNextGymDefender"];
        for (const n of RSm) {
            try { const m = find(RS).tryMethod(n); if (m) watch(RS, n, m.parameterCount); }
            catch (e) { log("gym trace " + n + ": " + e); }
        }
        watch("Niantic.Holoholo.Gym.GymBattleState", "HandleBattleCompletion", 1,
            (a) => "status=" + a[1].add(0x20).readS32());
        watch("Niantic.Holoholo.Gym.GymBattleState", "EndBattleWhenReady", 2, (a) => "status=" + a[1].toInt32());
    }
});

const SHOP_LIST = 9071, SHOP_BUY = 9072;
const IAP_READY = 3, IAP_BUSY = 2, IAP_REFRESHING = 4;
const BUY_NONE = 1, BUY_FAILURE = 2, BUY_TOO_LOW = 3, BUY_IN_PROGRESS = 5, BUY_SUCCESS = 6;

async function rpcOnce(method, body) {
    const f = decode(await post(buildEnvelope(nextRpcId++, [{ method, body: new Uint8Array(body) }])));
    const r = f.get(100);
    return r && r.length ? r[0].v : new Uint8Array(0);
}
const str = (u8) => decodeURIComponent(escape(String.fromCharCode(...u8)));

function installShop(find) {
    const Mgr = find("Niantic.Platform.Ditto.Iap.IapManager");
    const StoreItem = find("Niantic.Platform.Ditto.Iap.IapStoreItem");
    const Balance = find("Niantic.Platform.Ditto.Iap.IapBalance");
    const S = Il2Cpp.corlib.class("System.String"), I = Il2Cpp.corlib.class("System.Int32");
    const Dict = Il2Cpp.corlib.class("System.Collections.Generic.Dictionary`2");
    const DictSI = Dict.inflate(S, I), DictSS = Dict.inflate(S, S);
    const dict = (k, entries) => {
        const d = k.new();
        for (const [key, v] of entries) d.method("Add", 2).invoke(Il2Cpp.string(key), typeof v === "string" ? Il2Cpp.string(v) : v);
        return d;
    };

    let state = IAP_READY, result = BUY_NONE, pendingRefresh = false;
    let catalog = { items: [], coins: 0, stardust: 0 };

    function refresh() {
        state = IAP_REFRESHING;
        rpcOnce(SHOP_LIST, []).then((b) => {
            const f = decode(b), items = [];
            for (const it of f.get(1) || []) {
                const g = decode(it.v), s = (n) => (g.get(n) ? str(g.get(n)[0].v) : ""), n = (k) => (g.get(k) ? g.get(k)[0].v : 0);
                items.push({ sku: s(1), price: n(2), item: s(3), count: n(4), category: s(5), sort: n(6) });
            }
            catalog = { items, coins: f.get(7) ? f.get(7)[0].v : 0, stardust: f.get(8) ? f.get(8)[0].v : 0 };
            log("shop: " + items.length + " items, " + catalog.coins + " coins");
        }).catch((e) => log("shop: list failed: " + e)).then(() => { state = IAP_READY; pendingRefresh = true; });
    }

    Mgr.method("get_IapState").implementation = function () { return state; };
    Mgr.method("get_PurchaseResult").implementation = function () { return result; };
    Mgr.method("RefreshSkusAndBalances").implementation = function () {
        try { refresh(); } catch (e) { log("shop: refresh: " + e); }
    };
    Mgr.method("ProcessEvents").implementation = function () {
        if (!pendingRefresh) return 0;
        pendingRefresh = false;
        try {
            const em = this.field("iapEventManager").value;
            if (em && !em.isNull()) em.method("OnStoreRefresh").invoke();
        } catch (e) { log("shop: OnStoreRefresh: " + (e.stack || e)); }
        return 1;
    };
    Mgr.method("GetStoreSkusAndBalances").implementation = function (items, balances) {
        try {
            for (const c of catalog.items) {
                const si = StoreItem.new();
                si.method("set_Sku").invoke(Il2Cpp.string(c.sku));
                si.method("set_LocalCurrencyPrice").invoke(Il2Cpp.string(""));
                si.method("set_IsVendorItem").invoke(false);
                si.method("set_CanBePurchased").invoke(true);
                si.method("set_VirtualCurrencyPrice").invoke(dict(DictSI, [["POKECOIN", c.price]]));
                si.method("set_VirtualCurrencyGranted").invoke(dict(DictSI, []));
                si.method("set_PresentationData").invoke(dict(DictSS, [["CATEGORY", c.category], ["SORT", String(c.sort)]]));
                si.method("set_ItemQuantities").invoke(dict(DictSI, [[c.item, c.count]]));
                items.method("Add", 1).invoke(si);
            }
            for (const [cur, amt] of [["POKECOIN", catalog.coins], ["STARDUST", catalog.stardust]]) {
                const b = Balance.new();
                b.method("set_CurrencyType").invoke(Il2Cpp.string(cur));
                b.method("set_Amount").invoke(amt);
                balances.method("Add", 1).invoke(b);
            }
        } catch (e) { log("shop: list build failed: " + (e.stack || e)); }
    };
    Mgr.method("PurchaseItem").implementation = function (itemId) {
        try {
            const sku = itemId && !itemId.isNull() ? itemId.content : "";
            state = IAP_BUSY; result = BUY_IN_PROGRESS;
            rpcOnce(SHOP_BUY, fld(1, utf8(sku))).then((b) => {
                const f = decode(b), ok = f.get(1) && f.get(1)[0].v === 1;
                const why = f.get(2) ? str(f.get(2)[0].v) : "";
                result = ok ? BUY_SUCCESS : /^need /.test(why) ? BUY_TOO_LOW : BUY_FAILURE;
                log("shop: buy " + sku + " -> " + (ok ? "ok" : "refused: " + why));
            }).catch((e) => { result = BUY_FAILURE; log("shop: buy failed: " + e); })
              .then(() => { state = IAP_READY; refresh(); });
        } catch (e) { result = BUY_FAILURE; state = IAP_READY; log("shop: PurchaseItem: " + e); }
    };
    log("shop: IapManager replaced (list " + SHOP_LIST + ", buy " + SHOP_BUY + ")");
}
