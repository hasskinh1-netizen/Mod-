#pragma once
#include <cstddef>
#include <mutex>
#include <string>
#include <vector>

// Log entry types map to the HUD badges:
//   0 = INFO, 1 = ERR, 2 = OK
struct Output {
    std::string text;
    std::string time;
    int type;
};

class Console {
public:
    static Console& Get();

    std::vector<Output> outputArr;
    mutable std::mutex logMutex;
    bool autoScroll = true;
    bool visible = true;

    // -1 = ALL, 0 = INFO, 1 = ERR, 2 = OK
    int filter = -1;

    void log(const std::string& text);
    void logError(const std::string& text);
    void logInfo(const std::string& text);
    void clearLogs();

    std::vector<Output> Snapshot() const;
    size_t CountType(int type) const;
};
