#import "WSPythonServer.h"
#import "WSPaths.h"
#import "WSLog.h"

#import <Python/Python.h>
#import <UIKit/UIKit.h>
#import <unistd.h>

NSNotificationName const WSPythonServerStateDidChangeNotification =
    @"WSPythonServerStateDidChange";

@implementation WSPythonServer {
    dispatch_queue_t _queue;       // serialises every call into CPython
    BOOL _interpreterReady;
    PyThreadState *_mainThreadState;
    PyObject *_boot;               // the ws_boot module, borrowed-forever
    NSFileHandle *_logRead;
    NSMutableData *_logPartial;
}

+ (WSPythonServer *)shared {
    static WSPythonServer *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [WSPythonServer new]; });
    return shared;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _queue = dispatch_queue_create("com.windstock.launcher.python", DISPATCH_QUEUE_SERIAL);
    _state = WSPythonServerStateStopped;
    _logPartial = [NSMutableData data];
    // iOS takes a suspended app's listening sockets away; the server has to
    // reopen them the moment we are back, before the game's first request.
    // Notifications, not the app delegate -- the game replaces the delegate.
    for (NSNotificationName name in @[UIApplicationWillEnterForegroundNotification,
                                      UIApplicationDidBecomeActiveNotification]) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(appWoke:)
                                                   name:name object:nil];
    }
    return self;
}

- (void)appWoke:(NSNotification *)note {
    dispatch_async(_queue, ^{
        if (!self->_interpreterReady) return;
        PyGILState_STATE gil = PyGILState_Ensure();
        PyObject *result = [self call:"revive"];
        Py_XDECREF(result);
        PyGILState_Release(gil);
        [self readStatus];
    });
}

#pragma mark - state

- (void)setState:(WSPythonServerState)state error:(nullable NSString *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_state = state;
        self->_lastError = [error copy];
        [NSNotificationCenter.defaultCenter
            postNotificationName:WSPythonServerStateDidChangeNotification object:self];
    });
}

#pragma mark - stdout pipe

// Python writes to a pipe rather than to a file we poll: the server screen
// shows lines as the server prints them, which is what makes "did the client
// even reach us" answerable while standing outside with the phone.
- (int)openLogPipe {
    int fds[2];
    if (pipe(fds) != 0) return -1;

    _logRead = [[NSFileHandle alloc] initWithFileDescriptor:fds[0] closeOnDealloc:YES];
    __weak typeof(self) weakSelf = self;
    _logRead.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *chunk = handle.availableData;
        if (chunk.length == 0) return;
        [weakSelf consumeLogData:chunk];
    };
    return fds[1];
}

- (void)consumeLogData:(NSData *)chunk {
    @synchronized (self) {
        [_logPartial appendData:chunk];
        const char *bytes = _logPartial.bytes;
        NSUInteger start = 0;
        for (NSUInteger i = 0; i < _logPartial.length; i++) {
            if (bytes[i] != '\n') continue;
            NSData *lineData = [_logPartial subdataWithRange:NSMakeRange(start, i - start)];
            NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
            if (line.length) WSLog(@"server", @"%@", line);
            start = i + 1;
        }
        if (start > 0) {
            [_logPartial replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
        }
    }
}

#pragma mark - interpreter

- (BOOL)prepareInterpreter {
    if (_interpreterReady) return YES;

    NSString *serverDir = WSPaths.pythonServerDir;
    NSString *stdlib = WSPaths.pythonStdlibDir;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:stdlib]) {
        WSLog(@"server", @"python-stdlib missing from the bundle -- run tools/stage_python.sh");
        return NO;
    }
    if (![fm fileExistsAtPath:[serverDir stringByAppendingPathComponent:@"server.py"]]) {
        WSLog(@"server", @"PythonServer/server.py missing -- run tools/stage_server.sh");
        return NO;
    }

    NSString *dataDir = [WSPaths.serverDataDir stringByAppendingPathComponent:@"data"];
    [WSPaths ensureDirectory:dataDir error:nil];

    setenv("WS_SERVER_DIR", serverDir.fileSystemRepresentation, 1);
    setenv("WS_DATA_DIR", dataDir.fileSystemRepresentation, 1);
    setenv("WS_FRAMEWORKS_DIR", WSPaths.frameworksDir.fileSystemRepresentation, 1);
    setenv("CERT_DIR", [serverDir stringByAppendingPathComponent:@"certs"]
                           .fileSystemRepresentation, 1);
    setenv("BIND", "127.0.0.1", 1);
    setenv("WS_HTTP_PORT", "8080", 1);
    setenv("PYTHONDONTWRITEBYTECODE", "1", 1);   // the bundle is read-only
    setenv("PYTHONUNBUFFERED", "1", 1);

    int writeFD = [self openLogPipe];
    if (writeFD >= 0) {
        setenv("WS_LOG_FD", [NSString stringWithFormat:@"%d", writeFD].UTF8String, 1);
    }

    PyStatus status;
    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode = 0;
    config.user_site_directory = 0;
    config.site_import = 0;
    config.install_signal_handlers = 0;    // UIKit owns the signal handlers
    config.optimization_level = 1;

    PyConfig_SetBytesString(&config, &config.program_name, "windstock");
    PyConfig_SetBytesString(&config, &config.home,
                            WSPaths.hostBundlePath.fileSystemRepresentation);

    config.module_search_paths_set = 1;
    NSArray<NSString *> *searchPaths = @[
        stdlib,
        [stdlib stringByAppendingPathComponent:@"lib-dynload"],
        serverDir,
        [serverDir stringByAppendingPathComponent:@"vendor"],
    ];
    for (NSString *path in searchPaths) {
        wchar_t *wide = Py_DecodeLocale(path.fileSystemRepresentation, NULL);
        if (!wide) continue;
        PyWideStringList_Append(&config.module_search_paths, wide);
        PyMem_RawFree(wide);
    }

    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        WSLog(@"server", @"Py_InitializeFromConfig failed: %s",
              status.err_msg ?: "(no message)");
        return NO;
    }

    _boot = PyImport_ImportModule("ws_boot");
    if (!_boot) {
        [self logPythonError:@"import ws_boot"];
        return NO;
    }

    _interpreterReady = YES;
    WSLog(@"server", @"CPython %s ready", Py_GetVersion());
    // Py_InitializeFromConfig leaves this thread holding the GIL. The serial
    // queue below is not guaranteed to run on the same thread every time, so
    // hand the GIL back and let every later call take it through PyGILState.
    _mainThreadState = PyEval_SaveThread();
    return YES;
}

- (void)logPythonError:(NSString *)context {
    if (!PyErr_Occurred()) {
        WSLog(@"server", @"%@ failed with no Python error set", context);
        return;
    }
    PyObject *type = NULL, *value = NULL, *tb = NULL;
    PyErr_Fetch(&type, &value, &tb);
    PyErr_NormalizeException(&type, &value, &tb);
    PyObject *str = value ? PyObject_Str(value) : NULL;
    const char *msg = str ? PyUnicode_AsUTF8(str) : "(unprintable)";
    WSLog(@"server", @"%@ raised: %s", context, msg ?: "(null)");
    Py_XDECREF(str);
    Py_XDECREF(type); Py_XDECREF(value); Py_XDECREF(tb);
}

- (nullable PyObject *)call:(const char *)name {
    if (!_boot) return NULL;
    PyObject *fn = PyObject_GetAttrString(_boot, name);
    if (!fn) { [self logPythonError:@(name)]; return NULL; }
    PyObject *result = PyObject_CallNoArgs(fn);
    Py_DECREF(fn);
    if (!result) [self logPythonError:@(name)];
    return result;
}

#pragma mark - control

- (void)startOnPort:(uint16_t)port {
    [self startOnPort:port tunnelTarget:nil];
}

- (void)startOnPort:(uint16_t)port tunnelTarget:(nullable NSString *)target {
    [self setState:WSPythonServerStateStarting error:nil];
    NSString *tunnel = [target copy] ?: @"";
    dispatch_async(_queue, ^{
        setenv("PORT", [NSString stringWithFormat:@"%u", port].UTF8String, 1);
        if (![self prepareInterpreter]) {
            [self setState:WSPythonServerStateFailed
                     error:@"Could not start the Python runtime. See the log."];
            return;
        }
        self->_port = port;
        PyGILState_STATE gil = PyGILState_Ensure();
        // Server or tunnel is chosen by a call, not an environment variable:
        // os.environ was copied when the interpreter started, so a setenv()
        // made now would never reach it.
        PyObject *configure = self->_boot
            ? PyObject_GetAttrString(self->_boot, "configure_tunnel") : NULL;
        if (configure) {
            PyObject *mode = PyObject_CallFunction(configure, "s", tunnel.UTF8String);
            if (!mode) [self logPythonError:@"configure_tunnel"];
            Py_XDECREF(mode);
            Py_DECREF(configure);
        } else {
            [self logPythonError:@"configure_tunnel"];
        }
        PyObject *result = [self call:"start"];
        Py_XDECREF(result);
        PyGILState_Release(gil);
        if (!result) {
            [self setState:WSPythonServerStateFailed error:@"ws_boot.start() failed."];
            return;
        }
        // start() only spawns the thread; the listener may still fail to bind.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       self->_queue, ^{ [self readStatus]; });
    });
}

- (void)stop {
    dispatch_async(_queue, ^{
        if (!self->_interpreterReady) return;
        PyGILState_STATE gil = PyGILState_Ensure();
        PyObject *result = [self call:"stop"];
        Py_XDECREF(result);
        PyGILState_Release(gil);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       self->_queue, ^{ [self readStatus]; });
    });
}

- (void)forgetOnlineCertificate {
    dispatch_async(_queue, ^{
        if (!self->_interpreterReady) return;
        PyGILState_STATE gil = PyGILState_Ensure();
        PyObject *result = [self call:"forget_online_certificate"];
        Py_XDECREF(result);
        PyGILState_Release(gil);
    });
}

- (void)refreshState {
    dispatch_async(_queue, ^{
        if (!self->_interpreterReady) return;
        [self readStatus];
    });
}

/// Must run on _queue. Takes the GIL itself.
- (void)readStatus {
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *result = [self call:"status_json"];
    NSString *text = nil;
    if (result) {
        const char *json = PyUnicode_AsUTF8(result);
        if (json) text = @(json);
        Py_DECREF(result);
    }
    PyGILState_Release(gil);
    if (!text) return;

    NSDictionary *status = [NSJSONSerialization
        JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding]
                   options:0 error:nil];
    if (![status isKindOfClass:NSDictionary.class]) return;

    NSString *err = [status[@"error"] isKindOfClass:NSString.class] ? status[@"error"] : nil;
    BOOL running = [status[@"running"] boolValue];
    if (running) {
        [self setState:WSPythonServerStateRunning error:nil];
    } else if (err) {
        [self setState:WSPythonServerStateFailed error:err];
    } else {
        [self setState:WSPythonServerStateStopped error:nil];
    }
}

@end
