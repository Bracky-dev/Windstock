//  WSPythonServer.h -- the Windstock server, embedded.
//
//  CPython 3.13 (python-apple-support) is linked into the launcher and the
//  server's own .py files are staged into the bundle by tools/stage_server.sh.
//  That keeps one implementation of the game protocol -- the one the project
//  actually maintains -- instead of a second, diverging Swift port.
//
//  The interpreter is initialised once and never finalised: CPython does not
//  reliably survive Py_Finalize/Py_Initialize cycles with threads in flight.
//  Start/stop therefore means starting and stopping the HTTP server inside the
//  interpreter, not the interpreter itself.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const WSPythonServerStateDidChangeNotification;

typedef NS_ENUM(NSInteger, WSPythonServerState) {
    WSPythonServerStateStopped = 0,
    WSPythonServerStateStarting,
    WSPythonServerStateRunning,
    WSPythonServerStateFailed,
};

@interface WSPythonServer : NSObject

@property (class, readonly) WSPythonServer *shared;

@property (readonly) WSPythonServerState state;
@property (readonly) uint16_t port;
/// Non-nil when state == Failed.
@property (readonly, nullable, copy) NSString *lastError;

/// Starts the interpreter (first call only) and the HTTP server. Returns
/// immediately; watch WSPythonServerStateDidChangeNotification.
- (void)startOnPort:(uint16_t)port;
/// The same, but choosing what runs behind the ports: nil/empty for the game
/// server on this phone, "ip:port" for the encrypted tunnel to a Windstock
/// Online server (tunnel.py). Calling it while the other one is running
/// switches over.
- (void)startOnPort:(uint16_t)port tunnelTarget:(nullable NSString *)target;
/// Windstock Online: drop the certificate saved for the current server, so
/// the next connection learns it afresh.
- (void)forgetOnlineCertificate;
- (void)stop;

/// Re-reads the server's status out of the interpreter. Cheap; called by the
/// server screen on a timer.
- (void)refreshState;

@end

NS_ASSUME_NONNULL_END
