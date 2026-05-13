#import <Foundation/Foundation.h>

/// Runs `toolPath` with the given NULL-terminated argv via Authorization Services.
/// Dispatches to a background queue and calls `completion` on that queue once
/// the privileged child process has exited (or authorization failed).
void ISSRunPrivilegedCommand(const char *toolPath,
                             const char *const *arguments,
                             void (^completion)(int status));
