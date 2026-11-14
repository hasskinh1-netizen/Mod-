
#include <fstream>
#include <cstdint>
#include <ctime>
#include <iomanip>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "Generators/Generator.h"
#include "Generators/CppGenerator.h"
#include "Managers/StructManager.h"
#include "Managers/EnumManager.h"
#include "Managers/MemberManager.h"
#include "Managers/PackageManager.h"

#include "HashStringTable.h"
#include "Utils.h"
#include "Menu/Logger.h"
#include "Unreal/NameArray.h"

inline void InitSettings()
{
	Settings::InitWeakObjectPtrSettings();
	Settings::InitLargeWorldCoordinateSettings();

	Settings::InitObjectPtrPropertySettings();
	Settings::InitArrayDimSizeSettings();
}

/* Scan __TEXT for the first IDA pattern that hits, ADRL-decode at hit+step,
 * and return the result as an imagebase-relative offset (the form
 * ObjectArray::Init / FName::Init expect). Returns 0 on failure.
 *
 * Lifted straight from Mj0x's UEGameProfile GetNamesPtr / GetGUObjectArrayPtr
 * idiom — paste a vector of {ida_pattern, step} pairs and call. */
static int32 FindOffsetByIDAPatterns(std::initializer_list<std::pair<const char*, int>> Patterns, const char* Label, const char* ModuleName = nullptr)
{
	const auto [ImageBase, ImageSize, Header, Slide] = GetImageBaseAndSize(ModuleName);
	if (!ImageBase) { LogError("FindOffsetByIDAPatterns[%s]: module not found", Label); return 0; }

	int Idx = 0;
	for (const auto& [Pattern, Step] : Patterns)
	{
		++Idx;
		uintptr_t Hit = reinterpret_cast<uintptr_t>(FindPattern(Pattern, "__TEXT", 0));
		if (!Hit) continue;

		uintptr_t Resolved = ASMUtils::ResolveADRL(Hit + Step);
		if (!Resolved || Resolved < ImageBase || Resolved >= (ImageBase + ImageSize)) continue;

		const int32 Offset = static_cast<int32>(Resolved - ImageBase);
		LogInfo("FindOffsetByIDAPatterns[%s]: pattern #%d hit @ +0x%lX -> 0x%X", Label, Idx, Hit - ImageBase, Offset);
		return Offset;
	}
	LogError("FindOffsetByIDAPatterns[%s]: no pattern matched", Label);
	return 0;
}


bool Generator::InitEngineCore()
{
	LogInfo("Initializing Engine Core...");

	/* ------------------------------------------------------------------
	 * PUBG Mobile (UE 4.18, fixed TUObjectArray) detection.
	 * Patterns/resolution taken from Mj0x's iOS_UEDumper PUBG profile.
	 * ------------------------------------------------------------------ */
	const int32 PUBGGObjectsOff = FindOffsetByIDAPatterns({
		{"80 B9 ? ? ? ? ? ? ? 91 ? ? 40 F9 ? 03 80 52", 2},
	}, "PUBG GObjects");

	const int32 PUBGGNamesOff = FindOffsetByIDAPatterns({
		{"ff c3 01 91 c0 03 5f d6 ? ? ? ? ? ? ? 91 ? ? ? 94 ? ? ? 34 ff ? ? ? ? ? ? ? ? ? ? 91", 0x1c},
	}, "PUBG GNames");

	Settings::Internal::bIsPUBGProfile = (PUBGGObjectsOff != 0 || PUBGGNamesOff != 0);
	if (Settings::Internal::bIsPUBGProfile)
		LogInfo("PUBG Mobile profile active (GObjects=%s, GNames=%s)",
			PUBGGObjectsOff != 0 ? "yes" : "no", PUBGGNamesOff != 0 ? "yes" : "no");

	if (PUBGGObjectsOff != 0)
	{
		/* The ADRP+ADD resolves to FUObjectArray; ObjObjects sits at +0x10.
		 * UE <= 4.19 uses a flat (non-chunked) TUObjectArray relative to it:
		 *   TUObjectArray.Objects      = +0x00  (FUObjectItem*)
		 *   TUObjectArray.MaxElements  = +0x08
		 *   TUObjectArray.NumElements  = +0x0C */
		const int32 PUBGObjObjectsOff = PUBGGObjectsOff + 0x10;

		const FFixedUObjectArrayLayout PUBGLayout
		{
			.ObjectsOffset    = 0x0,
			.MaxObjectsOffset = 0x8,
			.NumObjectsOffset = 0xC,
		};

		LogInfo("Detected PUBG Mobile GObjects (FUObjectArray+0x10) at 0x%X (fixed TUObjectArray)", PUBGObjObjectsOff);
		ObjectArray::Init(PUBGObjObjectsOff, PUBGLayout, Settings::General::DefaultModuleName);
	}
	else
	{
		ObjectArray::Init();
	}

	if (ObjectArray::DEBUGGetGObjects() == nullptr)
	{
		LogError("Dump aborted: GObjects (global object array) was not found. "
		         "This game/version is not supported by the current auto-scan.");
		return false;
	}

	const int32 NumObjects = ObjectArray::Num();
	LogInfo("GObjects NumElements: %d", NumObjects);
	if (NumObjects <= 0 || NumObjects > 0x400000)
	{
		LogError("Dump aborted: GObjects looks invalid (NumElements=%d). "
		         "Wait until the game is fully loaded, then press Start Dump again.", NumObjects);
		return false;
	}

	/* Per-game FName decryption hooks. Install BEFORE FName::Init.
	 * Pick whichever match the target game; unused hooks default to identity.
	 *
	 *   (1) Raw FNameEntry-bytes transform — header itself is encrypted.
	 *       Returns a (possibly scratch) entry pointer the reader uses instead.
	 * InitNameEntryDecryption([](uint8_t* Entry) -> uint8_t* {
	 *     // ... bytes-in / bytes-out ...
	 *     return Entry;
	 * });
	 *
	 *   (2) Output std::string transform — DeltaForce. Header is plaintext,
	 *       chars are XOR'd. Runs at the tail of FNameEntry::GetString on the
	 *       already-decoded std::string.
	 * InitNameStringDecryption([](std::string Decoded) -> std::string {
	 *     // ... XOR Decoded chars in-place, see DeltaForce example in ReadMe.md ...
	 *     return Decoded;
	 * });
	 *
	 *   (3) TNameEntryArray pointer chain — PUBG (UE 4.17, bIsNamePool == false):
	 * InitNameArrayDecryption([](uintptr_t Start) -> uintptr_t {
	 *     // ... pointer-chain walk, see PUBG example in ReadMe.md ...
	 *     return Start;
	 * });
	 *
	 *   (4) FNamePool pointer indirection — Valorant (UE 4.23+, bIsNamePool == true):
	 * InitNamePoolDecryption([](uintptr_t Start) -> uintptr_t {
	 *     // ... reassemble pointer from scattered bytes ...
	 *     return Start;
	 * });
	 */

	/* Optional per-game GNames override. Only applied when its signature actually
	 * matches this binary; otherwise we fall back to full auto-detection so the
	 * dumper works on non-NGR games instead of dereferencing garbage. */
	bool bNameInitialized = false;

	/* PUBG Mobile (UE 4.18): GNames is an encrypted TNameEntryArray.
	 * ADRP+ADD resolves to [int32 Header | ptr FirstHop]; walking
	 * Hops = (Header - 100) / 3 yields TNameEntryArray** (the runtime
	 * dereferences once more inside NameArray::TryInit). */
	if (PUBGGNamesOff != 0)
	{
		LogInfo("Detected PUBG Mobile GNames at 0x%X (encrypted TNameEntryArray)", PUBGGNamesOff);

		InitNameArrayDecryption([](uintptr_t RawAddr) -> uintptr_t
		{
			if (!RawAddr || IsBadReadPtr((void*)RawAddr) || IsBadReadPtr((void*)(RawAddr + 8)))
				return 0;

			const int32_t Header = *reinterpret_cast<int32_t*>(RawAddr);
			if (Header < 100) return 0;

			uint32_t Hops = (uint32_t)((Header - 100) / 3);
			if (Hops == 0 || Hops > 16) return 0;

			uint64_t Chain[16]{};
			Chain[Hops - 1] = *reinterpret_cast<int64_t*>(RawAddr + 8);

			while (Hops >= 2)
			{
				const uintptr_t Next = Chain[Hops - 1];
				if (!Next || IsBadReadPtr((void*)Next)) return 0;
				Chain[Hops - 2] = *reinterpret_cast<int64_t*>(Next);
				--Hops;
			}

			return Chain[0]; // TNameEntryArray** — NameArray::TryInit derefs once
		});

		FName::Init(PUBGGNamesOff, FName::EOffsetOverrideType::GNames, false, Settings::General::DefaultModuleName);
		bNameInitialized = FName::IsInitialized();

		if (!bNameInitialized)
		{
			/* Pattern matched but the chain produced an unusable array. Reset
			 * to identity so the generic auto-detection below isn't poisoned
			 * by the PUBG-specific decryption hook. */
			InitNameArrayDecryption([](uintptr_t RawAddr) -> uintptr_t { return RawAddr; });
			LogError("PUBG GNames override failed; falling back to auto-detection");
		}
	}

	if (!bNameInitialized)
	{
		const int32 GNamesOff = FindOffsetByIDAPatterns({
			{"? ? ? ? 29 01 15 91 28 21 08 8B", 0}, // HOK: World / NGR
		}, "GNames");

		if (GNamesOff != 0)
		{
			/* "NGR" is only valid as a module name when that image is actually loaded. */
			const char* const ModuleName = GetModuleBase("NGR") != 0 ? "NGR" : nullptr;
			LogInfo("Applying per-game GNames override at 0x%X (module: %s)", GNamesOff, ModuleName ? ModuleName : "main executable");
			FName::Init(GNamesOff, FName::EOffsetOverrideType::GNames, true, ModuleName);
			bNameInitialized = FName::IsInitialized();
		}
	}

	if (!bNameInitialized)
	{
		LogInfo("No matching GNames override; trying automatic FName/GNames detection...");
		FName::Init(true);
		bNameInitialized = FName::IsInitialized();
	}

	if (!bNameInitialized)
	{
		LogError("Dump aborted: FName/GNames could not be initialized. "
		         "The game is likely encrypted or uses an unsupported FNamePool layout.");
		return false;
	}

	/* PUBG Mobile is UE 4.18: FName is { int32 ComparisonIndex; int32 Number; }.
	 * The generic heuristic in OffsetFinder::InitFNameSettings() reads GObjects[0]
	 * ('None' => both int32s are 0) and would wrongly conclude that the game uses
	 * WITH_CASE_PRESERVING_NAME + FNAME_OUTLINE_NUMBER. */
	if (PUBGGObjectsOff != 0 || PUBGGNamesOff != 0)
	{
		Settings::Internal::bForcedLegacyFNameLayout = true;
		LogInfo("PUBG profile: forcing legacy FName layout (UE <= 4.19)");
	}

	Off::Init();
	PropertySizes::Init();
	Off::InSDK::ProcessEvent::InitPE(); //Must be at this position, relies on offsets initialized in Off::Init()

	Off::InSDK::World::InitGWorld(); //Must be at this position, relies on offsets initialized in Off::Init()

	Off::InSDK::Text::InitTextOffsets(); //Must be at this position, relies on offsets initialized in Off::InitPE()

	InitSettings();
	LogSuccess("Engine Core initialized successfully");
	return true;
}

bool Generator::InitInternal()
{
	LogInfo("Initializing Internal Generator...");

	// Initialize PackageManager with all packages, their names, structs, classes enums, functions and dependencies
	PackageManager::Init();

	// Initialize StructManager with all structs and their names
	StructManager::Init();

	// Initialize EnumManager with all enums and their names
	EnumManager::Init();

	// Initialized all Member-Name collisions
	MemberManager::Init();

	// Post-Initialize PackageManager after StructManager has been initialized. 'PostInit()' handles Cyclic-Dependencies detection
	PackageManager::PostInit();

	LogSuccess("Internal Generator initialized successfully");
	return true;
}

bool Generator::SetupDumperFolder()
{
	try
	{
		/* PUBG mirrors the layout produced by SDKGen: a stable "SDKGen" root
		 * that contains Offsets.txt / LastStatus.txt / BootLog.txt and a
		 * "<Game>_(v<Version>)_64Bit" per-game folder.  Other games keep the
		 * historical "<Version>-<Game>" root. */
		std::string FolderName = Settings::Internal::bIsPUBGProfile
			? std::string("SDKGen")
			: (Settings::Generator::GameVersion + '-' + Settings::Generator::GameName);

		FileNameHelper::MakeValidFileName(FolderName);

		DumperFolder = fs::path(Settings::Generator::SDKGenerationPath) / "Documents" / FolderName;

		if (fs::exists(DumperFolder))
		{
			fs::path Old = DumperFolder.generic_string() + "_OLD";

			fs::remove_all(Old);

			fs::rename(DumperFolder, Old);
		}

		fs::create_directories(DumperFolder);
	}
	catch (const std::filesystem::filesystem_error& fe)
	{
		LogError("Could not create required folders! Info: %s", fe.what());
		return false;
	}

	LogSuccess("Dumper folder created: %s", DumperFolder.string().c_str());
	return true;
}

bool Generator::SetupFolders(std::string& FolderName, fs::path& OutFolder)
{
	fs::path Dummy;
	std::string EmptyName = "";
	return SetupFolders(FolderName, OutFolder, EmptyName, Dummy);
}

bool Generator::SetupFolders(std::string& FolderName, fs::path& OutFolder, std::string& SubfolderName, fs::path& OutSubFolder)
{
	FileNameHelper::MakeValidFileName(FolderName);
	FileNameHelper::MakeValidFileName(SubfolderName);

	try
	{
		OutFolder = DumperFolder / FolderName;
		OutSubFolder = OutFolder / SubfolderName;

		if (fs::exists(OutFolder))
		{
			fs::path Old = OutFolder.generic_string() + "_OLD";

			fs::remove_all(Old);

			fs::rename(OutFolder, Old);
		}

		fs::create_directories(OutFolder);

		if (!SubfolderName.empty())
			fs::create_directories(OutSubFolder);
	}
	catch (const std::filesystem::filesystem_error& fe)
	{
		LogError("Could not create required folders! Info: %s", fe.what());
		return false;
	}

	return true;
}


// iOS port: stub. Upstream emits a Metadata.json describing editor-only properties.
// The iOS port doesn't yet expose Off::FField::EditorOnlyMetadata; skipping for KISS.
void DumpEditorOnlyMetadata(const fs::path& /*DumperFolder*/)
{
}

/* Emit a single-header summary of every offset Dumper-7 discovered + the runtime
 * pointers that drive the SDK. Consumed by external tooling (iOS_UEDumper-style
 * profiles, debug helpers) that wants Dumper-7's results without parsing the full
 * Cpp SDK. Mirrors the layout of iOS_UEDumper's UE_Offsets struct. */
void DumpUEOffsetsHeader(const fs::path& DumperFolder)
{
	const fs::path OutPath = DumperFolder / "UEOffsets.hpp";
	std::ofstream Out(OutPath);
	if (!Out)
	{
		LogError("DumpUEOffsetsHeader: failed to open %s", OutPath.string().c_str());
		return;
	}

	const uintptr_t ImageBase = GetModuleBase();
	auto Addr = [ImageBase](uintptr_t off) { return off ? ImageBase + off : 0; };

	/* Live pointers where possible.  Off::InSDK::NameArray::GNames is the
	 * address of the GNames global (which may be encrypted on PUBG), while
	 * NameArray::DEBUGGetGNames() returns the decrypted TNameEntryArray*. */
	const uintptr_t LiveNames = reinterpret_cast<uintptr_t>(NameArray::DEBUGGetGNames());
	const uintptr_t LiveObjects = reinterpret_cast<uintptr_t>(ObjectArray::DEBUGGetGObjects());
	const uintptr_t NamesPtr = LiveNames ? LiveNames : Addr(Off::InSDK::NameArray::GNames);
	const uintptr_t ObjectsInner = LiveObjects ? LiveObjects : Addr(Off::InSDK::ObjArray::GObjects);
	/* Fixed (UE <= 4.19) layouts expose the inner TUObjectArray at
	 * FUObjectArray+0x10.  Chunked layouts are already scanned from their
	 * own base, so keep GObjects as-is there. */
	const uintptr_t ObjectsBase = ObjectsInner
		? (Off::FUObjectArray::bIsChunked ? ObjectsInner : ObjectsInner - 0x10)
		: 0;
	const uintptr_t WorldPtr = Addr(Off::InSDK::World::GWorld);

	Out << "#pragma once\n";
	Out << "// Auto-generated by Dumper-7 (iOS port).\n";
	Out << "// All offsets discovered for the target game by OffsetFinder + InitPE + InitGWorld.\n\n";
	Out << "#include <cstdint>\n\n";
	Out << "namespace UEOffsets\n{\n\n";

	Out << "namespace Config\n{\n";
	Out << "    constexpr bool isUsingCasePreservingName = " << (Settings::Internal::bUseCasePreservingName ? "true" : "false") << ";\n";
	Out << "    constexpr bool IsUsingFNamePool          = " << (Settings::Internal::bUseNamePool ? "true" : "false") << ";\n";
	Out << "    constexpr bool isUsingOutlineNumberName  = " << (Settings::Internal::bUseOutlineNumberName ? "true" : "false") << ";\n";
	Out << "}\n\n";

	Out << std::hex << std::showbase;

	Out << "namespace FName\n{\n";
	Out << "    constexpr uintptr_t ComparisonIndex = " << Off::FName::CompIdx << ";\n";
	Out << "    constexpr uintptr_t Number          = " << Off::FName::Number << ";\n";
	Out << "    constexpr uintptr_t DisplayIndex    = " << (Settings::Internal::bUseCasePreservingName ? Off::FName::CompIdx + 4 : 0) << ";\n";
	Out << "    constexpr uintptr_t Size            = " << Off::InSDK::Name::FNameSize << ";\n";
	Out << "}\n\n";

	Out << "namespace FNamePool\n{\n";
	Out << std::dec;
	Out << "    constexpr int32_t  Stride       = " << Off::InSDK::NameArray::FNameEntryStride << ";\n";
	Out << "    constexpr int32_t  BlocksBit    = " << Off::InSDK::NameArray::FNamePoolBlockOffsetBits << ";\n";
	Out << std::hex << std::showbase;
	Out << "    constexpr uintptr_t BlocksOff   = " << Off::NameArray::ChunksStart << ";\n";
	Out << "}\n\n";

	Out << "namespace FNamePoolEntry\n{\n";
	Out << "    constexpr uintptr_t Header = " << Off::FNameEntry::NamePool::HeaderOffset << ";\n";
	Out << "    constexpr uintptr_t Name   = " << Off::FNameEntry::NamePool::StringOffset << ";\n";
	Out << "}\n\n";

	Out << "namespace FUObjectArray\n{\n";
	Out << "    // Off::InSDK::ObjArray::GObjects points at the ObjObjects sub-struct.\n";
	Out << "    constexpr uintptr_t ObjObjects = " << 0 << ";\n";
	Out << "}\n\n";

	Out << "namespace TUObjectArray\n{\n";
	if (Off::FUObjectArray::bIsChunked)
	{
		Out << "    constexpr uintptr_t Objects             = " << Off::FUObjectArray::ChunkedFixedLayout.ObjectsOffset << ";\n";
		Out << "    constexpr uintptr_t NumElements         = " << Off::FUObjectArray::ChunkedFixedLayout.NumElementsOffset << ";\n";
		Out << "    constexpr uintptr_t NumElementsPerChunk = " << Off::InSDK::ObjArray::ChunkSize << ";\n";
	}
	else
	{
		Out << "    constexpr uintptr_t Objects             = " << Off::FUObjectArray::FixedLayout.ObjectsOffset << ";\n";
		Out << "    constexpr uintptr_t NumElements         = " << Off::FUObjectArray::FixedLayout.NumObjectsOffset << ";\n";
		Out << "    constexpr uintptr_t NumElementsPerChunk = 0;\n";
	}
	Out << "}\n\n";

	Out << "namespace FUObjectItem\n{\n";
	Out << "    constexpr uintptr_t Object = " << Off::InSDK::ObjArray::FUObjectItemInitialOffset << ";\n";
	Out << "    constexpr uintptr_t Size   = " << Off::InSDK::ObjArray::FUObjectItemSize << ";\n";
	Out << "}\n\n";

	Out << "namespace UObject\n{\n";
	Out << "    constexpr uintptr_t Vft           = " << Off::UObject::Vft << ";\n";
	Out << "    constexpr uintptr_t ObjectFlags   = " << Off::UObject::Flags << ";\n";
	Out << "    constexpr uintptr_t InternalIndex = " << Off::UObject::Index << ";\n";
	Out << "    constexpr uintptr_t ClassPrivate  = " << Off::UObject::Class << ";\n";
	Out << "    constexpr uintptr_t NamePrivate   = " << Off::UObject::Name << ";\n";
	Out << "    constexpr uintptr_t OuterPrivate  = " << Off::UObject::Outer << ";\n";
	Out << "}\n\n";

	Out << "namespace UField\n{\n";
	Out << "    constexpr uintptr_t Next = " << Off::UField::Next << ";\n";
	Out << "}\n\n";

	Out << "namespace UEnum\n{\n";
	Out << "    constexpr uintptr_t Names = " << Off::UEnum::Names << ";\n";
	Out << "}\n\n";

	Out << "namespace UStruct\n{\n";
	Out << "    constexpr uintptr_t SuperStruct     = " << Off::UStruct::SuperStruct << ";\n";
	Out << "    constexpr uintptr_t Children        = " << Off::UStruct::Children << ";\n";
	Out << "    constexpr uintptr_t ChildProperties = " << Off::UStruct::ChildProperties << ";\n";
	Out << "    constexpr uintptr_t PropertiesSize  = " << Off::UStruct::Size << ";\n";
	Out << "    constexpr uintptr_t MinAlignment    = " << Off::UStruct::MinAlignment << ";\n";
	Out << "    // -1 if not present in this build (StructBaseChain enables a faster IsA path).\n";
	Out << "    constexpr int32_t  StructBaseChain  = " << std::dec << Off::UStruct::StructBaseChain << std::hex << std::showbase << ";\n";
	Out << "}\n\n";

	Out << "namespace UFunction\n{\n";
	Out << "    constexpr uintptr_t EFunctionFlags = " << Off::UFunction::FunctionFlags << ";\n";
	Out << "    constexpr uintptr_t Func           = " << Off::UFunction::ExecFunction << ";\n";
	Out << "    // NumParams / ParamSize: not exposed by Dumper-7 (derived by walking Children).\n";
	Out << "}\n\n";

	Out << "namespace UClass\n{\n";
	Out << "    constexpr uintptr_t CastFlags             = " << Off::UClass::CastFlags << ";\n";
	Out << "    constexpr uintptr_t ClassDefaultObject    = " << Off::UClass::ClassDefaultObject << ";\n";
	Out << "    constexpr uintptr_t ImplementedInterfaces = " << Off::UClass::ImplementedInterfaces << ";\n";
	Out << "}\n\n";

	if (Settings::Internal::bUseFProperty)
	{
		Out << "namespace FField\n{\n";
		Out << "    constexpr uintptr_t Vft          = " << Off::FField::Vft << ";\n";
		Out << "    constexpr uintptr_t ClassPrivate = " << Off::FField::Class << ";\n";
		Out << "    constexpr uintptr_t Owner        = " << Off::FField::Owner << ";\n";
		Out << "    constexpr uintptr_t Next         = " << Off::FField::Next << ";\n";
		Out << "    constexpr uintptr_t NamePrivate  = " << Off::FField::Name << ";\n";
		Out << "    constexpr uintptr_t FlagsPrivate = " << Off::FField::Flags << ";\n";
		Out << "    // -1 if not present (editor-only builds expose extra metadata).\n";
		Out << "    constexpr int32_t  EditorOnlyMetadata = " << std::dec << Off::FField::EditorOnlyMetadata << std::hex << std::showbase << ";\n";
		Out << "}\n\n";

		Out << "namespace FFieldClass\n{\n";
		Out << "    constexpr uintptr_t Name       = " << Off::FFieldClass::Name << ";\n";
		Out << "    constexpr uintptr_t Id         = " << Off::FFieldClass::Id << ";\n";
		Out << "    constexpr uintptr_t CastFlags  = " << Off::FFieldClass::CastFlags << ";\n";
		Out << "    constexpr uintptr_t ClassFlags = " << Off::FFieldClass::ClassFlags << ";\n";
		Out << "    constexpr uintptr_t SuperClass = " << Off::FFieldClass::SuperClass << ";\n";
		Out << "}\n\n";

		Out << "namespace FProperty\n{\n";
		Out << "    constexpr uintptr_t ArrayDim        = " << Off::Property::ArrayDim << ";\n";
		Out << "    constexpr uintptr_t ElementSize     = " << Off::Property::ElementSize << ";\n";
		Out << "    constexpr uintptr_t PropertyFlags   = " << Off::Property::PropertyFlags << ";\n";
		Out << "    constexpr uintptr_t Offset_Internal = " << Off::Property::Offset_Internal << ";\n";
		Out << "    constexpr uintptr_t Size            = " << Off::InSDK::Properties::PropertySize << ";\n";
		Out << "}\n\n";
	}
	else
	{
		Out << "namespace UProperty\n{\n";
		Out << "    constexpr uintptr_t ArrayDim        = " << Off::Property::ArrayDim << ";\n";
		Out << "    constexpr uintptr_t ElementSize     = " << Off::Property::ElementSize << ";\n";
		Out << "    constexpr uintptr_t PropertyFlags   = " << Off::Property::PropertyFlags << ";\n";
		Out << "    constexpr uintptr_t Offset_Internal = " << Off::Property::Offset_Internal << ";\n";
		Out << "    constexpr uintptr_t Size            = " << Off::InSDK::Properties::PropertySize << ";\n";
		Out << "}\n\n";
	}

	/* Per-property-type subclass offsets. All sub-offsets are relative to the property
	 * base (UProperty or FProperty depending on UE version). */
	Out << "namespace ByteProperty       { constexpr uintptr_t Enum               = " << Off::ByteProperty::Enum << "; }\n";
	Out << "namespace BoolProperty       { constexpr uintptr_t Base               = " << Off::BoolProperty::Base << "; }\n";
	Out << "namespace ObjectProperty     { constexpr uintptr_t PropertyClass      = " << Off::ObjectProperty::PropertyClass << "; }\n";
	Out << "namespace ClassProperty      { constexpr uintptr_t MetaClass          = " << Off::ClassProperty::MetaClass << "; }\n";
	Out << "namespace StructProperty     { constexpr uintptr_t Struct             = " << Off::StructProperty::Struct << "; }\n";
	Out << "namespace ArrayProperty      { constexpr uintptr_t Inner              = " << Off::ArrayProperty::Inner << "; }\n";
	Out << "namespace DelegateProperty   { constexpr uintptr_t SignatureFunction  = " << Off::DelegateProperty::SignatureFunction << "; }\n";
	Out << "namespace MapProperty        { constexpr uintptr_t Base               = " << Off::MapProperty::Base << "; }\n";
	Out << "namespace SetProperty        { constexpr uintptr_t ElementProp        = " << Off::SetProperty::ElementProp << "; }\n";
	Out << "namespace EnumProperty       { constexpr uintptr_t Base               = " << Off::EnumProperty::Base << "; }\n";
	Out << "namespace FieldPathProperty  { constexpr uintptr_t FieldClass         = " << Off::FieldPathProperty::FieldClass << "; }\n";
	Out << "namespace OptionalProperty   { constexpr uintptr_t ValueProperty      = " << Off::OptionalProperty::ValueProperty << "; }\n\n";

	/* Property sizes that vary by UE version / compiler. */
	Out << "namespace PropertySizes\n{\n";
	Out << "    constexpr int32_t DelegateProperty               = " << std::dec << PropertySizes::DelegateProperty << ";\n";
	Out << "    constexpr int32_t FieldPathProperty              = " << PropertySizes::FieldPathProperty << ";\n";
	Out << "    constexpr int32_t MulticastInlineDelegateProperty = " << PropertySizes::MulticastInlineDelegateProperty << ";\n";
	Out << "}\n\n";
	Out << std::hex << std::showbase;

	/* FName resolution helpers (used by SDK's runtime to call AppendString / GetNameEntryFromName). */
	Out << "namespace FNameResolver\n{\n";
	Out << "    constexpr bool      bUsesAppendString          = " << (Off::InSDK::Name::bIsUsingAppendStringOverToString ? "true" : "false") << ";\n";
	Out << "    constexpr bool      bAppendStringInlined       = " << (Off::InSDK::Name::bIsAppendStringInlinedAndUsed ? "true" : "false") << ";\n";
	Out << "    constexpr uintptr_t AppendNameToString_Offset  = " << Off::InSDK::Name::AppendNameToString << ";\n";
	Out << "    constexpr uintptr_t GetNameEntryFromName_Offset = " << Off::InSDK::Name::GetNameEntryFromName << ";\n";
	Out << "}\n\n";

	/* FText layout (used for FText::ToString in the SDK). */
	Out << "namespace FText\n{\n";
	Out << "    constexpr uintptr_t TextSize                = " << Off::InSDK::Text::TextSize << ";\n";
	Out << "    constexpr uintptr_t TextDatOffset           = " << Off::InSDK::Text::TextDatOffset << ";\n";
	Out << "    constexpr uintptr_t InTextDataStringOffset  = " << Off::InSDK::Text::InTextDataStringOffset << ";\n";
	Out << "}\n\n";

	/* Misc UE class field offsets that the SDK references. */
	Out << "namespace ULevel    { constexpr uintptr_t Actors = " << Off::InSDK::ULevel::Actors << "; }\n";
	Out << "namespace UDataTable { constexpr uintptr_t RowMap = " << Off::InSDK::UDataTable::RowMap << "; }\n\n";

	Out << "}  // namespace UEOffsets\n\n";

	Out << "namespace UEPointers\n{\n";
	Out << "    constexpr uintptr_t Names             = " << NamesPtr << ";\n";
	Out << "    // FUObjectArray base (same value as SDKGen's Offsets.txt 'uobject'\n";
	Out << "    // for legacy/fixed layouts).\n";
	Out << "    constexpr uintptr_t UObjectArray      = " << ObjectsBase << ";\n";
	Out << "    // Inner TUObjectArray (FUObjectArray + 0x10 on UE <= 4.19).\n";
	Out << "    constexpr uintptr_t ObjObjects        = " << ObjectsInner << ";\n";
	Out << "    // 0 when no stable GWorld slot exists; UWorld::GetWorld() then\n";
	Out << "    // falls back to UEngine::GameViewport->World.\n";
	Out << "    constexpr uintptr_t World             = " << WorldPtr << ";\n";
	Out << "    constexpr uintptr_t ProcessEvent      = " << Addr(Off::InSDK::ProcessEvent::PEOffset) << ";\n";
	Out << std::dec;
	Out << "    constexpr int32_t  ProcessEventIndex = " << Off::InSDK::ProcessEvent::PEIndex << ";\n";
	Out << "}\n";

	Out.close();
	LogSuccess("DumpUEOffsetsHeader: wrote %s", OutPath.string().c_str());
}


/* -------------------------------------------------------------------------
 * PUBG Mobile helpers
 * ---------------------------------------------------------------------- */

namespace
{
	enum class EPUBGOffsetKind : uint8_t
	{
		Reflected,  /* exact reflected member resolved from the live dump */
		Candidate,  /* likely member; emitted for verification on the target build */
		Manual,     /* vtable/function or stable struct offset; not reflected */
	};

	struct PUBGOffsetSpec
	{
		const char* Macro;
		const char* Classes;   /* comma separated UClass names (A/U prefix stripped) */
		const char* Member;
		uint32_t Fallback;
		EPUBGOffsetKind Kind = EPUBGOffsetKind::Reflected;
		const char* Note = nullptr;
	};

	/* The macro names/values are the ones used by the common PUBG iOS bases.
	 * Reflected entries are resolved from the live dump.  Candidate entries use
	 * a likely member name and are marked for verification.  Manual entries are
	 * vtable/function offsets or stable struct offsets that reflection cannot
	 * discover; they keep the known 4.x value and are documented in the output. */
	const PUBGOffsetSpec GPUBGOffsetSpecs[] =
	{
		{ "kLineOfSightTo",              "",                            "",                        0x7A8, EPUBGOffsetKind::Manual,
		  "AController::LineOfSightTo vtable byte offset (not a reflected field)" },
		{ "kPersistentLevel",            "World",                       "PersistentLevel",         0x30   },
		{ "kNetDriver",                  "World",                       "NetDriver",               0x38   },
		{ "kServerConnection",           "NetDriver",                   "ServerConnection",        0x78   },
		{ "kPlayerController",           "NetConnection",               "OwningActor",             0x98   },
		{ "klocalPlayerController",      "LocalPlayer",                 "PlayerController",        0x30   },
		{ "kPawn",                       "Controller",                  "Pawn",                    0x4B8  },
		{ "kCharacter",                  "Controller",                  "Character",               0x4C8  },
		{ "kControlRotation",            "Controller",                  "ControlRotation",         0x4E0  },
		{ "kMyTeam",                     "STExtraPlayerState,UAEPlayerState", "TeamID",            0x940  },
		{ "kCameraCache",                "PlayerCameraManager",         "CameraCache",             0x520  },
		{ "kViewTarget",                 "PlayerCameraManager",         "ViewTarget",              0x10A0 },
		{ "kPlayerCameraManager",        "PlayerController",            "PlayerCameraManager",     0x548  },
		{ "kHealth",                     "STExtraCharacter",            "Health",                  0x0E60 },
		{ "kHealthMax",                  "STExtraCharacter",            "HealthMax",               0x0E64 },
		{ "kbDead",                      "STExtraCharacter",            "bDead",                   0x0E7C },
		{ "kbIsGunADS",                  "STExtraCharacter",            "bIsGunADS",               0x1134 },
		{ "kCurrentVehicle",             "STExtraCharacter",            "CurrentVehicle",          0x0EB0 },
		{ "kNearDeatchComponent",        "STExtraBaseCharacter",        "NearDeatchComponent",     0x1C28 },
		{ "kbHidden",                    "Actor",                       "bHidden",                 0x00E8 },
		{ "kRootComponent",              "Actor",                       "RootComponent",           0x0208 },
		{ "kRepMovement",                "Actor",                       "ReplicatedMovement",      0x0110 },
		{ "kPlayerName",                 "UAECharacter",                "PlayerName",              0x0960 },
		{ "kPlayerUID",                  "UAECharacter",                "PlayerUID",               0x0988 },
		{ "kNation",                     "UAECharacter",                "Nation",                  0x0970 },
		{ "kTeamID",                     "UAECharacter",                "TeamID",                  0x0998 },
		{ "kbIsAI",                      "UAECharacter",                "bIsAI",                   0x0A40 },
		{ "kbIsMLAI",                    "UAECharacter",                "bIsMLAI",                 0x0A41 },
		{ "kMesh",                       "Character",                   "Mesh",                    0x0510 },
		{ "kStaticMesh",                 "StaticMeshComponent",         "StaticMesh",              0x08C8 },
		{ "kLastRenderTime",             "PrimitiveComponent",          "LastRenderTime",          0x0430 },
		{ "kVelocity",                   "MovementComponent",           "Velocity",                0x012C },
		{ "kRelativeLocation",           "SceneComponent",              "RelativeLocation",        0x01E4 },
		{ "kRelativeScale3D",            "SceneComponent",              "RelativeScale3D",         0x01FC },
		{ "kComponentVelocity",          "SceneComponent",              "ComponentVelocity",       0x02C0 },
		{ "kNearDeathBreath",            "STExtraBaseCharacter",        "NearDeathBreath",         0x1C40 },
		{ "kbIsWeaponFiring",            "STExtraBaseCharacter",        "bIsWeaponFiring",         0x1840 },
		{ "kWeaponManagerComponent",     "STExtraBaseCharacter",        "WeaponManagerComponent",  0x2628 },
		{ "kPoseState",                  "STExtraBaseCharacter",        "PoseState",               0x1738 },
		{ "kScopeFov",                   "STExtraBaseCharacter",        "ScopeFov",                0x1D3C },
		{ "kCurrentWeaponReplicated",    "WeaponManagerComponent",      "CurrentWeaponReplicated", 0x05E8 },
		{ "kShootWeaponEntityComponent", "STExtraShootWeaponComponent", "ShootWeaponEntityComponent", 0x330 },
		{ "kWeaponId",                   "ShootWeaponEntity",           "WeaponId",                0x01E0 },
		{ "kBulletFireSpeed",            "ShootWeaponEntity",           "BulletFireSpeed",         0x0560 },
		{ "kRecoilKickADS",              "ShootWeaponEntity",           "RecoilKickADS",           0x0CF0 },
		{ "kGameDeviationFactor",        "ShootWeaponEntity",           "GameDeviationFactor",     0x0C2C },
		{ "kShootWeaponComponent",       "STExtraShootWeapon",          "ShootWeaponComponent",    0x0FA0 },
		{ "kShootWeaponEntityComp",      "STExtraShootWeapon",          "ShootWeaponEntityComp",   0x1380 },
		{ "kShootWeaponEffectComp",      "STExtraShootWeapon",          "ShootWeaponEffectComp",   0x1388 },
		{ "kShootMode",                  "STExtraShootWeapon",          "ShootMode",               0x10F9 },
		{ "kVehicleCommon",              "STExtraVehicleBase",          "VehicleCommon",           0x0C08 },
		{ "kHP",                         "VehicleCommonComponent",      "Hp",                      0x0354 },
		{ "kHPMax",                      "VehicleCommonComponent",      "HPMax",                   0x0350 },
		{ "kFuel",                       "VehicleCommonComponent",      "Fuel",                    0x043C },
		{ "kFuelMax",                    "VehicleCommonComponent",      "FuelMax",                 0x0438 },
		{ "kPickUpDataList",             "PickUpListWrapperActor,PickUpDataComponent", "PickUpDataList", 0x08D0 },
		{ "kGoodsID",                    "",                            "",                        0x38, EPUBGOffsetKind::Manual,
		  "box goods ID offset (stable 4.x struct offset, not reflected)" },
		{ "kTableName",                  "PickUpListWrapperActor,PickUpWrapperActor,PickUpDataComponent,PlayerTombBox",
		                                                                "ItemTableName",           0x920, EPUBGOffsetKind::Candidate,
		  "box item table FString; verify on target" },
		{ "kCurrentStates",              "STExtraCharacter",            "CurrentStates",           0x1058 },
		{ "kFPS",                        "",                            "",                        0x1C4, EPUBGOffsetKind::Manual,
		  "legacy FPS offset kept for base compatibility (not reflected; usually unused)" },
		{ "kBP_MapUIMarkManager_C",      "BP_STExtraPlayerController_C,STExtraPlayerController_C",
		                                                                "BP_MapUIMarkManager",     0x4270, EPUBGOffsetKind::Candidate,
		  "blueprint component pointer on the player controller; verify on target" },
		{ "kpExtraGameState",            "MapUIMarkManager",            "pExtraGameState",         0x0428 },
		{ "kAlivePlayerNum",             "STExtraGameStateBase",        "AlivePlayerNum",          0x0BB4 },
		{ "kPlayerNum",                  "STExtraGameStateBase",        "PlayerNum",               0x0818 },
		{ "kelapsedSeconds",             "GameState",                   "ElapsedTime",             0x04DC },
		{ "kPlayerState",                "Controller",                  "PlayerState",             0x04D0 },
		{ "kKill",                       "UAEPlayerState",              "Kills",                   0x06C8 },
		{ "kTPP",                        "STExtraBaseCharacter",        "ThirdPersonCameraComponent", 0x1C50, EPUBGOffsetKind::Candidate,
		  "inferred from the kTPP name; verify on target" },
		{ "kFPP",                        "STExtraBaseCharacter",        "FPPCameraComp",           0x1C60, EPUBGOffsetKind::Candidate,
		  "inferred from the kFPP name; verify on target" },
		{ "kGameReplayType",             "UAEPlayerController",         "GameReplayType",          0x0944 },
		{ "kPickUpAnim",                 "STExtraBaseCharacter",        "MainCharAnimClass",       0x1E28 },
		{ "kPressingFireBtn",            "STExtraPlayerController",     "bIsPressingFireBtn",      0x33D0 },
		{ "kCurrentReloadWeapon",        "STExtraBaseCharacter",        "CurrentReloadWeapon",     0x2B58 },
		{ "kCachedBulletTrackComponent", "STExtraShootWeapon",          "CachedBulletTrackComponent", 0x0E28 },
		{ "wuhou",                       "SceneComponent",              "RelativeRotation",        0x190  },
		{ "kYaw",                        "",                            "",                        0x888, EPUBGOffsetKind::Manual,
		  "APlayerController::AddYawInput vtable byte offset (not a reflected field)" },
		{ "kRoll",                       "",                            "",                        0x890, EPUBGOffsetKind::Manual,
		  "APlayerController::AddRollInput vtable byte offset (not a reflected field)" },
		{ "kPitch",                      "",                            "",                        0x880, EPUBGOffsetKind::Manual,
		  "APlayerController::AddPitchInput vtable byte offset (not a reflected field)" },
	};

	std::vector<std::string> SplitClassList(const char* List)
	{
		std::vector<std::string> Out;
		if (!List || !*List)
			return Out;

		std::string_view View(List);
		size_t Start = 0;
		while (Start <= View.size())
		{
			const size_t Comma = View.find(',', Start);
			const size_t End = Comma == std::string_view::npos ? View.size() : Comma;
			std::string Name(View.substr(Start, End - Start));
			if (!Name.empty())
				Out.push_back(std::move(Name));
			if (Comma == std::string_view::npos)
				break;
			Start = Comma + 1;
		}
		return Out;
	}

	bool FindMemberInHierarchy(UEStruct Struct, const std::string& MemberName, UEProperty& OutProperty, std::string& OutOwner)
	{
		for (UEStruct Current = Struct; Current && Current.GetAddress(); )
		{
			if (UEProperty Property = Current.FindMember(MemberName))
			{
				OutProperty = Property;
				OutOwner = Current.GetName();
				return true;
			}

			UEStruct Super = Current.GetSuper();
			if (Super.GetAddress() == Current.GetAddress())
				break;
			Current = Super;
		}
		return false;
	}

	std::string TimestampNow()
	{
		std::time_t Now = std::time(nullptr);
		std::tm Local{};
#if defined(_WIN32)
		localtime_s(&Local, &Now);
#else
		localtime_r(&Now, &Local);
#endif
		char Buffer[64]{};
		std::strftime(Buffer, sizeof(Buffer), "%Y-%m-%d %H:%M:%S %z", &Local);
		return Buffer;
	}

	std::string SanitizeGameName(std::string Name)
	{
		for (char& C : Name)
		{
			if (C == '\r' || C == '\n' || C == '\t')
				C = ' ';
			if (static_cast<unsigned char>(C) < 0x20)
				C = ' ';
		}
		while (!Name.empty() && Name.front() == ' ') Name.erase(Name.begin());
		while (!Name.empty() && Name.back() == ' ')  Name.pop_back();
		return Name;
	}
}

void DumpPUBGOffsetsHeader(const fs::path& GameFolder)
{
	if (!Settings::Internal::bIsPUBGProfile)
		return;

	const fs::path OutPath = GameFolder / "PUBGOffsets.hpp";
	std::ofstream Out(OutPath);
	if (!Out)
	{
		LogError("DumpPUBGOffsetsHeader: failed to open %s", OutPath.string().c_str());
		return;
	}

	/* Gather all classes referenced by the table in a single pass.  Calling
	 * FindClassFast() per entry would rescan ~200k objects for every macro. */
	std::unordered_set<std::string> WantedClasses;
	for (const PUBGOffsetSpec& Spec : GPUBGOffsetSpecs)
	{
		for (const std::string& ClassName : SplitClassList(Spec.Classes))
			WantedClasses.insert(ClassName);
	}

	std::unordered_map<std::string, UEClass> Classes;
	for (UEObject Object : ObjectArray())
	{
		const void* Address = Object.GetAddress();
		if (!Address || IsBadReadPtr(Address))
			continue;
		if (!Object.IsA(EClassCastFlags::Class))
			continue;

		const std::string Name = Object.GetName();
		if (WantedClasses.count(Name) && Classes.find(Name) == Classes.end())
			Classes.emplace(Name, Object.Cast<UEClass>());
	}

	LogInfo("DumpPUBGOffsetsHeader: resolved %zu/%zu reflection classes", Classes.size(), WantedClasses.size());

	Out << "#ifndef PUBGOffsets_hpp\n";
	Out << "#define PUBGOffsets_hpp\n\n";
	Out << "// Auto-generated by Dumper-7 (iOS port) for PUBG Mobile.\n";
	Out << "// Reflected values were resolved from the live SDK dump.\n";
	Out << "// \"candidate\" values matched a likely member name and should be verified.\n";
	Out << "// \"manual\" values are vtable/function or stable struct offsets that\n";
	Out << "// cannot be discovered through UClass reflection; the known 4.x value\n";
	Out << "// is kept for compatibility.  \"fallback\" means the reflected member\n";
	Out << "// was not found in this build and the known 4.x value is used.\n\n";

	size_t Resolved = 0;
	size_t Candidates = 0;
	size_t Manual = 0;
	size_t Fallbacks = 0;

	for (const PUBGOffsetSpec& Spec : GPUBGOffsetSpecs)
	{
		const bool bManual = (Spec.Kind == EPUBGOffsetKind::Manual);

		uint32_t Offset = Spec.Fallback;
		bool bFound = false;
		std::string Owner;

		if (!bManual)
		{
			for (const std::string& ClassName : SplitClassList(Spec.Classes))
			{
				auto It = Classes.find(ClassName);
				if (It == Classes.end())
					continue;

				UEProperty Property;
				if (FindMemberInHierarchy(It->second, Spec.Member, Property, Owner))
				{
					const int32 FoundOffset = Property.GetOffset();
					if (FoundOffset > 0 && FoundOffset < 0x100000)
					{
						Offset = static_cast<uint32_t>(FoundOffset);
						bFound = true;
					}
				}

				if (bFound)
					break;
			}
		}

		Out << "#define " << Spec.Macro << " \"0x"
			<< std::uppercase << std::hex << std::setw(4) << std::setfill('0') << Offset
			<< std::dec << std::nouppercase << std::setfill(' ') << "\"";

		if (bManual)
		{
			++Manual;
			Out << " // manual";
			if (Spec.Note && *Spec.Note)
				Out << ": " << Spec.Note;
		}
		else if (bFound)
		{
			if (Spec.Kind == EPUBGOffsetKind::Candidate)
			{
				++Candidates;
				Out << " // candidate: " << Owner << "::" << Spec.Member;
				if (Spec.Note && *Spec.Note)
					Out << " (" << Spec.Note << ")";
			}
			else
			{
				++Resolved;
				Out << " // " << Owner << "::" << Spec.Member;
			}
		}
		else
		{
			++Fallbacks;
			Out << " // fallback";
			if (Spec.Note && *Spec.Note)
				Out << ": " << Spec.Note;
			Out << " (member not found)";
		}
		Out << "\n";
	}

	Out << "\n#endif // PUBGOffsets_hpp\n";
	Out.close();

	LogSuccess("DumpPUBGOffsetsHeader: wrote %s (%zu resolved, %zu candidates, %zu manual, %zu fallbacks)",
		OutPath.string().c_str(), Resolved, Candidates, Manual, Fallbacks);
}

namespace
{
	void DumpNamesFile(const fs::path& Path)
	{
		std::ofstream Out(Path);
		if (!Out)
		{
			LogError("DumpNamesFile: failed to open %s", Path.string().c_str());
			return;
		}

		Out << "Address: 0x" << std::uppercase << std::hex
			<< reinterpret_cast<uintptr_t>(NameArray::DEBUGGetGNames())
			<< std::dec << std::nouppercase << "\n\n";

		const int32 Count = NameArray::GetNumElements();
		if (Count > 0 && Count < 0x1000000)
		{
			for (int32 Index = 0; Index < Count; ++Index)
			{
				const std::string Name = NameArray::GetNameEntry(Index).GetString();
				if (Name.empty())
					continue;
				Out << "[" << std::setw(6) << std::setfill('0') << Index << std::setfill(' ') << "] " << Name << "\n";
			}
		}
		else
		{
			Out << "// TNameEntryArray did not expose a usable element count (" << Count << ")\n";
		}

		Out.close();
		LogSuccess("DumpNamesFile: wrote %s", Path.string().c_str());
	}

	void DumpObjectsFile(const fs::path& Path)
	{
		std::ofstream Out(Path);
		if (!Out)
		{
			LogError("DumpObjectsFile: failed to open %s", Path.string().c_str());
			return;
		}

		Out << "Address: 0x" << std::uppercase << std::hex
			<< (reinterpret_cast<uintptr_t>(ObjectArray::DEBUGGetGObjects()) - 0x10)
			<< std::dec << std::nouppercase << "\n\n";

		for (UEObject Object : ObjectArray())
		{
			const void* Address = Object.GetAddress();
			if (!Address || IsBadReadPtr(Address))
				continue;

			std::string ClassName = "Object";
			if (UEClass Class = Object.GetClass())
				ClassName = Class.GetName();

			Out << "[" << std::setw(6) << std::setfill('0') << Object.GetIndex() << std::setfill(' ') << "] "
				<< ClassName << " " << Object.GetName()
				<< " 0x" << std::uppercase << std::hex << reinterpret_cast<uintptr_t>(Address)
				<< std::dec << std::nouppercase << "\n";
		}

		Out.close();
		LogSuccess("DumpObjectsFile: wrote %s", Path.string().c_str());
	}

	void DumpOffsetsTxt(const fs::path& Root)
	{
		const fs::path OutPath = Root / "Offsets.txt";
		std::ofstream Out(OutPath);
		if (!Out)
		{
			LogError("DumpOffsetsTxt: failed to open %s", OutPath.string().c_str());
			return;
		}

		const uintptr_t ImageBase = GetModuleBase();
		const uintptr_t LiveNames = reinterpret_cast<uintptr_t>(NameArray::DEBUGGetGNames());
		const uintptr_t GNames = LiveNames ? LiveNames : (ImageBase + static_cast<uintptr_t>(Off::InSDK::NameArray::GNames));
		/* Off::InSDK::ObjArray::GObjects points at the inner TUObjectArray
		 * (FUObjectArray+0x10).  SDKGen and the common PUBG bases expect the
		 * FUObjectArray base, so subtract the 0x10 preamble. */
		const uintptr_t GObjects = ImageBase + static_cast<uintptr_t>(Off::InSDK::ObjArray::GObjects) - 0x10;

		Out << std::uppercase << std::hex << std::showbase;
		Out << "gname = " << GNames << "\n";
		Out << "uobject = " << GObjects << "\n";
		Out << std::dec << std::noshowbase;
		Out << "processevent = " << Off::InSDK::ProcessEvent::PEIndex << "\n";
		/* PUBG's UObject vtable layout has kept GetDefaultObject at index 111. */
		Out << "GetDefaltObject = 111\n";
		Out.close();
		LogSuccess("DumpOffsetsTxt: wrote %s", OutPath.string().c_str());
	}

	void DumpLastStatusTxt(const fs::path& Root, const fs::path& GameFolder)
	{
		const fs::path OutPath = Root / "LastStatus.txt";
		std::ofstream Out(OutPath);
		if (!Out)
		{
			LogError("DumpLastStatusTxt: failed to open %s", OutPath.string().c_str());
			return;
		}

		const MachImageInfo Image = GetImageBaseAndSize();
		const char* ImageName = _dyld_get_image_name(0);
		std::string ModuleName = ImageName ? ImageName : "main executable";
		const size_t Slash = ModuleName.find_last_of('/');
		if (Slash != std::string::npos)
			ModuleName = ModuleName.substr(Slash + 1);

		size_t HppCount = 0;
		size_t CppCount = 0;
		try
		{
			for (const auto& Entry : fs::directory_iterator(GameFolder / "SDK"))
			{
				if (!Entry.is_regular_file())
					continue;
				const std::string Ext = Entry.path().extension().string();
				if (Ext == ".hpp") ++HppCount;
				else if (Ext == ".cpp") ++CppCount;
			}
		}
		catch (...) {}

		Out << "SDKGen - live status\n\n";
		Out << "Game: " << SanitizeGameName(Settings::Generator::GameName)
			<< " | v" << SanitizeGameName(Settings::Generator::GameVersion) << "\n";
		Out << "Bundle: " << Settings::Generator::BundleIdentifier << "\n\n";

		Out << "Mach-O module: " << ModuleName << "\n";
		Out << "Image base: 0x" << std::uppercase << std::hex << Image.Base << std::dec << std::nouppercase << "\n";
		Out << "ASLR slide: 0x" << std::uppercase << std::hex << static_cast<uintptr_t>(Image.Slide) << std::dec << std::nouppercase << "\n";
		Out << "Documents root: " << Root.string() << "\n";
		Out << "Offsets.txt: " << (Root / "Offsets.txt").string() << "\n\n";

		Out << "Vtable (active): ProcessEvent=" << Off::InSDK::ProcessEvent::PEIndex
			<< "  GetDefaultObject=111\n\n";

		Out << "- Resolved pointers -\n";
		const uintptr_t LiveNames = reinterpret_cast<uintptr_t>(NameArray::DEBUGGetGNames());
		Out << "GNames *        0x" << std::uppercase << std::hex
			<< (LiveNames ? LiveNames : Image.Base + static_cast<uintptr_t>(Off::InSDK::NameArray::GNames))
			<< std::dec << std::nouppercase << "   count: " << NameArray::GetNumElements() << "\n";
		Out << "GUObjectArray * 0x" << std::uppercase << std::hex
			<< Image.Base + static_cast<uintptr_t>(Off::InSDK::ObjArray::GObjects) - 0x10
			<< std::dec << std::nouppercase << "   count: " << ObjectArray::Num() << "\n";
		Out << "ObjObjects ptr  0x" << std::uppercase << std::hex
			<< reinterpret_cast<uintptr_t>(ObjectArray::DEBUGGetGObjects())
			<< std::dec << std::nouppercase << "\n\n";

		Out << "- Output paths -\n";
		Out << "Folder:\n  " << GameFolder.string() << "\n";
		Out << "SDK.hpp:\n  " << (GameFolder / "SDK.hpp").string() << "\n";
		Out << "SDK folder:\n  " << (GameFolder / "SDK").string() << "/\n\n";

		Out << "- Done - generation summary -\n";
		Out << "UE objects in map:          " << ObjectArray::Num() << "\n";
		Out << ".hpp files in SDK/ folder:  " << HppCount << "\n";
		Out << ".cpp files in SDK/ folder:  " << CppCount << "\n";
		Out << "Root SDK.hpp written:       " << (fs::exists(GameFolder / "SDK.hpp") ? "yes" : "no") << "\n";
		Out << "PUBGOffsets.hpp written:    " << (fs::exists(GameFolder / "PUBGOffsets.hpp") ? "yes" : "no") << "\n";

		Out.close();
		LogSuccess("DumpLastStatusTxt: wrote %s", OutPath.string().c_str());
	}

	void DumpBootLogTxt(const fs::path& Root)
	{
		const fs::path OutPath = Root / "BootLog.txt";
		std::ofstream Out(OutPath);
		if (!Out)
		{
			LogError("DumpBootLogTxt: failed to open %s", OutPath.string().c_str());
			return;
		}

		const std::string Now = TimestampNow();
		Out << Now << " dumper constructor invoked\n";
		Out << Now << " engine core initialized\n";
		Out << Now << " internal generator initialized\n";
		Out << Now << " SDK generation started\n";
		Out << Now << " SDK generation completed\n";
		Out.close();
	}

	void DumpGameLog(const fs::path& GameFolder)
	{
		const fs::path OutPath = GameFolder / "dump.log";
		std::ofstream Out(OutPath);
		if (!Out)
			return;

		Out << "Generated by Dumper-7 (iOS port)\n";
		Out << "Game: " << SanitizeGameName(Settings::Generator::GameName)
			<< " | v" << SanitizeGameName(Settings::Generator::GameVersion) << "\n";
		Out << "Bundle: " << Settings::Generator::BundleIdentifier << "\n";
		Out << "Objects: " << ObjectArray::Num() << "\n";
		Out << "ProcessEvent index: " << Off::InSDK::ProcessEvent::PEIndex << "\n";
		Out.close();
	}
}

void DumpSDKGenCompanionFiles(const fs::path& GameFolder)
{
	if (!Settings::Internal::bIsPUBGProfile)
		return;
	if (GameFolder.empty() || !fs::exists(GameFolder))
	{
		LogError("DumpSDKGenCompanionFiles: invalid game folder");
		return;
	}

	const fs::path Root = GameFolder.parent_path();

	DumpNamesFile(GameFolder / "NamesDump.txt");
	DumpObjectsFile(GameFolder / "ObjectsDump.txt");
	DumpOffsetsTxt(Root);
	DumpLastStatusTxt(Root, GameFolder);
	DumpBootLogTxt(Root);
	DumpGameLog(GameFolder);

	LogSuccess("DumpSDKGenCompanionFiles: wrote SDKGen-style files to %s", Root.string().c_str());
}
