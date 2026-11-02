#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, LogLevel) {
  LogLevelDebug = 0,
  LogLevelInfo,
  LogLevelWarning,
  LogLevelError,
  LogLevelCritical
};

@interface Logger : NSObject

+ (void)log:(LogLevel)level message:(NSString *)message;
+ (BOOL)canLog:(LogLevel)level;
+ (void)setFileLoggingEnabled:(BOOL)fileLoggingEnabled;
+ (nullable NSURL *)getLogFileURL;
+ (uint64_t)getLogFileSize;
/// Zips the log files whose names pass the test, nil when none does.
+ (nullable NSURL *)zipLogFilesPassingTest:(BOOL (^)(NSString * name))test NS_SWIFT_NAME(zipLogFiles(passingTest:));

@end

NS_ASSUME_NONNULL_END
