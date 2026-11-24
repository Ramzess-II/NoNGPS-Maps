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
/// Zips the log files of the days, "yyyy-MM-dd", nil when there is none.
+ (nullable NSURL *)zipLogFilesOfDays:(NSSet<NSString *> *)days NS_SWIFT_NAME(zipLogFiles(days:));
/// A drive starts: the lines logged after this go to a new file.
+ (void)startTrip;
/// Gets the place and the text of a failed CHECK/ASSERT of the core before the process aborts, e.g. to put them into a
/// crash report. Nil for none. Runs on the thread that failed: no waiting, no network.
+ (void)setAssertHandler:(nullable void (^)(NSString * source, NSString * message))handler;

@end

NS_ASSUME_NONNULL_END
