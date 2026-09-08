#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdatomic.h>

// duti cannot register dynamic UTIs. Use an actual disposable file so macOS
// resolves only this extension; never assign public.data or extensionless files.
int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc != 3) return 64;
    NSURL *app = [[NSURL fileURLWithPath:@(argv[1])] URLByResolvingSymlinksInPath];
    NSString *ext = @(argv[2]);
    NSCharacterSet *invalid = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    if (ext.length == 0 || [ext rangeOfCharacterFromSet:invalid].location != NSNotFound ||
        ![[NSBundle bundleWithURL:app].bundleIdentifier isEqualToString:@"com.microsoft.VSCode"])
      return 64;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    if (![fm createDirectoryAtURL:dir withIntermediateDirectories:NO
                      attributes:@{NSFilePosixPermissions: @0700} error:nil]) return 1;
    NSURL *file = [dir URLByAppendingPathComponent:[@"probe" stringByAppendingPathExtension:ext]];
    int status = 1;
    if ([NSData.data writeToURL:file options:NSDataWritingAtomic error:nil]) {
      NSWorkspace *workspace = NSWorkspace.sharedWorkspace;
      NSURL *current = [[workspace URLForApplicationToOpenURL:file] URLByResolvingSymlinksInPath];
      UTType *type = nil;
      [file getResourceValue:&type forKey:NSURLContentTypeKey error:nil];
      if ([current isEqual:app]) {
        status = 0;
      } else if (current == nil && type.isDynamic) {
        // The completion may run on another queue; publish one atomic result.
        __block atomic_int result;
        atomic_init(&result, 0);
        [workspace setDefaultApplicationAtURL:app toOpenContentTypeOfFileAtURL:file
                            completionHandler:^(NSError *error) {
          if (error) fprintf(stderr, "VSCode handler .%s: %s (%ld)\n", argv[2],
                             error.domain.UTF8String, (long)error.code);
          atomic_store(&result, error == nil ? 1 : -1);
        }];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
        while (atomic_load(&result) == 0 && deadline.timeIntervalSinceNow > 0)
          [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        int completed = atomic_load(&result);
        if (completed == 0) fprintf(stderr, "VSCode handler .%s: macOS completion timed out\n", argv[2]);
        NSURL *actual = [[workspace URLForApplicationToOpenURL:file] URLByResolvingSymlinksInPath];
        status = completed == 1 && [actual isEqual:app] ? 0 : 1;
      }
    }
    if (status != 0) fprintf(stderr, "VSCode handler .%s: default application unverified\n", argv[2]);
    [fm removeItemAtURL:dir error:nil];
    return status;
  }
}
