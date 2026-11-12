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

void StartDump()
{
    try
    {
        std::this_thread::sleep_for(2s);

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

        if (Settings::Generator::GameName.empty() && Settings::Generator::GameVersion.empty())
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
