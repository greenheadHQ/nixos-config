#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

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
        __block BOOL finished = NO;
        __block BOOL succeeded = NO;
        [workspace setDefaultApplicationAtURL:app toOpenContentTypeOfFileAtURL:file
                            completionHandler:^(NSError *error) {
          if (error) fprintf(stderr, "VSCode handler .%s: %s (%ld)\n", argv[2],
                             error.domain.UTF8String, (long)error.code);
          succeeded = error == nil;
          finished = YES;
        }];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
        while (!finished && deadline.timeIntervalSinceNow > 0)
          [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        if (!finished) fprintf(stderr, "VSCode handler .%s: macOS completion timed out\n", argv[2]);
        NSURL *actual = [[workspace URLForApplicationToOpenURL:file] URLByResolvingSymlinksInPath];
        status = finished && succeeded && [actual isEqual:app] ? 0 : 1;
      }
    }
    if (status != 0) fprintf(stderr, "VSCode handler .%s: default application unverified\n", argv[2]);
    [fm removeItemAtURL:dir error:nil];
    return status;
  }
}
