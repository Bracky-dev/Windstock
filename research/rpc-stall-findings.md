# 0.63 on windstock30: where the boot stalls (2026-10-19)

Verified on the emulator (translator063, this project's server/ on :443):
- PTC authorize/login/accessToken/profile -> OK. GET /plfe/version -> 200 (needed this project's server;
  the copy in "Pokemon go private server/work/server" answered 405).
- Native plugin then calls getaddrinfo(pgorelease.nianticlabs.com, "443") from libNianticLabsPlugin.so+0x8f8c69
  (translator maps it to 10.0.2.2), but NEVER calls socket()/connect(). No POST /plfe/rpc reaches the server.
  ~22 s later the client restarts the PTC login. HoloBoot steps (WaitForLogin, config, digest, GM) never run.
- Plugin threads are busy in control-flow-flattened Thumb code (jump-table dispatcher, 64-bit state compares)
  at libNianticLabsPlugin.so+0xa54740 / 0xa5f340 / 0xa61580 / 0xfe89c0 / 0xe78480 / 0xf52f40 (tid with ~140 samples).
  Unknown whether slow or looping; the same pattern shows in the 0.71 run.

## Request-signer path (managed seam to hook / bypass the native signer)
Niantic.Platform.Rpc `RpcHandler` (dump.cs:176286, static):
- `Send(int timeoutMs, int retryDelayMs, RpcHandler.Request[] requests, Action<Result> cb)`  RVA 0x7D92FC  <- native builds + signs the envelope after this
- `Send(int method, int timeoutMs, int retryDelayMs, IMessage inProto, Action<IFuture<RpcData>> cb, CancellationToken)` RVA 0x7D8DBC
- `Recv(RpcHandler.Result)` RVA 0x7D9AA0   <- response comes back here
- `OnRpcResponseEventHandler(IMessage)` RVA 0x7D9D34, `DispatchCallbacks` RVA 0x7D97C0
Native bindings: `NianticPlugin.GetN2Api(out N2EntryPoints.N2NativeBindings)` (dump.cs:173662); libNianticLabsPlugin export `GetN2ApiW`.
(RVAs are the iOS arm64 dump; the Android armv7 il2cpp has its own.)
Bypass plan: hook managed `RpcHandler.Send`, POST the request protos as a plain envelope to the server's /plfe/rpc
over the existing 127.0.0.1:18080 relay, and feed the reply to `Recv` -- skipping the native signer entirely.

## RESOLVED (2026-10-19): bypass working
Hook `Niantic.Platform.Bindings.N2EntryPoints.N2ServerSend_.Invoke` (Niantic.Promenade.dll):
`(timeoutMs, retryMs, count, int[] methods, IntPtr bodies [one flat buffer, sizes[] split it], int[] sizes, out rpcId)`.
Build envelope (#3 request_id, #4 Request{1 type,2 msg}, #10 auth_info{1 "ptc",2{1 token}}), POST /plfe/0/rpc via
127.0.0.1:18080 (Host pgorelease.nianticlabs.com), then call `RpcHandler.Recv(Result)` from `NianticPlugin.Update`.
Gotchas: `RpcHandler.Result` is a STRUCT (pass `obj.unbox()`); `Il2Cpp.array(byte)`.set strides 4 under translation,
write bytes raw via `arr.elements.writeByteArray`; token comes from `N2ServerResetAuthToken_` (AuthToken{1:"PTC.a...."}).
Result: GET_PLAYER, remote config, asset digest, game master all served; client reaches the Terms of Service screen.
Code: translator063/agent/index.js (local git repo in translator063, commit "0.63: bypass native RPC signer").

## 0.71 resolution
Same bypass as 0.63 at the managed seam, Ditto names: `Niantic.Platform.Ditto.Bindings.N2EntryPoints.N2ServerSend_.Invoke(timeoutMs, retryMs, count, methods[], bodies, sizes[], debugInfo, debugSize, out result)`
(two extra args vs 0.63). Replies are delivered with `Niantic.Platform.Ditto.Rpc.RpcManager.Recv(RpcResponse)` on the `thisInstance` singleton
(class, not struct; build `ActionPayloads` list manually, ctor not run by `new()`); tick hook is `DittoPlugin` Update.
Result: boot RPCs 2,7,300,6,5000,121,106 answered, client reaches the map. Agent: translator071/agent/index.js.
