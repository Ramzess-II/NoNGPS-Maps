#import "Logger.h"
#import <OSLog/OSLog.h>
#import <sys/utsname.h>
#import "AppInfo.h"

#include "base/logging.hpp"
#include "coding/zip_creator.hpp"

#include <cmath>

@interface Logger ()

@property(nullable, nonatomic) NSFileHandle * fileHandle;
/// When the file was started, its name: at the first line since the launch or since startTrip.
@property(nullable, nonatomic) NSDate * started;
/// The first moment of the next day: a line written at it or later goes on in the folder of that day.
@property(nullable, nonatomic) NSDate * dayEnd;
/// The file under the logs folder, see freeLogFileNameStarted:now:. It is chosen once per file, as the name of a
/// file that is written already would be taken for a shared one.
@property(nullable, nonatomic) NSString * fileName;
/// When a failed open may be tried again, nil when the last one worked.
@property(nullable, nonatomic) NSDate * retryOpen;
@property(nonnull, nonatomic) os_log_t osLogger;
/// This property is introduced to avoid the CoreApi => Maps target dependency and stores the
/// MWMSettings.isFileLoggingEnabled value.
@property(class, nonatomic) BOOL fileLoggingEnabled;
@property(class, readonly, nonatomic) dispatch_queue_t fileLoggingQueue;

+ (Logger *)logger;
+ (void)enableFileLogging;
+ (void)disableFileLogging;
+ (void)runSyncOnFileLoggingQueue:(dispatch_block_t)block;
+ (void)logMessageWithLevel:(base::LogLevel)level src:(base::SrcPoint const &)src message:(std::string const &)message;
+ (void)tryWriteToFile:(std::string const &)logString;
+ (BOOL)openFileIfNeeded;
+ (void)closeFile;
+ (void)deleteOldestFiles;
+ (NSArray<NSString *> *)logFiles;
+ (NSArray<NSString *> *)logFilesOfDays:(NSSet<NSString *> *)days;
+ (BOOL)logFileAtIndex:(NSUInteger)index of:(NSArray<NSString *> *)names goesOnInto:(NSSet<NSString *> *)taken;
+ (nullable NSString *)dayAfter:(NSString *)day;
+ (NSString *)startOfLogFile:(NSString *)fileName;
+ (NSString *)logFileNameStarted:(NSDate *)started now:(NSDate *)now;
+ (NSString *)freeLogFileNameStarted:(NSDate *)started now:(NSDate *)now;
+ (NSString *)phoneId;
+ (nullable NSURL *)zipLogFiles:(NSArray<NSString *> *)names inFolder:(NSString *)folder;
+ (void)removeFileAtPath:(NSString *)filePath;
+ (base::LogLevel)baseLevel:(LogLevel)level;

@end

// Subsystem and category are used for the OSLog.
NSString * const kLoggerSubsystem = [[NSBundle mainBundle] bundleIdentifier];
NSString * const kLoggerCategory = @"OM";
NSString * const kDocumentsPath =
    [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
// "<phone>/<yyyy-MM-dd>/<HHmmss>.log" in it, one file per launch and per drive, so that the folders of any phones
// and days merge into one tree.
NSString * const kLogsFolderPath = [kDocumentsPath stringByAppendingPathComponent:@"logs"];
// The single log file of the earlier versions.
NSString * const kOldLogFilePath = [kDocumentsPath stringByAppendingPathComponent:@"log.txt"];
NSString * const kZipLogsFileName = @"logs.zip";
NSString * const kPhoneIdKey = @"LogsPhoneId";
// The version of the trip log format, nogps::kLogFormat of the core.
int const kLogFormat = 2;
// A day of driving, 20 hours and more at about 6.5 MB an hour: the log of a drive is analysed afterwards.
unsigned long long const kMaxLogsTotalSize = 150'000'000;
// A file that reaches it ends, the lines after go to a new file: a long session is not one huge file. About 4.5 hours
// at 6.5 MB an hour.
unsigned long long const kMaxLogFileSize = 30'000'000;
// Opening a file walks the whole log tree to keep it under the limit, so a failure is not retried at once.
NSTimeInterval const kOpenRetrySeconds = 5;

// A file of the logs folder by its path in it.
static NSDictionary<NSFileAttributeKey, id> * FileAttributes(NSString * name)
{
  return [NSFileManager.defaultManager attributesOfItemAtPath:[kLogsFolderPath stringByAppendingPathComponent:name]
                                                        error:nil];
}

@implementation Logger

static BOOL _fileLoggingEnabled = NO;
// Read by the assert function of any thread: the pointer is replaced as a whole.
static void (^kAssertHandler)(NSString *, NSString *) = nil;
static void * kFileLoggingQueueKey = &kFileLoggingQueueKey;

+ (void)initialize
{
  if (self == [Logger class])
  {
    SetLogMessageFn(&LogMessage);
    SetAssertFunction(&AssertMessage);
  }
}

+ (Logger *)logger
{
  static Logger * logger = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{ logger = [[self alloc] init]; });
  return logger;
}

+ (dispatch_queue_t)fileLoggingQueue
{
  static dispatch_queue_t fileLoggingQueue = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    dispatch_queue_attr_t attributes =
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
    fileLoggingQueue = dispatch_queue_create("app.organicmaps.fileLoggingQueue", attributes);
    dispatch_queue_set_specific(fileLoggingQueue, kFileLoggingQueueKey, kFileLoggingQueueKey, nullptr);
  });
  return fileLoggingQueue;
}

- (instancetype)init
{
  self = [super init];
  if (self)
    _osLogger = os_log_create(kLoggerSubsystem.UTF8String, kLoggerCategory.UTF8String);
  return self;
}

// MARK: - Public

+ (void)setFileLoggingEnabled:(BOOL)fileLoggingEnabled
{
  fileLoggingEnabled ? [self enableFileLogging] : [self disableFileLogging];
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    LOG_SHORT(LINFO, ("Local time:", NSDate.date.description.UTF8String,
                      ", Time Zone:", NSTimeZone.defaultTimeZone.abbreviation.UTF8String));
  });
  LOG(LINFO, ("File logging is enabled:", [self fileLoggingEnabled] ? "YES" : "NO"));
}

+ (BOOL)fileLoggingEnabled
{
  __block BOOL fileLoggingEnabled = NO;
  [self runSyncOnFileLoggingQueue:^{ fileLoggingEnabled = _fileLoggingEnabled; }];
  return fileLoggingEnabled;
}

+ (void)log:(LogLevel)level message:(NSString *)message
{
  LOG_SHORT([self baseLevel:level], (message.UTF8String));
}

+ (BOOL)canLog:(LogLevel)level
{
  return [Logger baseLevel:level] >= base::g_LogLevel;
}

+ (nullable NSURL *)getLogFileURL
{
  if ([self fileLoggingEnabled])
  {
    // On the queue: no file is switched or deleted while it is zipped.
    __block NSArray<NSString *> * files;
    __block NSURL * zipURL;
    [self runSyncOnFileLoggingQueue:^{
      files = [self logFiles];
      if (files.count > 0)
        zipURL = [self zipLogFiles:files inFolder:kLogsFolderPath];
    }];
    if (files.count == 0)
      LOG(LERROR, ("No log files while file logging is enabled:", kLogsFolderPath.UTF8String));
    return zipURL;
  }
  else
  {
    // Fetch logs from the OSLog store.
    if (@available(iOS 15.0, *))
    {
      NSError * error;
      OSLogStore * store = [OSLogStore storeWithScope:OSLogStoreCurrentProcessIdentifier error:&error];

      if (error)
      {
        LOG(LERROR, (error.localizedDescription.UTF8String));
        return nil;
      }

      NSPredicate * predicate = [NSPredicate predicateWithFormat:@"subsystem == %@", kLoggerSubsystem];
      OSLogEnumerator * enumerator = [store entriesEnumeratorWithOptions:{}
                                                                position:nil
                                                               predicate:predicate
                                                                   error:&error];

      if (error)
      {
        LOG(LERROR, (error.localizedDescription.UTF8String));
        return nil;
      }

      NSMutableString * logString = [NSMutableString string];
      NSString * kNewLineStr = @"\n";

      id object;
      while (object = [enumerator nextObject])
      {
        if ([object isMemberOfClass:[OSLogEntryLog class]])
        {
          [logString appendString:[object composedMessage]];
          [logString appendString:kNewLineStr];
        }
      }

      if (logString.length == 0)
      {
        LOG(LINFO, ("OSLog entry is empty."));
        return nil;
      }

      // Named as a log file started now, in the same tree.
      NSFileManager * fileManager = NSFileManager.defaultManager;
      NSString * folder = [fileManager.temporaryDirectory URLByAppendingPathComponent:@"logs"].path;
      NSString * name = [self logFileNameStarted:NSDate.date now:NSDate.date];
      NSString * path = [folder stringByAppendingPathComponent:name];
      [fileManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
             withIntermediateDirectories:YES
                              attributes:nil
                                   error:nil];
      [fileManager createFileAtPath:path contents:[logString dataUsingEncoding:NSUTF8StringEncoding] attributes:nil];
      NSURL * zipURL = [self zipLogFiles:@[name] inFolder:folder];
      [self removeFileAtPath:folder];
      return zipURL;
    }
    else
    {
      return nil;
    }
  }
}

+ (nullable NSURL *)zipLogFilesOfDays:(NSSet<NSString *> *)days
{
  // On the queue: no file is switched or deleted while it is zipped.
  __block NSURL * zipURL;
  [self runSyncOnFileLoggingQueue:^{
    NSArray<NSString *> * files = [self logFilesOfDays:days];
    if (files.count > 0)
      zipURL = [self zipLogFiles:files inFolder:kLogsFolderPath];
  }];
  return zipURL;
}

/// The log files of the days "yyyy-MM-dd", of every phone, and the files they go on from. A trip that crossed midnight
/// travels with the file it began in: the next day has a file of the same start time. A drive that began in the same
/// second as another is "<HHmmss>-2.log" but goes on as "<HHmmss>.log", so the files are matched without the suffix and
/// both drives of that second are taken. A file that reached kMaxLogFileSize ended there and the trip went on in the
/// next file of the phone, so it travels with it as well.
+ (NSArray<NSString *> *)logFilesOfDays:(NSSet<NSString *> *)days
{
  NSArray<NSString *> * names = [self logFiles];
  NSMutableSet<NSString *> * taken = [NSMutableSet set];
  // A file goes on only into later ones: from the last to the first, the chain is known when it is asked.
  for (NSInteger i = names.count - 1; i >= 0; --i)
  {
    // "<phone>/<yyyy-MM-dd>/<HHmmss>.log": of every phone id.
    NSArray<NSString *> * parts = names[i].pathComponents;
    if (parts.count == 3 && [names[i].pathExtension isEqualToString:@"log"] &&
        ([days containsObject:parts[1]] || [self logFileAtIndex:i of:names goesOnInto:taken]))
      [taken addObject:names[i]];
  }
  NSMutableArray<NSString *> * files = [NSMutableArray array];
  for (NSString * name in names)
    if ([taken containsObject:name])
      [files addObject:name];
  return files;
}

+ (BOOL)logFileAtIndex:(NSUInteger)index of:(NSArray<NSString *> *)names goesOnInto:(NSSet<NSString *> *)taken
{
  NSString * name = names[index];
  NSArray<NSString *> * parts = name.pathComponents;
  // A file ends at the first line that would bring it to kMaxLogFileSize: not shorter than a line.
  unsigned long long const kSplitSlack = 100'000;
  unsigned long long const size =
      [NSFileManager.defaultManager attributesOfItemAtPath:[kLogsFolderPath stringByAppendingPathComponent:name]
                                                     error:nil]
          .fileSize;
  if (size + kSplitSlack >= kMaxLogFileSize && index + 1 < names.count && [taken containsObject:names[index + 1]] &&
      [names[index + 1].pathComponents.firstObject isEqualToString:parts[0]])
    return YES;

  NSString * start = [self startOfLogFile:parts[2]];
  NSString * next = [self dayAfter:parts[1]];
  if (next == nil)
    return NO;
  for (NSUInteger j = index + 1; j < names.count; ++j)
  {
    NSArray<NSString *> * otherParts = names[j].pathComponents;
    if (otherParts.count == 3 && [otherParts[0] isEqualToString:parts[0]] && [otherParts[1] isEqualToString:next] &&
        [[self startOfLogFile:otherParts[2]] isEqualToString:start] && [taken containsObject:names[j]])
      return YES;
  }
  return NO;
}

/// The start time "HHmmss" of the file name: without the ".log" and the "-N" of a second drive of the same second.
+ (NSString *)startOfLogFile:(NSString *)fileName
{
  return [fileName stringByReplacingOccurrencesOfString:@"(-[0-9]+)?\\.log$"
                                             withString:@""
                                                options:NSRegularExpressionSearch
                                                  range:NSMakeRange(0, fileName.length)];
}

/// The day after a folder name "yyyy-MM-dd", nil when it is not a day.
+ (nullable NSString *)dayAfter:(NSString *)day
{
  static NSDateFormatter * formatter;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd";
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    // No daylight saving: a day is always 24 hours.
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  });
  NSDate * date = [formatter dateFromString:day];
  return date ? [formatter stringFromDate:[date dateByAddingTimeInterval:24 * 60 * 60]] : nil;
}

+ (void)startTrip
{
  // On the queue: the lines logged before it are of the file before.
  [self runSyncOnFileLoggingQueue:^{
    [self closeFile];
    [self logger].started = nil;
    // A new drive is worth an attempt even if the last open failed.
    [self logger].retryOpen = nil;
  }];
}

+ (void)setAssertHandler:(void (^)(NSString *, NSString *))handler
{
  kAssertHandler = [handler copy];
}

+ (uint64_t)getLogFileSize
{
  __block uint64_t size = 0;
  [self runSyncOnFileLoggingQueue:^{
    for (NSString * name in [self logFiles])
      size += FileAttributes(name).fileSize;
  }];
  return size;
}

// MARK: - C++ injection

void LogMessage(base::LogLevel level, base::SrcPoint const & src, std::string const & message)
{
  [Logger logMessageWithLevel:level src:src message:message];
  CHECK_LESS(level, base::g_LogAbortLevel, ("Abort. Log level is too serious", level));
}

bool AssertMessage(base::SrcPoint const & src, std::string const & message)
{
  [Logger logMessageWithLevel:base::LCRITICAL src:src message:message];
  auto handler = kAssertHandler;
  if (handler)
    handler(@(DebugPrint(src).c_str()), @(message.c_str()));
  return true;
}

// MARK: - Private

+ (void)enableFileLogging
{
  [self runSyncOnFileLoggingQueue:^{
    if (![NSFileManager.defaultManager createDirectoryAtPath:kLogsFolderPath
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil] ||
        ![self openFileIfNeeded])
    {
      LOG(LERROR, ("Failed to open a log file in", kLogsFolderPath.UTF8String));
      [self disableFileLogging];
      return;
    }

    _fileLoggingEnabled = YES;
  }];
}

+ (void)disableFileLogging
{
  [self runSyncOnFileLoggingQueue:^{
    [self closeFile];
    [self logger].dayEnd = nil;
    [self removeFileAtPath:kLogsFolderPath];
    [self removeFileAtPath:kOldLogFilePath];

    _fileLoggingEnabled = NO;
  }];
}

+ (void)logMessageWithLevel:(base::LogLevel)level src:(base::SrcPoint const &)src message:(std::string const &)message
{
  // Build the log message string.
  auto & logHelper = base::LogHelper::Instance();
  std::ostringstream output;
  // TODO: (KK) Either guard this call, or refactor thread ids in logHelper.
  logHelper.WriteProlog(output, level);
  logHelper.WriteLog(output, src, message);

  auto const logString = output.str();

  // Log the message into the system log.
  os_log([self logger].osLogger, "%{public}s", logString.c_str());

  if (level < LINFO)
    dispatch_async([self fileLoggingQueue], ^{ [self tryWriteToFile:logString]; });
  else
    [self runSyncOnFileLoggingQueue:^{ [self tryWriteToFile:logString]; }];
}

+ (void)tryWriteToFile:(std::string const &)logString
{
  dispatch_assert_queue([self fileLoggingQueue]);
  if (!_fileLoggingEnabled || ![self openFileIfNeeded])
    return;

  NSFileHandle * fileHandle = [self logger].fileHandle;
  unsigned long long const size = [fileHandle seekToEndOfFile];
  [fileHandle writeData:[NSData dataWithBytes:logString.c_str() length:logString.length()]];
  if (size + logString.length() >= kMaxLogFileSize)
  {
    // The next line opens a new file.
    [self closeFile];
    [self logger].started = nil;
  }
}

/// Opens the file to write to: a new one after the launch and after startTrip, the same one in the folder of the new
/// day after midnight. Reports errors to the system log only: LOG() would come back here.
+ (BOOL)openFileIfNeeded
{
  dispatch_assert_queue([self fileLoggingQueue]);
  Logger * logger = [self logger];
  NSFileManager * fileManager = NSFileManager.defaultManager;
  NSDate * now = NSDate.date;
  // Opening a file walks the whole tree to keep it under the limit: a full disk would do it for every line.
  if (logger.fileHandle == nil && logger.retryOpen != nil && [now compare:logger.retryOpen] == NSOrderedAscending)
    return NO;
  if (logger.started == nil)
  {
    logger.started = now;
    logger.dayEnd = nil;
  }
  if (logger.dayEnd == nil || [now compare:logger.dayEnd] != NSOrderedAscending)
  {
    [self closeFile];
    NSCalendar * calendar = NSCalendar.currentCalendar;
    logger.dayEnd = [calendar dateByAddingUnit:NSCalendarUnitDay
                                         value:1
                                        toDate:[calendar startOfDayForDate:now]
                                       options:0];
    logger.fileName = [self freeLogFileNameStarted:logger.started now:now];
  }

  if (logger.fileHandle != nil)
    return YES;

  NSString * path = [kLogsFolderPath stringByAppendingPathComponent:logger.fileName];
  unsigned long long const size = [fileManager attributesOfItemAtPath:path error:nil].fileSize;
  if (size == 0)
  {
    // Before the folder of the file is made: it is empty yet.
    [self deleteOldestFiles];
    [fileManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:nil];
    [fileManager createFileAtPath:path contents:nil attributes:nil];
  }
  NSFileHandle * fileHandle = [NSFileHandle fileHandleForWritingAtPath:path];
  if (fileHandle == nil)
  {
    logger.retryOpen = [now dateByAddingTimeInterval:kOpenRetrySeconds];
    os_log_error(logger.osLogger, "Failed to open log file for writing %{public}s", path.UTF8String);
    return NO;
  }
  [fileHandle seekToEndOfFile];
  logger.fileHandle = fileHandle;
  logger.retryOpen = nil;

  if (size == 0)
  {
    // The time of a line is seconds since the launch: this line tells the readers of the file when that was.
    std::ostringstream anchor;
    // The first line of the file, which the tools read it by: its time is UTC, unlike the time of a line. The map
    // version is not known here: the core writes "MAPS ms=<unix ms> version=<number>" when the navigation starts and
    // when a drive starts a file, so a file this limit has begun in the middle of a drive has none.
    AppInfo * info = AppInfo.sharedInfo;
    NSString * trip = logger.fileName.lastPathComponent.stringByDeletingPathExtension;
    anchor << "LOGFMT " << kLogFormat << " ms=" << std::llround(now.timeIntervalSince1970 * 1000)
           << " phone=" << [self phoneId].UTF8String << " trip=" << trip.UTF8String
           << " app=" << info.bundleVersion.UTF8String << " build=" << info.buildNumber.UTF8String
           << " commit=" << info.gitHash.UTF8String << " om=" << info.upstreamVersion.UTF8String << std::endl;
    base::LogHelper::Instance().WriteProlog(anchor, LINFO);
    anchor << "Local time: " << now.description.UTF8String << std::endl;
    base::LogHelper::Instance().WriteProlog(anchor, LINFO);
    anchor << "NonGPS Maps: " << AppInfo.sharedInfo.fullVersion.UTF8String << std::endl;
    auto const anchorString = anchor.str();
    [fileHandle writeData:[NSData dataWithBytes:anchorString.c_str() length:anchorString.length()]];
  }
  return YES;
}

+ (void)closeFile
{
  Logger * logger = [self logger];
  [logger.fileHandle closeFile];
  logger.fileHandle = nil;
}

/// Deletes the oldest log files until all of them together take at most kMaxLogsTotalSize, then the folders left
/// empty.
+ (void)deleteOldestFiles
{
  NSArray<NSString *> * files =
      [[self logFiles] sortedArrayUsingComparator:^NSComparisonResult(NSString * a, NSString * b) {
        return [FileAttributes(a).fileModificationDate compare:FileAttributes(b).fileModificationDate];
      }];

  unsigned long long total = 0;
  for (NSString * name in files)
    total += FileAttributes(name).fileSize;

  NSFileManager * fileManager = NSFileManager.defaultManager;
  for (NSString * name in files)
  {
    if (total <= kMaxLogsTotalSize)
      break;
    unsigned long long const size = FileAttributes(name).fileSize;
    NSError * error;
    if ([fileManager removeItemAtPath:[kLogsFolderPath stringByAppendingPathComponent:name] error:&error])
      total -= size;
    else
      os_log_error([self logger].osLogger, "Failed to delete old log file %{public}s",
                   error.localizedDescription.UTF8String);
  }

  // The deepest first: a folder of a phone after the folders of its days.
  NSArray<NSString *> * paths =
      [[fileManager subpathsOfDirectoryAtPath:kLogsFolderPath error:nil] sortedArrayUsingSelector:@selector(compare:)];
  for (NSString * name in paths.reverseObjectEnumerator)
  {
    NSString * path = [kLogsFolderPath stringByAppendingPathComponent:name];
    BOOL isFolder = NO;
    if ([fileManager fileExistsAtPath:path isDirectory:&isFolder] && isFolder &&
        [fileManager contentsOfDirectoryAtPath:path error:nil].count == 0)
      [fileManager removeItemAtPath:path error:nil];
  }
}

/// The files of the logs folder and its subfolders by their paths in it, sorted: the files named as before the tree
/// too.
+ (NSArray<NSString *> *)logFiles
{
  NSFileManager * fileManager = NSFileManager.defaultManager;
  NSMutableArray<NSString *> * files = [NSMutableArray array];
  for (NSString * name in [[fileManager subpathsOfDirectoryAtPath:kLogsFolderPath
                                                            error:nil] sortedArrayUsingSelector:@selector(compare:)])
  {
    BOOL isFolder = NO;
    if (![name.lastPathComponent hasPrefix:@"."] &&
        [fileManager fileExistsAtPath:[kLogsFolderPath stringByAppendingPathComponent:name] isDirectory:&isFolder] &&
        !isFolder)
      [files addObject:name];
  }
  return files;
}

/// The path of a log file under the logs folder. A file is named by the time it was started at, and is in the folder
/// of the day it is written on: over midnight it goes on in the next folder under the same name.
+ (NSString *)logFileNameStarted:(NSDate *)started now:(NSDate *)now
{
  static NSDateFormatter * dayFormatter;
  static NSDateFormatter * timeFormatter;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    dayFormatter = [[NSDateFormatter alloc] init];
    dayFormatter.dateFormat = @"yyyy-MM-dd";
    timeFormatter = [[NSDateFormatter alloc] init];
    timeFormatter.dateFormat = @"HHmmss";
    for (NSDateFormatter * formatter in @[dayFormatter, timeFormatter])
    {
      formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
      // Follows a change of the time zone, as NSCalendar.currentCalendar of the day end does.
      formatter.timeZone = NSTimeZone.localTimeZone;
    }
  });
  return [NSString stringWithFormat:@"%@/%@/%@.log", [self phoneId], [dayFormatter stringFromDate:now],
                                    [timeFormatter stringFromDate:started]];
}

/// The name of a log file that no drive has written yet: two drives started in the same second would share
/// "<HHmmss>.log" and be read as one, so the second one gets "<HHmmss>-2.log".
+ (NSString *)freeLogFileNameStarted:(NSDate *)started now:(NSDate *)now
{
  NSString * name = [self logFileNameStarted:started now:now];
  NSFileManager * fileManager = NSFileManager.defaultManager;
  if (![fileManager fileExistsAtPath:[kLogsFolderPath stringByAppendingPathComponent:name]])
    return name;
  NSString * base = [name substringToIndex:name.length - @".log".length];
  // A file per second of a drive is far more than the app can start: the name is shared only if they all exist.
  for (int i = 2; i < 100; ++i)
  {
    NSString * next = [NSString stringWithFormat:@"%@-%d.log", base, i];
    if (![fileManager fileExistsAtPath:[kLogsFolderPath stringByAppendingPathComponent:next]])
      return next;
  }
  return name;
}

/// The model and a random id made once per install.
+ (NSString *)phoneId
{
  static NSString * phoneId;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    phoneId = [NSUserDefaults.standardUserDefaults stringForKey:kPhoneIdKey];
    if (phoneId != nil)
      return;

    struct utsname systemInfo;
    uname(&systemInfo);
    NSString * model = @(systemInfo.machine);
    model = [model stringByReplacingOccurrencesOfString:@"[^A-Za-z0-9]"
                                             withString:@"_"
                                                options:NSRegularExpressionSearch
                                                  range:NSMakeRange(0, model.length)];
    phoneId = [NSString stringWithFormat:@"%@-%04x", model, arc4random_uniform(0x10000)];
    [NSUserDefaults.standardUserDefaults setObject:phoneId forKey:kPhoneIdKey];
  });
  return phoneId;
}

+ (void)runSyncOnFileLoggingQueue:(dispatch_block_t)block
{
  if (dispatch_get_specific(kFileLoggingQueueKey) != nullptr)
    block();
  else
    dispatch_sync([self fileLoggingQueue], block);
}

/// Zips the files of the folder, given by their paths in it, as "logs/<path>": the same tree as the logs.zip of
/// Android, so that the zips of any phones and days unpack into one tree.
+ (nullable NSURL *)zipLogFiles:(NSArray<NSString *> *)names inFolder:(NSString *)folder
{
  std::vector<std::string> paths;
  std::vector<std::string> entries;
  for (NSString * name in names)
  {
    paths.push_back([folder stringByAppendingPathComponent:name].UTF8String);
    entries.push_back(std::string("logs/") + name.UTF8String);
  }
  NSString * zipPath =
      [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:kZipLogsFileName].path;
  if (!CreateZipFromFiles(paths, entries, zipPath.UTF8String))
  {
    LOG(LERROR, ("Failed to zip log files to", zipPath.UTF8String));
    return nil;
  }
  return [NSURL fileURLWithPath:zipPath];
}

+ (void)removeFileAtPath:(NSString *)filePath
{
  if ([NSFileManager.defaultManager fileExistsAtPath:filePath])
  {
    NSError * error;
    [NSFileManager.defaultManager removeItemAtPath:filePath error:&error];
    if (error)
      LOG(LERROR, (error.localizedDescription.UTF8String));
  }
}

+ (base::LogLevel)baseLevel:(LogLevel)level
{
  switch (level)
  {
  case LogLevelDebug: return LDEBUG;
  case LogLevelInfo: return LINFO;
  case LogLevelWarning: return LWARNING;
  case LogLevelError: return LERROR;
  case LogLevelCritical: return LCRITICAL;
  }
}

@end
