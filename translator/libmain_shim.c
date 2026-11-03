// Dummy arm64 "libmain.so" so the real UnityPlayer.java's System.loadLibrary("main")
// succeeds on a 64-bit-only device. The actual 32-bit libmain runs under the
// translator (libwst64.so); its JNI natives are already bound to our inverse
// host->guest trampolines before UnityPlayer is instantiated. This shim only needs
// to load cleanly.
#include <jni.h>
JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void* reserved) { (void)vm; (void)reserved; return JNI_VERSION_1_6; }
