#include <iostream>
#include <chrono>
#include <exception>
#include <fstream>
#include <thread>
#include <cstdio>

#include "Generators/CppGenerator.h"
#include "Generators/MappingGenerator.h"
#include "Generators/IDAMappingGenerator.h"
#include "Generators/DumpspaceGenerator.h"

#include "Generators/Generator.h"

#import <Foundation/Foundation.h>

#include "main.h"
#include "Menu/Logger.h"

#include "Unreal/NameArray.h"

using namespace std::chrono_literals;

static std::string NSStringToStd(NSString* Value)
{
    if (!Value)
        return "";
    const char* Utf8 = [Value UTF8String];
    return Utf8 ? std::string(Utf8) : std::string();
}

static bool IsSuspiciousGameString(const std::string& Value)
{
    if (Value.empty() || Value.size() > 96)
        return true;

    size_t ControlChars = 0;
    for (unsigned char C : Value)
    {
        if (C < 0x20 || C == 0x7F)
            ++ControlChars;
    }

    return ControlChars > 0;
}

static void LoadBundleMetadata()
{
    NSBundle* Bundle = [NSBundle mainBundle];
    NSDictionary* Info = [Bundle infoDictionary];
    if (!Info)
        return;

    id Identifier = Info[@"CFBundleIdentifier"];
    id DisplayName = Info[@"CFBundleDisplayName"];
    if (!DisplayName)
        DisplayName = Info[@"CFBundleName"];
    id Version = Info[@"CFBundleShortVersionString"];
    if (!Version)
        Version = Info[@"CFBundleVersion"];

    Settings::Generator::BundleIdentifier = NSStringToStd(Identifier);
    Settings::Generator::BundleDisplayName = NSStringToStd(DisplayName);
    Settings::Generator::BundleVersion = NSStringToStd(Version);

    LogInfo("Bundle: %s | %s | v%s",
        Settings::Generator::BundleIdentifier.c_str(),
        Settings::Generator::BundleDisplayName.c_str(),
        Settings::Generator::BundleVersion.c_str());
}

void StartDump()
{
    try
    {
        std::this_thread::sleep_for(2s);

        LoadBundleMetadata();

        Settings::Config::DelayDumperStart();

        auto t_1 = std::chrono::high_resolution_clock::now();

        LogSuccess("Started Generation [Dumper-7]!\n");
        if (!Generator::InitEngineCore())
        {
            LogError("Dump stopped: engine core initialization failed (see log above).");
            return;
        }

        if (!Generator::InitInternal())
        {
            LogError("Dump stopped: internal generator initialization failed (see log above).");
            return;
        }

        /* PUBG: the reflected Kismet calls return undecoded FStrings on this
         * build, which is what produced values like "SaoTakrxr" and
         * "41.-++E+ees-.8on".  The host app's Info.plist is authoritative. */
        if (Settings::Internal::bIsPUBGProfile)
        {
            if (!Settings::Generator::BundleDisplayName.empty())
                Settings::Generator::GameName = Settings::Generator::BundleDisplayName;
            if (!Settings::Generator::BundleVersion.empty())
                Settings::Generator::GameVersion = Settings::Generator::BundleVersion;

            if (Settings::Generator::GameName.empty())
                Settings::Generator::GameName = "PUBG MOBILE";
            if (Settings::Generator::GameVersion.empty())
                Settings::Generator::GameVersion = "UnknownVersion";

            LogInfo("PUBG profile: using bundle metadata for GameName/GameVersion");
        }
        else if (Settings::Generator::GameName.empty() && Settings::Generator::GameVersion.empty())
        {
            FString Name;
            FString Version;
            UEClass Kismet = ObjectArray::FindClassFast("KismetSystemLibrary");

            if (!Kismet)
            {
                LogError("KismetSystemLibrary not found; using fallback game name/version.");
            }
            else if (Off::InSDK::ProcessEvent::PEOffset == 0)
            {
                LogError("ProcessEvent was not resolved; skipping GetGameName/GetEngineVersion.");
            }
            else
            {
                UEFunction GetGameName = Kismet.GetFunction("KismetSystemLibrary", "GetGameName");
                UEFunction GetEngineVersion = Kismet.GetFunction("KismetSystemLibrary", "GetEngineVersion");

                if (GetGameName)
                    Kismet.ProcessEvent(GetGameName, &Name);
                else
                    LogError("KismetSystemLibrary::GetGameName not found.");

                if (GetEngineVersion)
                    Kismet.ProcessEvent(GetEngineVersion, &Version);
                else
                    LogError("KismetSystemLibrary::GetEngineVersion not found.");

                Settings::Generator::GameName = Name.ToString();
                Settings::Generator::GameVersion = Version.ToString();
            }
        }

        if (Settings::Generator::GameName.empty())
            Settings::Generator::GameName = "UnknownGame";
        if (Settings::Generator::GameVersion.empty())
            Settings::Generator::GameVersion = "UnknownVersion";

        /* Reject obviously broken reflected strings on non-PUBG targets. */
        if (!Settings::Internal::bIsPUBGProfile)
        {
            if (IsSuspiciousGameString(Settings::Generator::GameName))
            {
                if (!Settings::Generator::BundleDisplayName.empty())
                    Settings::Generator::GameName = Settings::Generator::BundleDisplayName;
                else
                    Settings::Generator::GameName = "UnknownGame";
            }

            if (IsSuspiciousGameString(Settings::Generator::GameVersion))
            {
                if (!Settings::Generator::BundleVersion.empty())
                    Settings::Generator::GameVersion = Settings::Generator::BundleVersion;
                else
                    Settings::Generator::GameVersion = "UnknownVersion";
            }
        }

        /* Match SDKGen's per-game folder name: "<Game>_(v<Version>)_64Bit"
         * with the per-package headers inside "SDK/". */
        if (Settings::Internal::bIsPUBGProfile)
        {
            CppGenerator::MainFolderName = Settings::Generator::GameName + "_(v" + Settings::Generator::GameVersion + ")_64Bit";
            CppGenerator::SubfolderName = "SDK";
            LogInfo("PUBG output folder: %s", CppGenerator::MainFolderName.c_str());
        }

        LogInfo("GameName: %s\n", Settings::Generator::GameName.c_str());
        LogInfo("GameVersion: %s\n\n", Settings::Generator::GameVersion.c_str());


        Generator::Generate<CppGenerator>();
        Generator::Generate<MappingGenerator>();
        Generator::Generate<IDAMappingGenerator>();
        Generator::Generate<DumpspaceGenerator>();


        auto t_C = std::chrono::high_resolution_clock::now();
        auto ms_int_ = std::chrono::duration_cast<std::chrono::milliseconds>(t_C - t_1);
        std::chrono::duration<double, std::milli> ms_double_ = t_C - t_1;

        LogInfo("\n\nGenerating SDK took (%fms)\n\n\n", ms_double_.count());
    }
    catch (const std::exception& Ex)
    {
        LogError("Dump aborted with exception: %s", Ex.what());
    }
    catch (...)
    {
        LogError("Dump aborted with an unknown exception.");
    }
}
