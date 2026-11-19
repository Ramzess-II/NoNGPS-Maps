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

@end

NS_ASSUME_NONNULL_END
