// Send the agent's console to logcat (tag "WindstockAgent").
//
// Inside a gadget on a stock phone, console.log goes to the gadget's stdout -- nowhere.
// This module is imported FIRST by index.js, so it is live before the bridges evaluate
// and `adb logcat -s WindstockAgent` shows how far the agent got even when it never
// reaches the launcher. Works on Frida 16.7 and 17 (different Module APIs).

function exportOf(module, name) {
    try {
        if (typeof Module.findExportByName === "function") return Module.findExportByName(module, name);
    } catch (_) {}
    try {
        return Process.getModuleByName(module).findExportByName(name);
    } catch (_) {
        return null;
    }
}

const writeAddr = exportOf("liblog.so", "__android_log_write");
const write = writeAddr === null ? null : new NativeFunction(writeAddr, "int", ["int", "pointer", "pointer"]);
// host memory for the host liblog (translator64 later points Memory.allocUtf8String at the game)
const hostStr = Memory.allocUtf8String.bind(Memory);
const TAG = hostStr("WindstockAgent");

export function logcat(level, text) {
    if (write === null) return;
    try {
        write(level, TAG, hostStr(String(text)));
    } catch (_) {}
}

const original = { log: console.log, warn: console.warn, error: console.error };
console.log = (...a) => { logcat(4, a.join(" ")); original.log.apply(console, a); };
console.warn = (...a) => { logcat(5, a.join(" ")); original.warn.apply(console, a); };
console.error = (...a) => { logcat(6, a.join(" ")); original.error.apply(console, a); };

logcat(4, "agent loading (Frida " + Frida.version + ", " + Process.arch + ")");
