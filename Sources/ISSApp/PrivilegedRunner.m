#import "PrivilegedRunner.h"

#import <Security/Security.h>

void ISSRunPrivilegedCommand(const char *toolPath,
                             const char *const *arguments,
                             void (^completion)(int status)) {
    // Copy inputs into ObjC-managed storage so the caller can free its argv
    // before the dispatched block runs.
    NSString *tool = [NSString stringWithUTF8String:toolPath];
    NSMutableArray<NSString *> *argList = [NSMutableArray array];
    if (arguments != NULL) {
        for (size_t i = 0; arguments[i] != NULL; i++) {
            [argList addObject:[NSString stringWithUTF8String:arguments[i]]];
        }
    }

    void (^cb)(int) = [completion copy];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        AuthorizationRef authRef = NULL;
        OSStatus status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment, kAuthorizationFlagDefaults, &authRef);
        if (status != errAuthorizationSuccess) {
            if (cb) cb((int)status);
            return;
        }

        AuthorizationItem right = {kAuthorizationRightExecute, 0, NULL, 0};
        AuthorizationRights rights = {1, &right};

        status = AuthorizationCopyRights(
            authRef,
            &rights,
            kAuthorizationEmptyEnvironment,
            kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights | kAuthorizationFlagPreAuthorize,
            NULL
        );
        if (status != errAuthorizationSuccess) {
            AuthorizationFree(authRef, kAuthorizationFlagDestroyRights);
            if (cb) cb((int)status);
            return;
        }

        NSUInteger argc = argList.count;
        const char **argv = (const char **)calloc(argc + 1, sizeof(char *));
        for (NSUInteger i = 0; i < argc; i++) {
            argv[i] = [argList[i] UTF8String];
        }
        argv[argc] = NULL;

        FILE *pipe = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        status = AuthorizationExecuteWithPrivileges(
            authRef,
            [tool UTF8String],
            kAuthorizationFlagDefaults,
            (char *const *)argv,
            &pipe
        );
#pragma clang diagnostic pop

        free(argv);

        // Drain stdout — fread returns 0 at EOF, which happens when the child
        // closes its stdout (typically on exit). This is how we wait for the
        // privileged process to finish without access to its PID.
        if (pipe != NULL) {
            char buffer[4096];
            while (fread(buffer, 1, sizeof(buffer), pipe) > 0) {}
            fclose(pipe);
        }

        AuthorizationFree(authRef, kAuthorizationFlagDestroyRights);
        if (cb) cb((int)status);
    });
}
