#import "WSContainer.h"
#import "WSPaths.h"

#import <ctype.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>

static char *gRealHome = NULL;
static char *gRealBundlePath = NULL;
static char *gContainerHome = NULL;
static BOOL gSafeMode = NO;
static BOOL gDidBootstrap = NO;

const char *_Nullable WSContainerRealHome(void) { return gRealHome; }
const char *_Nullable WSContainerRealBundlePath(void) { return gRealBundlePath; }
const char *_Nullable WSContainerCurrentHome(void) { return gContainerHome; }
BOOL WSContainerIsSafeMode(void) { return gSafeMode; }

// mkdir -p without Foundation: bootstrap runs before we want to touch it.
static void ws_mkdirs(const char *path) {
    char buf[PATH_MAX];
    strlcpy(buf, path, sizeof buf);
    for (char *p = buf + 1; *p; p++) {
        if (*p != '/') continue;
        *p = '\0';
        mkdir(buf, 0755);
        *p = '/';
    }
    mkdir(buf, 0755);
}

static BOOL ws_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0;
}

// The active profile is a single line in Documents/Windstock/profile. Read with
// raw POSIX calls so bootstrap stays Foundation-free.
static void ws_read_profile(char *out, size_t outlen) {
    strlcpy(out, "default", outlen);
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/Documents/Windstock/profile", gRealHome);
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[256] = {0};
    if (fgets(line, sizeof line, f)) {
        size_t n = strlen(line);
        while (n && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = '\0';
        // Refuse anything that could escape Documents/Containers.
        BOOL ok = n > 0;
        for (size_t i = 0; i < n; i++) {
            char c = line[i];
            if (!(isalnum((unsigned char)c) || c == '-' || c == '_')) { ok = NO; break; }
        }
        if (ok) strlcpy(out, line, outlen);
    }
    fclose(f);
}

void WSContainerBootstrap(void) {
    if (gDidBootstrap) return;
    gDidBootstrap = YES;

    const char *home = getenv("HOME");
    if (!home) return;
    gRealHome = strdup(home);

    // Bundle path: <...>/WindstockLauncher.app, derived from the executable
    // path rather than NSBundle so that this stays valid after the swizzle.
    char exe[PATH_MAX];
    uint32_t sz = sizeof exe;
    if (_NSGetExecutablePath(exe, &sz) == 0) {
        char resolved[PATH_MAX];
        if (realpath(exe, resolved)) {
            char *slash = strrchr(resolved, '/');
            if (slash) *slash = '\0';
            gRealBundlePath = strdup(resolved);
        }
    }

    char marker[PATH_MAX];
    snprintf(marker, sizeof marker, "%s/Documents/Windstock/safe-mode", gRealHome);
    if (ws_exists(marker)) {
        gSafeMode = YES;
        return;  // leave the environment alone; the UI runs unsandboxed-as-usual
    }

    char launcherRoot[PATH_MAX];
    snprintf(launcherRoot, sizeof launcherRoot, "%s/Documents/Windstock", gRealHome);
    ws_mkdirs(launcherRoot);

    char profile[256];
    ws_read_profile(profile, sizeof profile);

    char container[PATH_MAX];
    snprintf(container, sizeof container, "%s/Documents/Containers/%s", gRealHome, profile);

    static const char *subdirs[] = {
        "Documents", "tmp", "Library", "Library/Caches", "Library/Preferences",
        "Library/Application Support", "Library/SplashBoard",
        // UIKit expects these to exist under HOME. The keyboard in particular
        // keeps its state in Library/Keyboard and will not come up without it.
        "Library/Keyboard", "Library/Cookies", "Library/WebKit",
        "Library/Saved Application State", "Library/Caches/Snapshots", NULL,
    };
    for (int i = 0; subdirs[i]; i++) {
        char p[PATH_MAX];
        snprintf(p, sizeof p, "%s/%s", container, subdirs[i]);
        ws_mkdirs(p);
    }

    char tmp[PATH_MAX];
    snprintf(tmp, sizeof tmp, "%s/tmp", container);

    setenv("HOME", container, 1);
    setenv("CFFIXED_USER_HOME", container, 1);
    setenv("TMPDIR", tmp, 1);
    // Unity reads this for its persistentDataPath on some versions.
    setenv("XDG_DATA_HOME", container, 1);

    gContainerHome = strdup(container);
}
