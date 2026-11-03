// 0.63 RPC bypass. The native plugin's request pipeline (obfuscated, builds + signs the envelope,
// never opens a socket under translation) is replaced at its managed boundary:
//   N2ServerSend_.Invoke(timeoutMs, retryDelayMs, count, methods[], bodies, sizes[], out rpcId)
// We build the RequestEnvelope ourselves (server/protocol.py layout: #3 request_id, #4 requests,
// #10 auth_info), POST it to /plfe/rpc through the local relay (127.0.0.1:18080 -> the server),
// and hand the reply to RpcHandler.Recv(Result) from NianticPlugin.Update (main thread).
import "./t64/flag.js";
import "./lib/logcat.js";
import "./t64/guest.js";
import Il2Cpp from "./t64/il2cpp.js";

const log = (s) => console.log("[rpc071] " + s);

// The agent carries /plfe/rpc; tell the translator to fail the plugin's own :443 lookup (see sys.cpp getaddrinfo).
try {
    const setenv = new NativeFunction(Module.getExportByName(null, "setenv"), "int", ["pointer", "pointer", "int"]);
    setenv(Memory.allocUtf8String("WST_BLOCK_NATIVE_RPC"), Memory.allocUtf8String("1"), 1);
    console.log("[rpc071] native :443 lookups blocked");
} catch (e) { console.log("[rpc071] setenv failed: " + e); }
const RELAY = { family: "ipv4", host: "127.0.0.1", port: 18080 };
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

// ---- state
let authToken = null;               // "PTC.a...." string, from N2Server*AuthToken
let nextRpcId = 1;
const done = [];                    // finished requests waiting for the main thread

function captureToken(a) {          // (authId, byte[] token, tokenSize): AuthToken{1: contents}
    try {
        const f = decode(bytesOf(a[1].elements, a[2])).get(1);
        if (f) { authToken = String.fromCharCode(...f[0].v); log("auth token captured (" + authToken.length + " chars)"); }
    } catch (e) { log("token parse failed: " + e); }
}

function buildEnvelope(rpcId, reqs) {
    let e = fvar(3, rpcId);
    for (const r of reqs) e = e.concat(fld(4, fvar(1, r.method).concat(fld(2, Array.from(r.body)))));
    if (authToken) e = e.concat(fld(10, fld(1, utf8("ptc")).concat(fld(2, fld(1, utf8(authToken))))));
    return e;
}

// A server restart resets connections mid-request: retry before reporting a failure,
// because a failed RPC leaves 0.71's request queue stalled.
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
    const conn = await Socket.connect(RELAY);
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
    const Plugin = tryFind("Niantic.Platform.Ditto.Plugin.DittoPlugin", "Niantic.Platform.Ditto.DittoPlugin", "Niantic.Platform.Ditto.Plugin.NianticPlugin", "Niantic.Platform.Ditto.NianticPlugin", "Niantic.Platform.Plugin.NianticPlugin");
    if (!Plugin) throw new Error("NianticPlugin not found");
    log("Plugin " + Plugin.fullName + " methods: " + Plugin.methods.map((m) => (m.isStatic ? "static " : "") + m.name + "/" + m.parameterCount).join(" "));
    const statusK = find("Niantic.Platform.Ditto.Rpc.RpcStatus");
    log("RpcStatus: " + statusK.fields.filter((f) => f.isStatic).map((f) => f.name + "=" + f.value).join(" "));
    const byteK = Il2Cpp.corlib.class("System.Byte");
    const Recv = Mgr.method("Recv", 1);
    const mgrInst = () => Mgr.field("thisInstance").value;
    const nested = (n) => ep.nested(n);

    // -- token capture (call through to the original)
    for (const n of ["N2ServerResetAuthToken_", "N2ServerRefreshAuthToken_"]) {
        const m = nested(n).method("Invoke");
        m.implementation = function (...a) { captureToken(a); return m.bind(this).invoke(...a); };
    }

    // -- the bypass: replace the native send
    const send = nested("N2ServerSend_").method("Invoke");
    send.implementation = function (timeoutMs, retryMs, count, methods, bodies, sizes, dbg, dbgSize, outId) {
        const rpcId = nextRpcId++;
        const reqs = [];
        let off = 0;
        for (let i = 0; i < count; i++) {
            const sz = sizes.get(i);
            reqs.push({ method: methods.get(i), body: sz > 0 ? bytesOf(bodies.add(off), sz) : new Uint8Array(0) });
            off += sz;
        }
        outId.writeS32(rpcId);
        log("Send #" + rpcId + " methods=[" + reqs.map((r) => r.method + ":" + r.body.length).join(",") + "] -> /plfe/0/rpc");
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
    log("Send bypass armed");

    // -- delivery: every frame, hand finished replies to RpcHandler.Recv
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
                    const arr = Il2Cpp.array(byteK, p.length);          // write raw: Arr.set strides by 4 for byte[] here
                    for (let wrote = 0; wrote < p.length; wrote += 4096) {
                        const n = Math.min(4096, p.length - wrote);
                        arr.elements.add(wrote).writeByteArray(p.buffer.slice(p.byteOffset + wrote, p.byteOffset + wrote + n));
                    }
                    list.method("Add", 1).invoke(ByteString.method("CopyFrom", 1).invoke(arr));
                }
                Recv.bind(mgrInst()).invoke(res);
                log("delivered #" + d.rpcId);
            } catch (e) { log("deliver #" + d.rpcId + " failed: " + (e.stack || e)); }
        }
        return upd.bind(this).invoke();
    };
    log("Update tick armed");
    // -- gym battle trace: which step of GO BATTLE gives up (logging only)
    const traceHook = (cls, name, argc) => {
        try {
            const k = find(cls);
            const m = argc === undefined ? k.method(name) : k.method(name, argc);
            m.implementation = function (...a) {
                log("trace " + k.name + "." + name + "(" + a.map((x) => (x === null || x === undefined) ? "null"
                    : (x.isNull && x.isNull()) ? "NULL" : (x.content !== undefined ? x.toString()
                    : (typeof x === "object" && x.class ? x.class.name : String(x)))).join(", ") + ")");
                let r;
                try { r = m.bind(this).invoke(...a); }
                catch (e) { log("trace " + k.name + "." + name + " threw " + e); throw e; }
                log("trace " + k.name + "." + name + " -> " + (r === undefined ? "void" : (r && r.isNull && r.isNull()) ? "NULL" : (r && r.content !== undefined ? r.toString() : (r && r.class ? r.class.name : String(r)))));
                return r;
            };
        } catch (e) { log("trace hook " + cls + "." + name + " failed: " + e); }
    };
    // -- raid lobby trace (logging only): which step after the countdown gives up
    const RAID_TRACE = true;
    if (RAID_TRACE) {
        const RL = "Niantic.Holoholo.Raid.RaidLobbyGuiController";
        for (const n of ["Init", "StartLobbyIntro", "OnLobbyIntroComplete", "ShowBattlePrepGui",
                         "PlayBattleIntro", "TeamIsReadyToFight", "UpdateAvatars", "RejoinBattle",
                         "<PingRaidDetails>m__6", "<PingRaidDetails>m__7", "<OnLobbyIntroComplete>m__3",
                         "<PlayBattleIntro>m__9", "HandleRaidBattleComplete"])
            traceHook(RL, n);
        for (const n of ["EnterState", "StartRaidBattleState"])
            traceHook("Niantic.Holoholo.Raid.RaidLobbyState", n);
        for (const n of ["GetRaidPokemon", "AddOrUpdateRaidPokemon"])
            traceHook("Niantic.Holoholo.Raid.RaidRpcService", n);
        traceHook("Niantic.Holoholo.Raid.RaidState", "SetCurrentLobbyProto");
        traceHook("Niantic.Holoholo.Raid.RaidBattleState", "EnterState");
    }
    const TRACE = false;   // set true to trace the gym battle / asset loader (see git history)
    if (TRACE) {
    traceHook("Niantic.Holoholo.Gym.GymState", "StartBattle");
    traceHook("Niantic.Holoholo.Gym.GymState", "FailedToStartBattle");
    traceHook("Niantic.Holoholo.Gym.GymState", "GetDefenderPokemonProtoByIndex");
    traceHook("Niantic.Holoholo.Gym.GymBattleState", "StartGymBattle");
    traceHook("Niantic.Holoholo.Battle.GymBattleRpcService", "SendStartBattleRpc");
    traceHook("Niantic.Holoholo.Gym.GymRootState", "RefreshGymDetails");
    for (const n of ["RunIntro", "ExitState", "HandleIntroComplete", "ReleaseAssetRequests"])
        traceHook("Niantic.Holoholo.Gym.GymBattleIntroState", n);
    for (const n of ["HandleBattleCompletion", "ResolveBattle", "EndBattleWhenReady", "SwitchToBattleResultsState", "ExitBattleResultsState"])
        traceHook("Niantic.Holoholo.Gym.GymBattleState", n);
    const PAM = "Niantic.Holoholo.AssetBundles.PokemonAssetManager";
    traceHook(PAM, "RequestModel", 1); traceHook(PAM, "RequestModel", 2);
    for (const n of ["RequestPokemonModel", "RequestSprite", "TryRequestSprite", "PokemonModelBundleName", "PokemonIconBundleName", "IsValidPokemonId"])
        if (!/IsValidPokemonId|PokemonModelBundleName/.test(n)) traceHook(PAM, n);
    for (const n of ["RunIntroState", "StartGymBattleWhenReady", "InstantiateBattlePokemon", "ExitState", "EnterState"])
        traceHook("Niantic.Holoholo.Gym.GymBattleState", n);
    traceHook("Niantic.Holoholo.AssetBundles.ResourceBundleLoader", "RequestBundle");
    for (const n of ["RequestBundle", "DownloadAndCacheAsset", "DownloadAsset", "LoadStreamFromPath", "LoadBundleFromBytes", "DecryptStream", "GetCacheFilePath"])
        traceHook("Niantic.Holoholo.AssetBundles.CloudStoreBundleLoader", n);
    // digest readiness: log the first answer and every change
    try {
        const ad = find("Niantic.Holoholo.AssetBundles.AssetDigest");
        for (const nm of ["get_IsReady", "get_State", "get_Count"]) {
            const m = ad.method(nm); let last = "unset";
            m.implementation = function () {
                const r = m.bind(this).invoke(); const v = String(r);
                if (v !== last) { log("digest " + nm + " = " + v); last = v; }
                return r;
            };
        }
    } catch (e) { log("digest state hook failed: " + e); }
    for (const n of ["Get", "RequestCloudURL", "RequestAssetDigest", "RefreshCloudURLs", "RetryDigestRequest"])
        traceHook("Niantic.Holoholo.AssetBundles.AssetDigest", n);

    }
});
