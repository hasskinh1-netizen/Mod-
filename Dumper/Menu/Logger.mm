//
//  Logger.mm
//  Dumper
//
//  Created by Euclid Jan Guillermo on 12/8/25.
//

#include "Logger.h"
#include "Console.h" // Your Console class
#import <Foundation/Foundation.h>
#include <cstdarg>
#include <cstdio>
#include <mutex>
#include <string>

// Persist logs so a crash can still be diagnosed after the process dies, and
// mirror them to the system log (visible in Console.app / idevice syslog).
static void AppendToLogFile(const char* Line)
{
    static std::mutex FileMutex;
    static FILE* LogFile = nullptr;

    std::lock_guard<std::mutex> Lock(FileMutex);

    if (!LogFile)
    {
        NSString* Documents = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        if (!Documents)
            return;

        NSString* Path = [Documents stringByAppendingPathComponent:@"Dumper.log"];
        LogFile = fopen(Path.fileSystemRepresentation, "a");
    }

    if (LogFile)
    {
        fputs(Line, LogFile);
        fputc('\n', LogFile);
        fflush(LogFile);
    }
}

// Helper to format string and send to console
static void LogToConsole(int type, const char* fmt, va_list args) {
    char buffer[2048];
    vsnprintf(buffer, sizeof(buffer), fmt, args);

    AppendToLogFile(buffer);
    NSLog(@"[Dumper] %s", buffer);

    std::string msg(buffer);

    // Assuming Console follows Singleton pattern or global instance
    // Type 0 = Info/Default, 1 = Error, 2 = Success/Special
    if (type == 1) {
        Console::Get().logError(msg);
    } else if (type == 2) {
        Console::Get().logInfo(msg); // Reusing logInfo for "Success" style if available, or just log
    } else {
        Console::Get().log(msg);
    }
}

void LogInfo(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    LogToConsole(0, fmt, args);
    va_end(args);
}

void LogError(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    LogToConsole(1, fmt, args);
    va_end(args);
}

void LogSuccess(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    LogToConsole(2, fmt, args);
    va_end(args);
}
