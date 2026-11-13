#include "Console.h"
#include <ctime>
#include <cstdio>

Console& Console::Get() {
    static Console instance;
    return instance;
}

// Helper for time string
static std::string GetTimeStr() {
    time_t now = time(0);
    struct tm tstruct;
    char buf[80];
    tstruct = *localtime(&now);
    strftime(buf, sizeof(buf), "%H:%M:%S", &tstruct);
    return std::string(buf);
}

void Console::log(const std::string& text) {
    std::lock_guard<std::mutex> lock(logMutex);
    outputArr.push_back({ text, GetTimeStr(), 0 });
}

void Console::logError(const std::string& text) {
    std::lock_guard<std::mutex> lock(logMutex);
    outputArr.push_back({ text, GetTimeStr(), 1 });
}

void Console::logInfo(const std::string& text) {
    std::lock_guard<std::mutex> lock(logMutex);
    outputArr.push_back({ text, GetTimeStr(), 2 });
}

void Console::clearLogs() {
    std::lock_guard<std::mutex> lock(logMutex);
    outputArr.clear();
}

std::vector<Output> Console::Snapshot() const {
    std::lock_guard<std::mutex> lock(logMutex);
    return outputArr;
}

size_t Console::CountType(int type) const {
    std::lock_guard<std::mutex> lock(logMutex);
    size_t Count = 0;
    for (const Output& Entry : outputArr) {
        if (Entry.type == type) {
            ++Count;
        }
    }
    return Count;
}
