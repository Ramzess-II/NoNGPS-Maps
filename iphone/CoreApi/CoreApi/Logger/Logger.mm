#import "Logger.h"
#import <OSLog/OSLog.h>
#import <sys/utsname.h>
#import "AppInfo.h"

#include "base/logging.hpp"
#include "coding/zip_creator.hpp"

#include "map/nogps/version.hpp"

@interface Logger ()

@property(nullable, nonatomic) NSFileHandle * fileHandle;
@property(nonnull, nonatomic) NSDate * day;
/// The first moment of the next day: a line written at it or later goes to a new file.
@property(nullable, nonatomic) NSDate * dayEnd;
@property(nonatomic) NSUInteger part;
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
+ (BOOL)openFileIfNeeded:(NSUInteger)nextSize;
+ (void)closeFile;
+ (void)deleteOldestFiles;
+ (NSArray<NSURL *> *)logFiles;
+ (NSString *)logFileNameForDay:(NSDate *)day part:(NSUInteger)part;
+ (NSString *)phoneId;
+ (nullable NSURL *)zipLogFiles:(NSArray<NSURL *> *)files;
+ (void)removeFileAtPath:(NSString *)filePath;
+ (base::LogLevel)baseLevel:(LogLevel)level;

@end

// Subsystem and category are used for the OSLog.
NSString * const kLoggerSubsystem = [[NSBundle mainBundle] bundleIdentifier];
NSString * const kLoggerCategory = @"OM";
NSString * const kDocumentsPath =
    [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
// One file a day per phone in it: "log-dd-MM-yy-<phone>[.<part>].log".
NSString * const kLogsFolderPath = [kDocumentsPath stringByAppendingPathComponent:@"logs"];
// The single log file of the earlier versions.
NSString * const kOldLogFilePath = [kDocumentsPath stringByAppendingPathComponent:@"log.txt"];
NSString * const kZipLogsFileName = @"logs.zip";
NSString * const kPhoneIdKey = @"LogsPhoneId";
unsigned long long const kMaxLogFileSize = 3'000'000;
// A day of driving, 20 hours and more at about 6.5 MB an hour: the log of a drive is analysed afterwards.
unsigned long long const kMaxLogsTotalSize = 150'000'000;

static unsigned long long FileSize(NSURL * file)
{
  NSNumber * size;
  [file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
  return size.unsignedLongLongValue;
}

static NSString * LogFilePath(NSDate * day, NSUInteger part)
{
  return [kLogsFolderPath stringByAppendingPathComponent:[Logger logFileNameForDay:day part:part]];
}

@implementation Logger

static BOOL _fileLoggingEnabled = NO;
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
    __block NSArray<NSURL *> * files;
    __block NSURL * zipURL;
    [self runSyncOnFileLoggingQueue:^{
      files = [self logFiles];
      if (files.count > 0)
        zipURL = [self zipLogFiles:files];
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

      NSURL * logURL = [NSFileManager.defaultManager.temporaryDirectory
          URLByAppendingPathComponent:[self logFileNameForDay:NSDate.date part:0]];
      [NSFileManager.defaultManager createFileAtPath:logURL.path
                                            contents:[logString dataUsingEncoding:NSUTF8StringEncoding]
                                          attributes:nil];
      return [self zipLogFiles:@[logURL]];
    }
    else
    {
      return nil;
    }
  }
}

+ (nullable NSURL *)zipLogFilesPassingTest:(BOOL (^)(NSString * name))test
{
  // On the queue: no file is switched or deleted while it is zipped.
  __block NSURL * zipURL;
  [self runSyncOnFileLoggingQueue:^{
    NSMutableArray<NSURL *> * files = [NSMutableArray array];
    for (NSURL * file in [self logFiles])
      if (test(file.lastPathComponent))
        [files addObject:file];
    if (files.count > 0)
      zipURL = [self zipLogFiles:files];
  }];
  return zipURL;
}

+ (uint64_t)getLogFileSize
{
  __block uint64_t size = 0;
  [self runSyncOnFileLoggingQueue:^{
    for (NSURL * file in [self logFiles])
      size += FileSize(file);
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
        ![self openFileIfNeeded:0])
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
  if (!_fileLoggingEnabled || ![self openFileIfNeeded:logString.length()])
    return;

  NSFileHandle * fileHandle = [self logger].fileHandle;
  [fileHandle seekToEndOfFile];
  [fileHandle writeData:[NSData dataWithBytes:logString.c_str() length:logString.length()]];
}

/// Opens the file of today with room for nextSize more bytes: a new one on a new day or when the last one is full.
/// Reports errors to the system log only: LOG() would come back here.
+ (BOOL)openFileIfNeeded:(NSUInteger)nextSize
{
  dispatch_assert_queue([self fileLoggingQueue]);
  Logger * logger = [self logger];
  NSFileManager * fileManager = NSFileManager.defaultManager;
  NSDate * now = NSDate.date;
  if (logger.dayEnd == nil || [now compare:logger.dayEnd] != NSOrderedAscending)
  {
    // Goes on in the last file of today, if there is one.
    [self closeFile];
    NSCalendar * calendar = NSCalendar.currentCalendar;
    logger.day = now;
    logger.dayEnd = [calendar dateByAddingUnit:NSCalendarUnitDay
                                         value:1
                                        toDate:[calendar startOfDayForDate:now]
                                       options:0];
    logger.part = 0;
    while ([fileManager fileExistsAtPath:LogFilePath(logger.day, logger.part + 1)])
      ++logger.part;
  }

  if (logger.fileHandle != nil)
  {
    if (logger.fileHandle.offsetInFile + nextSize <= kMaxLogFileSize)
      return YES;
    [self closeFile];
  }

  NSString * path = LogFilePath(logger.day, logger.part);
  unsigned long long size = [fileManager attributesOfItemAtPath:path error:nil].fileSize;
  while (size > 0 && size + nextSize > kMaxLogFileSize)
  {
    path = LogFilePath(logger.day, ++logger.part);
    size = [fileManager attributesOfItemAtPath:path error:nil].fileSize;
  }

  if (size == 0)
  {
    [self deleteOldestFiles];
    [fileManager createFileAtPath:path contents:nil attributes:nil];
  }
  NSFileHandle * fileHandle = [NSFileHandle fileHandleForWritingAtPath:path];
  if (fileHandle == nil)
  {
    os_log_error(logger.osLogger, "Failed to open log file for writing %{public}s", path.UTF8String);
    return NO;
  }
  [fileHandle seekToEndOfFile];
  logger.fileHandle = fileHandle;

  if (size == 0)
  {
    // The time of a line is seconds since the launch: this line tells the readers of the file when that was.
    std::ostringstream anchor;
    base::LogHelper::Instance().WriteProlog(anchor, LINFO);
    anchor << "Local time: " << now.description.UTF8String << std::endl;
    base::LogHelper::Instance().WriteProlog(anchor, LINFO);
    anchor << "NonGPS add-on: " << nogps::kAddonVersion << " (" << AppInfo.sharedInfo.gitHash.UTF8String << ")"
           << std::endl;
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

/// Deletes the oldest log files until all of them together take at most kMaxLogsTotalSize.
+ (void)deleteOldestFiles
{
  NSArray<NSURL *> * files = [[self logFiles] sortedArrayUsingComparator:^NSComparisonResult(NSURL * a, NSURL * b) {
    NSDate * dateA;
    NSDate * dateB;
    [a getResourceValue:&dateA forKey:NSURLContentModificationDateKey error:nil];
    [b getResourceValue:&dateB forKey:NSURLContentModificationDateKey error:nil];
    return [dateA compare:dateB];
  }];

  unsigned long long total = 0;
  for (NSURL * file in files)
    total += FileSize(file);

  for (NSURL * file in files)
  {
    if (total <= kMaxLogsTotalSize)
      break;
    unsigned long long const size = FileSize(file);
    NSError * error;
    if ([NSFileManager.defaultManager removeItemAtURL:file error:&error])
      total -= size;
    else
      os_log_error([self logger].osLogger, "Failed to delete old log file %{public}s",
                   error.localizedDescription.UTF8String);
  }
}

+ (NSArray<NSURL *> *)logFiles
{
  NSArray<NSURL *> * files =
      [NSFileManager.defaultManager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:kLogsFolderPath]
                                  includingPropertiesForKeys:@[NSURLContentModificationDateKey, NSURLFileSizeKey]
                                                     options:NSDirectoryEnumerationSkipsHiddenFiles
                                                       error:nil];
  return files ?: @[];
}

+ (NSString *)logFileNameForDay:(NSDate *)day part:(NSUInteger)part
{
  static NSDateFormatter * formatter;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"dd-MM-yy";
    // Follows a change of the time zone, as NSCalendar.currentCalendar of the day end does.
    formatter.timeZone = NSTimeZone.localTimeZone;
  });
  NSString * name = [NSString stringWithFormat:@"log-%@-%@", [formatter stringFromDate:day], [self phoneId]];
  return part == 0 ? [name stringByAppendingString:@".log"]
                   : [name stringByAppendingFormat:@".%lu.log", static_cast<unsigned long>(part)];
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

+ (nullable NSURL *)zipLogFiles:(NSArray<NSURL *> *)files
{
  // The same layout as the logs.zip of Android.
  std::vector<std::string> paths;
  std::vector<std::string> names;
  for (NSURL * file in files)
  {
    paths.push_back(file.path.UTF8String);
    names.push_back(std::string("logs/") + file.lastPathComponent.UTF8String);
  }
  NSString * zipPath =
      [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:kZipLogsFileName].path;
  if (!CreateZipFromFiles(paths, names, zipPath.UTF8String))
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
