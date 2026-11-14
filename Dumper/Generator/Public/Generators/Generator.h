#pragma once

#include <filesystem>

#include "Unreal/ObjectArray.h"
#include "Managers/DependencyManager.h"
#include "Managers/MemberManager.h"
#include "HashStringTable.h"


namespace fs = std::filesystem;

void DumpEditorOnlyMetadata(const fs::path& DumperFolder);
void DumpUEOffsetsHeader(const fs::path& DumperFolder);

/* PUBG Mobile extras.  DumpPUBGOffsetsHeader() resolves the macro table used
 * by common PUBG cheat bases from the live SDK dump and writes PUBGOffsets.hpp. */
void DumpPUBGOffsetsHeader(const fs::path& GameFolder);

/* PUBG Mobile extras.  DumpPUBGReportFunctions() scans the live UObject array
 * for UFunction objects related to reports/complaints/anti-cheat and writes
 * PUBGReportFunctions.txt plus PUBGReportFunctions.hpp with unslid offsets and
 * any resolvable native vtable slot. */
void DumpPUBGReportFunctions(const fs::path& GameFolder);

/* SDKGen-compatible companion files ("Offsets.txt", "LastStatus.txt",
 * "BootLog.txt", "NamesDump.txt", "ObjectsDump.txt" and "dump.log").
 * GameFolder is the per-game folder that contains SDK.hpp + SDK/. */
void DumpSDKGenCompanionFiles(const fs::path& GameFolder);

template<typename GeneratorType>
concept GeneratorImplementation = requires(GeneratorType t)
{
    /* Require static variables of type */
    GeneratorType::PredefinedMembers;
    requires(std::same_as<decltype(GeneratorType::PredefinedMembers), PredefinedMemberLookupMapType>);

    GeneratorType::MainFolderName;
    requires(std::same_as<decltype(GeneratorType::MainFolderName), std::string>);
    GeneratorType::SubfolderName;
    requires(std::same_as<decltype(GeneratorType::SubfolderName), std::string>);

    GeneratorType::MainFolder;
    requires(std::same_as<decltype(GeneratorType::MainFolder), fs::path>);
    GeneratorType::Subfolder;
    requires(std::same_as<decltype(GeneratorType::Subfolder), fs::path>);
    
    /* Require static functions */
    GeneratorType::Generate();

    GeneratorType::InitPredefinedMembers();
    GeneratorType::InitPredefinedFunctions();
};

class Generator
{
private:
    friend class GeneratorTest;

private:
    static inline fs::path DumperFolder;
    static inline bool bDumpedGObjects = false;
	static inline bool bDumepdEditorOnlyMetadata = false;

public:
    static bool InitEngineCore();
    static bool InitInternal();

private:
    static bool SetupDumperFolder();

    static bool SetupFolders(std::string& FolderName, fs::path& OutFolder);
    static bool SetupFolders(std::string& FolderName, fs::path& OutFolder, std::string& SubfolderName, fs::path& OutSubFolder);

public:
    template<GeneratorImplementation GeneratorType>
    static void Generate() 
    { 
        if (DumperFolder.empty())
        {
            if (!SetupDumperFolder())
                return;

            if (!bDumpedGObjects)
            {
                bDumpedGObjects = true;
                ObjectArray::DumpObjects(DumperFolder);

                if (Settings::Internal::bUseFProperty)
                    ObjectArray::DumpObjectsWithProperties(DumperFolder);
            }

            if (!bDumepdEditorOnlyMetadata)
            {
                bDumepdEditorOnlyMetadata = true;
                DumpEditorOnlyMetadata(DumperFolder);
            }

            DumpUEOffsetsHeader(DumperFolder);
        }

        if (!SetupFolders(GeneratorType::MainFolderName, GeneratorType::MainFolder, GeneratorType::SubfolderName, GeneratorType::Subfolder))
            return;

        GeneratorType::InitPredefinedMembers();
        GeneratorType::InitPredefinedFunctions();

        MemberManager::SetPredefinedMemberLookupPtr(&GeneratorType::PredefinedMembers);

        GeneratorType::Generate();
    };
};
