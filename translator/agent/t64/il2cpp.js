// translator64: the part of frida-il2cpp-bridge's API the agent uses, rebuilt on the game's
// own il2cpp exports (called through guest.js). The bridge itself assumes a native 32-bit
// process; here the game is translated, so classes/methods/objects are read through the
// il2cpp_* API and calls go through il2cpp_runtime_invoke (no hand-made ABI per method).
// Handles are raw GUEST pointers (NativePointer < 4 GB), exactly what the agent passes around.
import { callWords, G, galloc, gmodule, gstr, hookGuest, regPtr, toGuest } from "./guest.js";

const LIB = "libil2cpp.so";
const mod = gmodule(LIB);
if (!mod) throw new Error("translator64: libil2cpp.so not loaded");

// ---- raw API: every il2cpp_* export as a word-in/word-out function
const _fn = new Map();
function api(name) {
    let a = _fn.get(name);
    if (a === undefined) {
        a = mod.findExportByName("il2cpp_" + name);
        if (!a) throw new Error("il2cpp_" + name + " missing");
        _fn.set(name, a);
    }
    return a;
}
const call = (name, ...w) => callWords(api(name), w.map((x) => toGuest(x instanceof Object && !(x instanceof NativePointer) && x.handle ? x.handle : x)))[0];
const callP = (name, ...w) => G(call(name, ...w));
const cstr = (p) => (p ? G(p).readUtf8String() : null);

const PS = 4;
const OBJ_HDR = 8;            // klass, monitor
const ARR_HDR = 16;           // klass, monitor, bounds, max_length
const STR_LEN = 8, STR_CHARS = 12;

const T = {
    END: 0x00, VOID: 0x01, BOOLEAN: 0x02, CHAR: 0x03, I1: 0x04, U1: 0x05, I2: 0x06, U2: 0x07,
    I4: 0x08, U4: 0x09, I8: 0x0a, U8: 0x0b, R4: 0x0c, R8: 0x0d, STRING: 0x0e, PTR: 0x0f,
    BYREF: 0x10, VALUETYPE: 0x11, CLASS: 0x12, VAR: 0x13, ARRAY: 0x14, GENERICINST: 0x15,
    TYPEDBYREF: 0x16, I: 0x18, U: 0x19, FNPTR: 0x1b, OBJECT: 0x1c, SZARRAY: 0x1d, MVAR: 0x1e,
};

// ---- il2cpp_init: the agent is in before Unity initializes il2cpp; performs wait for it
const _pending = [];
let _ready = false;
function initialized() {
    if (!_ready) {
        try { _ready = call("is_fully_initialized") !== 0; } catch (_) {}
    }
    return _ready;
}
if (!initialized()) {
    const l = hookGuest(api("init"), {
        onLeave() {
            _ready = true;
            console.log("[windstock] il2cpp up: running " + _pending.length + " queued perform(s)");
            while (_pending.length) _pending.shift()();
        },
    });
    void l;
}

// ---- threads: the agent's own threads must be known to il2cpp before they run managed code
const _attached = new Set();
function attachThread() {
    const tid = Process.getCurrentThreadId();
    if (_attached.has(tid)) return;
    _attached.add(tid);
    if (call("is_vm_thread", 0)) return;
    call("thread_attach", call("domain_get"));
}

// ---- caches (handles are stable for the life of the process)
const _classes = new Map(), _types = new Map(), _methods = new Map(), _fields = new Map();
const cached = (m, h, mk) => { const k = toGuest(h); let v = m.get(k); if (!v) m.set(k, v = mk(G(k))); return v; };

function iterate(fnName, owner) {
    const it = galloc(4);
    it.writeU32(0);
    const out = [];
    for (;;) {
        const p = call(fnName, owner, it);
        if (!p) break;
        out.push(G(p));
    }
    return out;
}

// ---------------------------------------------------------------- Type
class Type {
    constructor(handle) { this.handle = handle; }
    get typeEnum() { return call("type_get_type", this.handle); }
    get enumValue() { return this.typeEnum; }
    get isByReference() { return ((this.handle.add(4).readU32() >>> 30) & 1) === 1; }
    get name() {
        if (this._name === undefined) {
            const p = call("type_get_name", this.handle);
            this._name = cstr(p);
        }
        return this._name;
    }
    get class() { return klassOf(callP("class_from_type", this.handle)); }
    get object() { return new Obj(callP("type_get_object", this.handle)); }
    get isReference() {
        const e = this.typeEnum;
        if (this.isByReference) return false;
        if (e === T.STRING || e === T.CLASS || e === T.OBJECT || e === T.ARRAY || e === T.SZARRAY) return true;
        if (e === T.GENERICINST || e === T.VAR || e === T.MVAR) return !this.class.isValueType;
        return false;
    }
    /** Bytes a value of this type takes inline (fields, arrays, unboxed values). */
    get size() {
        switch (this.typeEnum) {
            case T.BOOLEAN: case T.I1: case T.U1: return 1;
            case T.CHAR: case T.I2: case T.U2: return 2;
            case T.I8: case T.U8: case T.R8: return 8;
            case T.VALUETYPE: case T.GENERICINST: if (!this.isReference) return this.class.valueTypeSize; return PS;
            default: return 4;
        }
    }
    toString() { return this.name; }
}
const typeOf = (h) => cached(_types, h, (p) => new Type(p));

// ---------------------------------------------------------------- reading / writing typed values
function read(addr, type) {
    const p = addr;
    if (type.isByReference) return p.readPointer();
    switch (type.typeEnum) {
        case T.BOOLEAN: return p.readU8() !== 0;
        case T.CHAR: case T.U2: return p.readU16();
        case T.I1: return p.readS8();
        case T.U1: return p.readU8();
        case T.I2: return p.readS16();
        case T.I4: return p.readS32();
        case T.U4: return p.readU32();
        case T.I8: return p.readS64();
        case T.U8: return p.readU64();
        case T.R4: return p.readFloat();
        case T.R8: return p.readDouble();
        case T.I: case T.U: case T.PTR: case T.FNPTR: return p.readPointer();
        case T.STRING: return new Str(p.readPointer());
        case T.ARRAY: case T.SZARRAY: return new Arr(p.readPointer());
        case T.CLASS: case T.OBJECT: return new Obj(p.readPointer());
        default:
            if (type.isReference) return new Obj(p.readPointer());
            return ValueType.copyFrom(p, type);
    }
}

function write(addr, value, type) {
    const p = addr;
    if (type.isByReference) { p.writePointer(handleOf(value)); return; }
    switch (type.typeEnum) {
        case T.BOOLEAN: p.writeU8(value ? 1 : 0); return;
        case T.CHAR: case T.U2: p.writeU16(num(value)); return;
        case T.I1: p.writeS8(num(value)); return;
        case T.U1: p.writeU8(num(value)); return;
        case T.I2: p.writeS16(num(value)); return;
        case T.I4: p.writeS32(num(value)); return;
        case T.U4: p.writeU32(num(value) >>> 0); return;
        case T.I8: p.writeS64(value instanceof Int64 ? value : int64(String(value))); return;
        case T.U8: p.writeU64(value instanceof UInt64 ? value : uint64(String(value))); return;
        case T.R4: p.writeFloat(Number(value)); return;
        case T.R8: p.writeDouble(Number(value)); return;
        default:
            if (type.isReference || type.typeEnum === T.I || type.typeEnum === T.U || type.typeEnum === T.PTR) {
                p.writePointer(handleOf(value));
                return;
            }
            // a value type
            if (value instanceof ValueType) { Memory.copy(p, value.handle, type.size); return; }
            if (type.class.isEnum) { write(p, value, type.class.baseType); return; }
            if (Array.isArray(value)) {
                const fs = type.class.fields.filter((f) => !f.isStatic);
                fs.forEach((f, i) => write(p.add(f.offset - OBJ_HDR), value[i], f.type));
                return;
            }
            throw new Error("can't store " + value + " as " + type.name);
    }
}
const num = (v) => (typeof v === "boolean" ? +v : typeof v === "number" ? v : (v && v.toNumber) ? v.toNumber() :
    (v instanceof ValueType) ? v.field("value__").value : Number(v));
function handleOf(v) {
    if (v === null || v === undefined) return ptr(0);
    if (v instanceof NativePointer) return v;
    if (v.handle instanceof NativePointer) return v.handle;
    return G(toGuest(v));
}

// ---------------------------------------------------------------- Class
class Klass {
    constructor(handle) { this.handle = handle; }
    get name() { return this._name ??= cstr(call("class_get_name", this.handle)); }
    get namespace() { return this._ns ??= cstr(call("class_get_namespace", this.handle)); }
    get fullName() {
        const d = this.declaringClass;
        if (d) return d.fullName + "." + this.name;
        return this.namespace ? this.namespace + "." + this.name : this.name;
    }
    get type() { return typeOf(callP("class_get_type", this.handle)); }
    get image() { return new Image(callP("class_get_image", this.handle)); }
    get parent() { const p = call("class_get_parent", this.handle); return p ? klassOf(G(p)) : null; }
    get declaringClass() { const p = call("class_get_declaring_type", this.handle); return p ? klassOf(G(p)) : null; }
    get elementClass() { const p = call("class_get_element_class", this.handle); return p ? klassOf(G(p)) : null; }
    get isValueType() { return call("class_is_valuetype", this.handle) !== 0; }
    get isEnum() { return call("class_is_enum", this.handle) !== 0; }
    get isInterface() { return call("class_is_interface", this.handle) !== 0; }
    get isAbstract() { return call("class_is_abstract", this.handle) !== 0; }
    get isGeneric() { return call("class_is_generic", this.handle) !== 0; }
    get isInflated() { return call("class_is_inflated", this.handle) !== 0; }
    get instanceSize() { return call("class_instance_size", this.handle); }
    get valueTypeSize() { const a = galloc(4); return call("class_value_size", this.handle, a); }
    get arrayElementSize() { return call("class_array_element_size", this.handle); }
    get baseType() { return typeOf(callP("class_enum_basetype", this.handle)); }
    get methods() { return this._methods ??= iterate("class_get_methods", this.handle).map(methodOf); }
    get fields() { return this._fields ??= iterate("class_get_fields", this.handle).map(fieldOf); }
    get nestedClasses() { return iterate("class_get_nested_types", this.handle).map(klassOf); }
    get interfaces() { return iterate("class_get_interfaces", this.handle).map(klassOf); }
    get assemblyName() { return cstr(call("class_get_assemblyname", this.handle)); }

    initialize() { call("runtime_class_init", this.handle); return this; }
    isSubclassOf(other, interfaces) { return call("class_is_subclass_of", this.handle, other.handle, interfaces ? 1 : 0) !== 0; }
    isAssignableFrom(other) { return call("class_is_assignable_from", this.handle, other.handle) !== 0; }

    tryMethod(name, argc) {
        if (argc === undefined) argc = -1;
        for (let k = this; k; k = k.parent) {
            const m = k.methods.find((x) => x.name === name && (argc < 0 || x.parameterCount === argc));
            if (m) return m;
        }
        return null;
    }
    method(name, argc) {
        const m = this.tryMethod(name, argc);
        if (!m) throw new Error("couldn't find method " + name + " in class " + this.fullName);
        return m;
    }
    tryField(name) {
        for (let k = this; k; k = k.parent) {
            const f = k.fields.find((x) => x.name === name);
            if (f) return f;
        }
        return null;
    }
    field(name) {
        const f = this.tryField(name);
        if (!f) throw new Error("couldn't find field " + name + " in class " + this.fullName);
        return f;
    }
    tryNested(name) { return this.nestedClasses.find((c) => c.name === name) ?? null; }
    nested(name) { const c = this.tryNested(name); if (!c) throw new Error("no nested " + name); return c; }

    alloc() { return new Obj(callP("object_new", this.handle)); }
    new(...args) {
        const o = this.alloc();
        const ctor = this.methods.find((m) => m.name === ".ctor" && m.parameterCount === args.length);
        if (ctor) ctor.bind(o).invoke(...args);
        return o;
    }
    equals(o) { return o && this.handle.equals(o.handle); }
    toString() { return this.fullName; }
}
const klassOf = (h) => cached(_classes, h, (p) => new Klass(p));

// ---------------------------------------------------------------- Method
class Method {
    constructor(handle) { this.handle = handle; this._impl = null; }
    get name() { return this._name ??= cstr(call("method_get_name", this.handle)); }
    get class() { return klassOf(callP("method_get_class", this.handle)); }
    get parameterCount() { return this._argc ??= call("method_get_param_count", this.handle); }
    get parameters() {
        return this._params ??= Array.from({ length: this.parameterCount }, (_, i) => ({
            name: cstr(call("method_get_param_name", this.handle, i)),
            position: i,
            type: typeOf(callP("method_get_param", this.handle, i)),
        }));
    }
    get returnType() { return this._ret ??= typeOf(callP("method_get_return_type", this.handle)); }
    get isStatic() { return this._static ??= call("method_is_instance", this.handle) === 0; }
    get isGeneric() { return call("method_is_generic", this.handle) !== 0; }
    get isInflated() { return call("method_is_inflated", this.handle) !== 0; }
    get flags() { return call("method_get_flags", this.handle, 0); }
    get virtualAddress() { return this.handle.readPointer(); }       // MethodInfo.methodPointer
    get relativeVirtualAddress() { return this.virtualAddress.sub(mod.base); }
    get object() { return new Obj(callP("method_get_object", this.handle, 0)); }

    bind(target) { return new BoundMethod(this, target); }
    invoke(...args) { return invoke(this, null, args); }

    get implementation() { return this._impl ? this._impl.fn : null; }
    set implementation(fn) {
        if (this._impl) { this._impl.listener.detach(); this._impl = null; }
        if (fn === null || fn === undefined) return;
        const listener = hookGuest(this.virtualAddress, { replace: (rv) => replaceCall(this, fn, rv) });
        this._impl = { fn, listener };
    }
    revert() { this.implementation = null; }
    toString() { return this.class.fullName + "::" + this.name; }
}
const methodOf = (h) => cached(_methods, h, (p) => new Method(p));

class BoundMethod {
    constructor(method, target) { this.method_ = method; this.target = target; }
    get handle() { return this.method_.handle; }
    get name() { return this.method_.name; }
    get parameterCount() { return this.method_.parameterCount; }
    get parameters() { return this.method_.parameters; }
    get returnType() { return this.method_.returnType; }
    get isStatic() { return this.method_.isStatic; }
    get isGeneric() { return this.method_.isGeneric; }
    get virtualAddress() { return this.method_.virtualAddress; }
    get class() { return this.method_.class; }
    get implementation() { return this.method_.implementation; }
    set implementation(fn) { this.method_.implementation = fn; }
    bind(t) { return new BoundMethod(this.method_, t); }
    invoke(...args) { return invoke(this.method_, this.target, args); }
    toString() { return this.method_.toString(); }
}

// ---- runtime_invoke: params are pointers (reference types: the object itself; value types
// and primitives: a pointer to the value). Value-type results come back boxed.
function invoke(m, target, args) {
    attachThread();
    const ps = m.parameters;
    if (args.length !== ps.length) throw new Error(m + " takes " + ps.length + " argument(s), got " + args.length);
    const keep = [];
    const params = galloc(4 * Math.max(1, ps.length));
    for (let i = 0; i < ps.length; i++) {
        const t = ps[i].type;
        if (t.isReference) { params.add(4 * i).writePointer(handleOf(args[i])); continue; }
        const buf = galloc(Math.max(8, t.isByReference ? 4 : t.size));
        keep.push(buf);
        if (t.isByReference) buf.writePointer(handleOf(args[i]));
        else write(buf, args[i], t);
        params.add(4 * i).writePointer(t.isByReference ? handleOf(args[i]) : buf);
    }
    let self = ptr(0);
    if (!m.isStatic) {
        if (target === null || target === undefined) throw new Error(m + " needs an instance");
        self = target instanceof ValueType ? callP("value_box", target.type.class.handle, target.handle) : handleOf(target);
    }
    const exc = galloc(4);
    exc.writeU32(0);
    const r = callP("runtime_invoke", m.handle, self, params, exc);
    const e = exc.readPointer();
    if (!e.isNull()) throw new Error(m + " threw " + describeException(e));
    const rt = m.returnType;
    if (rt.typeEnum === T.VOID) return undefined;
    if (rt.isReference) return wrapRef(r, rt);
    if (r.isNull()) return null;
    return read(callP("object_unbox", r), rt);
}
function wrapRef(h, t) {
    switch (t.typeEnum) {
        case T.STRING: return new Str(h);
        case T.ARRAY: case T.SZARRAY: return new Arr(h);
        default: return new Obj(h);
    }
}
function describeException(e) {
    try {
        const buf = galloc(1024);
        call("format_exception", e, buf, 1024);
        return buf.readUtf8String();
    } catch (_) {
        try { return new Obj(e).class.fullName; } catch (__) { return String(e); }
    }
}

// ---- a replaced method, called by the game: regs -> JS values -> fn -> r0/r1.
// il2cpp's ARM ABI (softfp): [sret] [this] params... MethodInfo*; 64-bit values on even words.
function replaceCall(m, fn, rv) {
    const sp = rv.r(13);
    let w = 0;
    const word = () => (w < 4 ? rv.r(w++) : G(sp + 4 * (w++ - 4)).readU32());
    const rt = m.returnType;
    const sret = rt.typeEnum !== T.VOID && !rt.isReference && rt.typeEnum !== T.I8 && rt.typeEnum !== T.U8 &&
        rt.typeEnum !== T.R8 && rt.size > 4 && (rt.typeEnum === T.VALUETYPE || rt.typeEnum === T.GENERICINST) &&
        !rt.class.isEnum;
    const sretAt = sret ? word() : 0;
    const self = m.isStatic ? m.class : new Obj(G(word()));
    const vals = [];
    for (const p of m.parameters) {
        const t = p.type;
        if (t.isReference) { vals.push(wrapRef(G(word()), t)); continue; }
        if (t.isByReference) { vals.push(regPtr(word())); continue; }
        const n = Math.max(1, Math.ceil(t.size / 4));
        if (t.size === 8 && (t.typeEnum === T.I8 || t.typeEnum === T.U8 || t.typeEnum === T.R8) && (w & 1)) w++;
        const buf = galloc(4 * n);
        for (let k = 0; k < n; k++) buf.add(4 * k).writeU32(word());
        vals.push(read(buf, t));
    }
    let out;
    attachThread();
    out = fn.apply(self, vals);
    if (rt.typeEnum === T.VOID) return true;
    if (sret) {
        write(G(sretAt), out, rt);
        rv.set(0, sretAt);
        return true;
    }
    const buf = galloc(8);
    buf.writeU32(0); buf.add(4).writeU32(0);
    if (rt.isReference) buf.writePointer(handleOf(out));
    else write(buf, out, rt);
    rv.set(0, buf.readU32());
    if (rt.size > 4) rv.set(1, buf.add(4).readU32());
    return true;
}

// ---------------------------------------------------------------- Field
class Field {
    constructor(handle, target) { this.handle = handle; this.target = target ?? null; }
    get name() { return cstr(call("field_get_name", this.handle)); }
    get type() { return typeOf(callP("field_get_type", this.handle)); }
    get offset() { return call("field_get_offset", this.handle); }
    get flags() { return call("field_get_flags", this.handle); }
    get isStatic() { return (this.flags & 0x10) !== 0; }
    get isLiteral() { return (this.flags & 0x40) !== 0; }
    get class() { return klassOf(callP("field_get_parent", this.handle)); }
    bind(target) { return new Field(this.handle, target); }
    get address() {
        if (this.target instanceof ValueType) return this.target.handle.add(this.offset - OBJ_HDR);
        return handleOf(this.target).add(this.offset);
    }
    get value() {
        if (this.isStatic) {
            const t = this.type;
            const buf = galloc(Math.max(8, t.size));
            call("field_static_get_value", this.handle, buf);
            return read(buf, t);
        }
        if (this.target === null) throw new Error("field " + this.name + " needs an instance");
        return read(this.address, this.type);
    }
    set value(v) {
        if (this.isStatic) {
            const t = this.type;
            const buf = galloc(Math.max(8, t.size));
            write(buf, v, t);
            call("field_static_set_value", this.handle, buf);
            return;
        }
        if (this.target === null) throw new Error("field " + this.name + " needs an instance");
        write(this.address, v, this.type);
    }
    toString() { return this.name; }
}
const fieldOf = (h) => cached(_fields, h, (p) => new Field(p));

// ---------------------------------------------------------------- Object / String / Array / ValueType
class Obj {
    constructor(handle) { this.handle = handle instanceof NativePointer ? handle : G(toGuest(handle ?? 0)); }
    get class() { return klassOf(callP("object_get_class", this.handle)); }
    isNull() { return this.handle.isNull(); }
    equals(o) { return o !== null && o !== undefined && this.handle.equals(handleOf(o)); }
    tryMethod(name, argc) { const m = this.class.tryMethod(name, argc); return m ? m.bind(this) : null; }
    method(name, argc) { return this.class.method(name, argc).bind(this); }
    tryField(name) { const f = this.class.tryField(name); return f ? (f.isStatic ? f : f.bind(this)) : null; }
    field(name) { const f = this.class.field(name); return f.isStatic ? f : f.bind(this); }
    get size() { return call("object_get_size", this.handle); }
    unbox() { return ValueType.copyFrom(callP("object_unbox", this.handle), this.class.type); }
    ref(pin) { return new GCHandle(call("gchandle_new", this.handle, pin ? 1 : 0)); }
    weakRef(track) { return new GCHandle(call("gchandle_new_weakref", this.handle, track ? 1 : 0)); }
    get object() { return this; }
    toString() {
        if (this.isNull()) return "null";
        try { const s = this.method("ToString", 0).invoke(); return s ? s.content : "null"; } catch (e) { return this.class.fullName; }
    }
}
Obj.headerSize = OBJ_HDR;

class Str extends Obj {
    get length() { return this.isNull() ? 0 : this.handle.add(STR_LEN).readS32(); }
    get content() { return this.isNull() ? null : this.handle.add(STR_CHARS).readUtf16String(this.length); }
    set content(s) { throw new Error("Il2Cpp.String.content is read-only here"); }
    get object() { return new Obj(this.handle); }
    toString() { return this.isNull() ? "null" : JSON.stringify(this.content); }
}

class Arr extends Obj {
    get length() { return this.isNull() ? 0 : this.handle.add(12).readU32(); }
    get elementType() { return this.class.elementClass.type; }
    get elementSize() { return this.class.arrayElementSize; }
    get elements() { return this.handle.add(ARR_HDR); }
    get(i) {
        if (i < 0 || i >= this.length) throw new Error("index " + i + " out of bounds (" + this.length + ")");
        return read(this.elements.add(i * this.elementSize), this.elementType);
    }
    set(i, v) {
        if (i < 0 || i >= this.length) throw new Error("index " + i + " out of bounds (" + this.length + ")");
        write(this.elements.add(i * this.elementSize), v, this.elementType);
    }
    get object() { return new Obj(this.handle); }
    *[Symbol.iterator]() { const n = this.length; for (let i = 0; i < n; i++) yield this.get(i); }
    toString() { return "[" + Array.from(this).join(", ") + "]"; }
}
Arr.headerSize = ARR_HDR;

class ValueType {
    constructor(handle, type) {
        // keep the caller's pointer object: galloc'd memory lives as long as it does
        this.handle = handle instanceof NativePointer ? handle : G(toGuest(handle));
        this.type = type;
    }
    static copyFrom(src, type) {
        const n = Math.max(4, type.size);
        const buf = galloc(n);
        Memory.copy(buf, src, n);
        return new ValueType(buf, type);
    }
    get class() { return this.type.class; }
    isNull() { return this.handle.isNull(); }
    field(name) { const f = this.type.class.field(name); return f.isStatic ? f : f.bind(this); }
    tryField(name) { const f = this.type.class.tryField(name); return f ? (f.isStatic ? f : f.bind(this)) : null; }
    method(name, argc) { return this.type.class.method(name, argc).bind(this); }
    tryMethod(name, argc) { const m = this.type.class.tryMethod(name, argc); return m ? m.bind(this) : null; }
    box() { return new Obj(callP("value_box", this.type.class.handle, this.handle)); }
    toString() { try { return this.box().toString(); } catch (e) { return "[" + this.type.name + "]"; } }
}

class GCHandle {
    constructor(h) { this.handle = h; }
    get target() { const p = call("gchandle_get_target", this.handle); return p ? new Obj(G(p)) : null; }
    free() { call("gchandle_free", this.handle); }
}

// ---------------------------------------------------------------- Image / Assembly / Domain
class Image {
    constructor(handle) { this.handle = handle; }
    get name() { return cstr(call("image_get_name", this.handle)); }
    get assembly() { return new Assembly(callP("image_get_assembly", this.handle)); }
    get classes() {
        const n = call("image_get_class_count", this.handle);
        return Array.from({ length: n }, (_, i) => klassOf(callP("image_get_class", this.handle, i)));
    }
    tryClass(name) {
        const dot = name.lastIndexOf(".");
        const ns = dot < 0 ? "" : name.slice(0, dot), n = dot < 0 ? name : name.slice(dot + 1);
        const p = call("class_from_name", this.handle, gstr(ns), gstr(n));
        if (p) return klassOf(G(p));
        // "Outer.Inner": a nested class
        if (dot > 0) {
            const outer = this.tryClass(ns);
            if (outer) return outer.tryNested(n);
        }
        return null;
    }
    class(name) { const k = this.tryClass(name); if (!k) throw new Error("couldn't find class " + name); return k; }
}
class Assembly {
    constructor(handle) { this.handle = handle; }
    get image() { return new Image(callP("assembly_get_image", this.handle)); }
    get name() { return this.image.name.replace(/\.dll$/, ""); }
}
const domain = {
    get handle() { return callP("domain_get"); },
    get assemblies() {
        const n = galloc(4);
        const arr = callP("domain_get_assemblies", this.handle, n);
        const out = [];
        for (let i = 0, c = n.readU32(); i < c; i++) out.push(new Assembly(arr.add(4 * i).readPointer()));
        return out;
    },
    tryAssembly(name) { return this.assemblies.find((a) => a.name === name) ?? null; },
    assembly(name) { const a = this.tryAssembly(name); if (!a) throw new Error("couldn't find assembly " + name); return a; },
};

// ---------------------------------------------------------------- the Il2Cpp namespace
const Il2Cpp = {
    module: mod,
    domain,
    get corlib() { return new Image(callP("get_corlib")); },
    unityVersion: "5.3 (translator64)",
    Object: Obj, String: Str, Array: Arr, ValueType, Class: Klass, Method: Method, Field, Type,
    GCHandle, Image, Assembly,
    string(s) {
        attachThread();
        return new Str(callP("string_new", gstr(s === null || s === undefined ? "" : String(s))));
    },
    array(k, lengthOrElements) {
        attachThread();
        const els = typeof lengthOrElements === "number" ? null : lengthOrElements;
        const n = els ? els.length : lengthOrElements;
        const a = new Arr(callP("array_new", k.handle, n));
        if (els) els.forEach((v, i) => a.set(i, v));
        return a;
    },
    /** Runs `fn` once il2cpp is initialized: now, or right after il2cpp_init returns (on
     *  Unity's main thread). The agent loads before Unity starts il2cpp. */
    perform(fn) {
        return new Promise((resolve, reject) => {
            const run = () => {
                try { attachThread(); resolve(fn()); } catch (e) {
                    console.log("[windstock] Il2Cpp.perform: " + (e.stack || e));
                    reject(e);
                }
            };
            if (initialized()) run(); else _pending.push(run);
        });
    },
    exports: {
        resolveInternalCall: (namePtr) => callP("resolve_icall", namePtr),
        gcCollect: (gen) => call("gc_collect", gen),
    },
    gc: { collect: (gen) => call("gc_collect", gen ?? 0) },
};
Il2Cpp.Type.Enum = T;

globalThis.Il2Cpp = Il2Cpp;
export default Il2Cpp;
