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
          succeeded = error == nil;
          finished = YES;
        }];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
        while (!finished && deadline.timeIntervalSinceNow > 0)
          [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        NSURL *actual = [[workspace URLForApplicationToOpenURL:file] URLByResolvingSymlinksInPath];
        status = finished && succeeded && [actual isEqual:app] ? 0 : 1;
      }
    }
    [fm removeItemAtURL:dir error:nil];
    return status;
  }
}
