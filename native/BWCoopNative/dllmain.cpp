// BWCoopNative: native companion to the BWCoop Lua mod (Bellwright co-op, host only).
//
// UE4SS Lua hooks cannot cancel a game function, and emptying a request's parameters crashes
// the host (the game does not null-check its lookups). This add-on lets the Lua guard skip a
// call cleanly:
//
//   1. At Unreal init (before any Lua mod starts), every UFunction listed in armed.txt gets a
//      small wrapper installed as its native function pointer. The real function is remembered.
//   2. When BWCoop's Lua hook is attached later, UE4SS stores our wrapper as the "original".
//      So each call runs: UE4SS hook -> Lua pre-hook -> our wrapper -> real function.
//   3. A Lua pre-hook that wants the call blocked calls BWNative_Skip("<function path>").
//      The wrapper then skips that one call instead of running the real function.
//
// Lua functions (registered for the BWCoop Lua mod):
//   BWNative_Version() -> string
//   BWNative_IsArmed(path) -> bool
//   BWNative_Skip(path) -> bool        true if the next call of that function will be skipped
//   BWNative_SkipCount() -> integer    calls skipped since the game started
//
// Game calls (0.2.0): the game's own C++ functions, called by address (from the shipped PDB of
// Bellwright build 24840601). Each is checked against its first bytes and stays off when they
// differ, e.g. after a game update (see the bellwright-game-update skill):
//   BWNative_GameCallsReady() -> bool
// Objects are passed and returned as addresses (obj:GetAddress(); 0 = none).
//   BWNative_SetCommandedGroup(commandComponent, groupData|0) -> bool
//        UMistPlayerCommandComponent::SetCommandedCombatGroup: which squad a player commands
//        (keeps the squad's commanding players, the replicated squad id and the HUD in sync).
//   BWNative_GetSquadFlag(groupData, offset) -> bool
//   BWNative_SetSquadFlag(groupData, offset, bool) -> bool previous
//        The default-squad flags on UMistCombatGroupData: 0x1EC new hires ("Newcomers",
//        GetOrCreateNewHiresCombatGroup), 0x1ED call to arms ("Reservists", filled by "Mobilize
//        companions", GetOrCreateCallToArmsCombatGroup), 0x1EE common ("Common", where new
//        soldiers go, GetOrCreateCombatGroupForManuallySwitchedNpc). Other offsets are refused.
//   BWNative_GetCallToArms(groupData) / BWNative_SetCallToArms(groupData, bool): 0x1ED (0.2.0).
//   BWNative_ClosestPlayerSettlement(worldContext, x, y, z) -> settlement actor address|0
//        FMistTownUtils::FindClosestPlayerSettlement(ctx, location, 100 m, nullptr): the village
//        a new building at that spot joins.
//
// 0.3.0: per-player rates (rates.cpp) and the "BWCoop" admin tab in the UE4SS window (gui.cpp).
// 0.4.0: night skip rule (sleep.cpp); village trust and night skip in the admin tab.
// 0.4.1: admin tab laid out in tabs (Players, Give, Villager, World, Villages, Settings) over the log.
// 0.4.2: admin tab fits the visible window (UE4SS's window is the OS window's outer size); widths follow the font size.
//        Night skip log line names who is in bed and who is up.
//        +1/-1 skill level now sticks (UpdateStats after SetSkill, as the game's cheat does).
//        Instant books applied where the game adds the reading effect (KnowledgeItemTemplate::ApplyEffects).
//        Free crafting scoped to a player's own craft calls (the old 100 ms window crashed the settlement ledger).
// 0.4.3: Give tab: Search button and shown item names (BWCoop 0.6.3 resolves them); widths scaled once.
// 0.4.4: BWNative_ItemRequests: a caravan route stop's item request IDs, types and amounts (BWCoop 0.7.22 keep-stocked rules).
// 0.4.5: BWNative_SpawnNewcomer(worldContext, templateCdo, x, y, z) -> new NPC address|0: AMistTownNpc::GenerateImmigrant,
//        the game's own spawn of an unassigned recruitable villager (BWCoop 0.7.28 newcomers; research/immigrants-2026-10-17.md).

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <Windows.h>

#include <cstdint>
#include <filesystem>
#include <format>
#include <fstream>
#include <string>
#include <unordered_map>

#include <DynamicOutput/DynamicOutput.hpp>
#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <Mod/CppUserModBase.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#include <Unreal/FFrame.hpp>
#include <Unreal/UObjectArray.hpp>
#include <UE4SSProgram.hpp>
#include <imgui.h>

#include "bwcoop.hpp"
#include <Unreal/UObjectGlobals.hpp>

using namespace RC;
using namespace RC::Unreal;

namespace
{
    constexpr const char* kVersion = "0.4.6";

    struct Armed
    {
        UnrealScriptFunction Real{};
        std::string Path;
    };

    std::unordered_map<UFunction*, Armed> g_armed;
    std::unordered_map<std::string, UFunction*> g_byPath;

    // Skip request: the function to skip and the call number it must be.
    UFunction* g_skipFn = nullptr;
    uint64_t g_skipSeq = 0;
    uint64_t g_callSeq = 0;
    int64_t g_skipCount = 0;

    auto log(const std::wstring& msg) -> void
    {
        Output::send<LogLevel::Default>(STR("[BWCoopNative] {}\n"), msg);
    }

    auto widen(const std::string& s) -> std::wstring
    {
        return std::wstring(s.begin(), s.end());
    }

    // The wrapper every armed function now points at.
    auto Wrapper(UObject* Context, FFrame& Stack, void* Result) -> void
    {
        UFunction* fn = Stack.CurrentNativeFunction();
        auto it = fn ? g_armed.find(fn) : g_armed.end();
        if (it == g_armed.end())
        {
            fn = static_cast<UFunction*>(static_cast<void*>(Stack.Node()));
            it = fn ? g_armed.find(fn) : g_armed.end();
        }
        if (it == g_armed.end())
        {
            // Should never happen: we only install this wrapper on functions in g_armed.
            log(STR("wrapper called for an unknown function; call dropped"));
            return;
        }

        ++g_callSeq;
        if (g_skipFn == fn && g_callSeq == g_skipSeq + 1)
        {
            g_skipFn = nullptr;
            ++g_skipCount;
            return;
        }
        g_skipFn = nullptr; // a stale request never carries over to a later call
        it->second.Real(Context, Stack, Result);
    }

    auto modDirectory() -> std::filesystem::path
    {
        HMODULE self = nullptr;
        GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           reinterpret_cast<LPCWSTR>(&Wrapper), &self);
        wchar_t buf[MAX_PATH]{};
        GetModuleFileNameW(self, buf, MAX_PATH);
        // ...\Mods\BWCoopNative\dlls\main.dll -> ...\Mods\BWCoopNative
        return std::filesystem::path(buf).parent_path().parent_path();
    }

    auto armAll() -> void
    {
        auto listPath = modDirectory() / "armed.txt";
        std::ifstream in(listPath);
        if (!in)
        {
            log(STR("armed.txt not found; nothing armed"));
            return;
        }
        int armed = 0, missing = 0, already = 0;
        std::string line;
        while (std::getline(in, line))
        {
            while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
            if (line.empty() || line[0] == '#') continue;
            auto wpath = widen(line);
            auto* fn = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, wpath.c_str());
            if (!fn)
            {
                ++missing;
                log(STR("not found: ") + wpath);
                continue;
            }
            if (g_armed.contains(fn))
            {
                ++already;
                continue;
            }
            Armed a;
            a.Real = fn->GetFuncPtr();
            a.Path = line;
            if (!a.Real)
            {
                ++missing;
                log(STR("no native function: ") + wpath);
                continue;
            }
            g_armed.emplace(fn, a);
            g_byPath.emplace(line, fn);
            fn->SetFuncPtr(&Wrapper);
            ++armed;
        }
        log(std::format(STR("armed {} functions ({} not found, {} duplicates)"), armed, missing, already));
    }

    auto disarmAll() -> void
    {
        for (auto& [fn, a] : g_armed)
        {
            if (fn && fn->GetFuncPtr() == &Wrapper) fn->SetFuncPtr(a.Real);
        }
        g_armed.clear();
        g_byPath.clear();
    }

    // ---- Lua functions ----

    auto lua_version(const LuaMadeSimple::Lua& lua) -> int
    {
        lua.set_string(kVersion);
        return 1;
    }

    auto lua_isArmed(const LuaMadeSimple::Lua& lua) -> int
    {
        bool armed = false;
        if (lua.is_string())
        {
            armed = g_byPath.contains(std::string(lua.get_string()));
        }
        lua.set_bool(armed);
        return 1;
    }

    auto lua_skip(const LuaMadeSimple::Lua& lua) -> int
    {
        bool ok = false;
        if (lua.is_string())
        {
            auto it = g_byPath.find(std::string(lua.get_string()));
            if (it != g_byPath.end())
            {
                g_skipFn = it->second;
                g_skipSeq = g_callSeq;
                ok = true;
            }
        }
        lua.set_bool(ok);
        return 1;
    }

    auto lua_skipCount(const LuaMadeSimple::Lua& lua) -> int
    {
        lua.set_integer(g_skipCount);
        return 1;
    }

    // ---- Game calls ----

    struct GameFn
    {
        uintptr_t Rva;
        uint8_t Prologue[16];
        void* Address = nullptr;
    };

    GameFn g_setCommanded{0x063A7FF0, {0x4C, 0x8B, 0xDC, 0x49, 0x89, 0x53, 0x10, 0x53, 0x56, 0x48, 0x83, 0xEC, 0x68, 0x48, 0x8B, 0xF1}};
    GameFn g_closestSettlement{0x065559E0, {0x48, 0x8B, 0xC4, 0x53, 0x41, 0x56, 0x48, 0x83, 0xEC, 0x78, 0x48, 0x89, 0x68, 0x08, 0x45, 0x33}};
    constexpr size_t kCallToArmsOffset = 0x1ED;

    struct FVectorD
    {
        double X, Y, Z;
    };
    using SetCommandedFn = void (*)(UObject* Component, UObject* GroupData);
    using ClosestSettlementFn = UObject* (*)(const UObject* WorldContext, FVectorD Location, float Radius, UObject* Ignore);

    // 0.4.5: static AMistTownNpc* AMistTownNpc::GenerateImmigrant(const UObject*, FVector, const UMistNpcTemplate*):
    // GenerateNewNpc (always spawns, new GUID, template's faction) + SetRole(Worker) + UpdateBehaviorClass. It does not
    // check its arguments (SetRole on the result without a null check), so both objects are validated first.
    GameFn g_generateImmigrant{0x06B779C0, {0x40, 0x53, 0x48, 0x83, 0xEC, 0x50, 0xF2, 0x0F, 0x10, 0x4A, 0x10, 0x4C, 0x8D, 0x4C, 0x24, 0x20}};
    using GenerateImmigrantFn = UObject* (*)(const UObject* WorldContext, FVectorD Location, const UObject* Template);
    UClass* g_npcTemplateClass = nullptr;
    bool g_newcomerReady = false;

    UClass* g_commandComponentClass = nullptr;
    UClass* g_groupDataClass = nullptr;
    bool g_gameCallsReady = false;

    auto resolveGameFn(GameFn& f, const wchar_t* name) -> bool
    {
        auto* base = reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr));
        auto* p = base + f.Rva;
        if (memcmp(p, f.Prologue, sizeof(f.Prologue)) != 0)
        {
            log(std::format(STR("{} not at its expected address (game updated?); game calls off"), name));
            return false;
        }
        f.Address = p;
        return true;
    }

    auto resolveGameCalls() -> void
    {
        g_commandComponentClass = UObjectGlobals::StaticFindObject<UClass*>(nullptr, nullptr, STR("/Script/Mist.MistPlayerCommandComponent"));
        g_groupDataClass = UObjectGlobals::StaticFindObject<UClass*>(nullptr, nullptr, STR("/Script/Mist.MistCombatGroupData"));
        bool ok = g_commandComponentClass && g_groupDataClass;
        if (!ok) log(STR("squad classes not found; game calls off"));
        ok = resolveGameFn(g_setCommanded, STR("SetCommandedCombatGroup")) && ok;
        ok = resolveGameFn(g_closestSettlement, STR("FindClosestPlayerSettlement")) && ok;
        g_gameCallsReady = ok;
        log(ok ? STR("game calls ready") : STR("game calls NOT ready"));
        // newcomers (0.4.5) are separate: a mismatch here turns off only that feature
        g_npcTemplateClass = UObjectGlobals::StaticFindObject<UClass*>(nullptr, nullptr, STR("/Script/Mist.MistNpcTemplate"));
        g_newcomerReady = g_npcTemplateClass != nullptr && resolveGameFn(g_generateImmigrant, STR("GenerateImmigrant"));
        log(g_newcomerReady ? STR("newcomer spawn ready") : STR("newcomer spawn NOT ready"));
    }

    // Lua argument helpers: each consumes the value at the bottom of the argument stack.
    // Objects come from Lua as addresses (obj:GetAddress(); UE4SS does not export its Lua object
    // type to C++ mods) and must still be live objects in the global object array.
    auto takeObject(const LuaMadeSimple::Lua& lua) -> UObject*
    {
        if (!lua.is_integer())
        {
            lua.discard_value();
            return nullptr;
        }
        auto* obj = reinterpret_cast<UObject*>(static_cast<uintptr_t>(lua.get_integer()));
        if (!obj) return nullptr;
        auto* item = UObjectArray::IndexToObject(obj->GetInternalIndex());
        if (!item || item->GetUObject() != obj || item->IsUnreachable()) return nullptr;
        return obj;
    }

    auto takeNumber(const LuaMadeSimple::Lua& lua) -> double
    {
        if (lua.is_number()) return lua.get_number();
        lua.discard_value();
        return 0.0;
    }

    auto takeBool(const LuaMadeSimple::Lua& lua) -> bool
    {
        if (lua.is_bool()) return lua.get_bool();
        lua.discard_value();
        return false;
    }

    auto lua_gameCallsReady(const LuaMadeSimple::Lua& lua) -> int
    {
        lua.set_bool(g_gameCallsReady);
        return 1;
    }

    auto lua_setCommandedGroup(const LuaMadeSimple::Lua& lua) -> int
    {
        UObject* component = takeObject(lua);
        UObject* group = takeObject(lua);
        bool ok = g_gameCallsReady && component && component->IsA(g_commandComponentClass) &&
                  (!group || group->IsA(g_groupDataClass));
        if (ok) reinterpret_cast<SetCommandedFn>(g_setCommanded.Address)(component, group);
        lua.set_bool(ok);
        return 1;
    }

    auto lua_getCallToArms(const LuaMadeSimple::Lua& lua) -> int
    {
        UObject* group = takeObject(lua);
        bool on = false;
        if (g_gameCallsReady && group && group->IsA(g_groupDataClass))
        {
            on = reinterpret_cast<uint8_t*>(group)[kCallToArmsOffset] != 0;
        }
        lua.set_bool(on);
        return 1;
    }

    auto lua_setCallToArms(const LuaMadeSimple::Lua& lua) -> int
    {
        UObject* group = takeObject(lua);
        bool value = takeBool(lua);
        bool previous = false;
        if (g_gameCallsReady && group && group->IsA(g_groupDataClass))
        {
            auto* flag = reinterpret_cast<uint8_t*>(group) + kCallToArmsOffset;
            previous = *flag != 0;
            *flag = value ? 1 : 0;
        }
        lua.set_bool(previous);
        return 1;
    }

    auto squadFlagOffsetOk(int64_t offset) -> bool
    {
        return offset == 0x1EC || offset == 0x1ED || offset == 0x1EE;
    }

    auto lua_getSquadFlag(const LuaMadeSimple::Lua& lua) -> int
    {
        UObject* group = takeObject(lua);
        int64_t offset = lua.is_integer() ? lua.get_integer() : (lua.discard_value(), 0);
        bool on = false;
        if (g_gameCallsReady && group && group->IsA(g_groupDataClass) && squadFlagOffsetOk(offset))
        {
            on = reinterpret_cast<uint8_t*>(group)[offset] != 0;
        }
        lua.set_bool(on);
        return 1;
    }

    auto lua_setSquadFlag(const LuaMadeSimple::Lua& lua) -> int
    {
        UObject* group = takeObject(lua);
        int64_t offset = lua.is_integer() ? lua.get_integer() : (lua.discard_value(), 0);
        bool value = takeBool(lua);
        bool previous = false;
        if (g_gameCallsReady && group && group->IsA(g_groupDataClass) && squadFlagOffsetOk(offset))
        {
            auto* flag = reinterpret_cast<uint8_t*>(group) + offset;
            previous = *flag != 0;
            *flag = value ? 1 : 0;
        }
        lua.set_bool(previous);
        return 1;
    }

    auto lua_closestPlayerSettlement(const LuaMadeSimple::Lua& lua) -> int
    {
        UObject* context = takeObject(lua);
        FVectorD v{};
        v.X = takeNumber(lua);
        v.Y = takeNumber(lua);
        v.Z = takeNumber(lua);
        UObject* settlement = nullptr;
        if (g_gameCallsReady && context)
        {
            settlement = reinterpret_cast<ClosestSettlementFn>(g_closestSettlement.Address)(context, v, 10000.0f, nullptr);
        }
        lua.set_integer(static_cast<int64_t>(reinterpret_cast<uintptr_t>(settlement)));
        return 1;
    }

    // 0.4.5: BWNative_SpawnNewcomer(worldContext, templateCdo, x, y, z) -> the new AMistTownNpc's address, 0 when refused.
    // templateCdo must be a live UMistNpcTemplate (a template Blueprint's default object). Game thread only.
    auto lua_spawnNewcomer(const LuaMadeSimple::Lua& lua) -> int
    {
        UObject* context = takeObject(lua);
        UObject* tpl = takeObject(lua);
        FVectorD v{};
        v.X = takeNumber(lua);
        v.Y = takeNumber(lua);
        v.Z = takeNumber(lua);
        UObject* npc = nullptr;
        if (g_newcomerReady && context && tpl && tpl->IsA(g_npcTemplateClass))
        {
            npc = reinterpret_cast<GenerateImmigrantFn>(g_generateImmigrant.Address)(context, v, tpl);
        }
        lua.set_integer(static_cast<int64_t>(reinterpret_cast<uintptr_t>(npc)));
        return 1;
    }

    auto lua_newcomerReady(const LuaMadeSimple::Lua& lua) -> int
    {
        lua.set_bool(g_newcomerReady);
        return 1;
    }

    // 0.4.4: a caravan route stop's item requests (UMistCaravanRouteStopData, not reflected beyond Item):
    // TArray<FMistCaravanRouteStopItemRequest> at +0xF8 (load rules) or +0x110 (unload requests), 0x20 bytes each:
    // request GUID +0x00, Item +0x10, order type byte +0x18 (EMistDeliveryOrderType), quantity int32 +0x1C
    // (ServerSetItemRequestQuantity 0x063F1060, ServerAddItemRequest 0x063F0130). The GUID is what the
    // Server_CaravanRouteStop_ItemRequest_* requests take as ItemRequestId.
    //   BWNative_ItemRequests(stopData, isLoad) -> "A,B,C,D,type,qty;..." in array order (signed GUID parts), "" if none,
    //   nil if the object is not a route stop.
    UClass* g_routeStopClass = nullptr;

    auto lua_itemRequests(const LuaMadeSimple::Lua& lua) -> int
    {
        UObject* stop = takeObject(lua);
        bool isLoad = takeBool(lua);
        if (!g_routeStopClass)
        {
            g_routeStopClass = UObjectGlobals::StaticFindObject<UClass*>(nullptr, nullptr, STR("/Script/Mist.MistCaravanRouteStopData"));
        }
        if (!stop || !g_routeStopClass || !stop->IsA(g_routeStopClass))
        {
            lua.set_nil();
            return 1;
        }
        struct RawArray
        {
            uint8_t* Data;
            int32_t Num;
            int32_t Max;
        };
        const auto* arr = reinterpret_cast<const RawArray*>(reinterpret_cast<const uint8_t*>(stop) + (isLoad ? 0xF8 : 0x110));
        std::string out;
        if (arr->Num > 0 && arr->Num <= 1000 && arr->Max >= arr->Num && arr->Data)
        {
            for (int32_t i = 0; i < arr->Num; ++i)
            {
                const uint8_t* e = arr->Data + static_cast<size_t>(i) * 0x20;
                const auto* g = reinterpret_cast<const int32_t*>(e);
                out += std::format("{}{},{},{},{},{},{}", i ? ";" : "", g[0], g[1], g[2], g[3], static_cast<int>(e[0x18]),
                                   *reinterpret_cast<const int32_t*>(e + 0x1C));
            }
        }
        lua.set_string(out);
        return 1;
    }

    auto registerLua(LuaMadeSimple::Lua& lua) -> void
    {
        lua.register_function("BWNative_ItemRequests", lua_itemRequests);
        lua.register_function("BWNative_GameCallsReady", lua_gameCallsReady);
        lua.register_function("BWNative_SetCommandedGroup", lua_setCommandedGroup);
        lua.register_function("BWNative_GetCallToArms", lua_getCallToArms);
        lua.register_function("BWNative_SetCallToArms", lua_setCallToArms);
        lua.register_function("BWNative_GetSquadFlag", lua_getSquadFlag);
        lua.register_function("BWNative_SetSquadFlag", lua_setSquadFlag);
        lua.register_function("BWNative_ClosestPlayerSettlement", lua_closestPlayerSettlement);
        lua.register_function("BWNative_SpawnNewcomer", lua_spawnNewcomer);
        lua.register_function("BWNative_NewcomerReady", lua_newcomerReady);
        lua.register_function("BWNative_Version", lua_version);
        lua.register_function("BWNative_IsArmed", lua_isArmed);
        lua.register_function("BWNative_Skip", lua_skip);
        lua.register_function("BWNative_SkipCount", lua_skipCount);
        bwcoop::rates_register(lua);
        bwcoop::sleep_register(lua);
        bwcoop::gui_register(lua);
    }
} // namespace

namespace bwcoop
{
    void log(const std::wstring& msg) { Output::send<LogLevel::Default>(STR("[BWCoopNative] {}\n"), msg); }
    UObject* takeObject(const LuaMadeSimple::Lua& lua) { return ::takeObject(lua); }
    double takeNumber(const LuaMadeSimple::Lua& lua) { return ::takeNumber(lua); }
    bool takeBool(const LuaMadeSimple::Lua& lua) { return ::takeBool(lua); }
    std::string takeString(const LuaMadeSimple::Lua& lua)
    {
        if (lua.is_string()) return std::string(lua.get_string());
        lua.discard_value();
        return {};
    }
    bool prologueOk(uintptr_t rva, const uint8_t (&prologue)[16])
    {
        auto* base = reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr));
        return memcmp(base + rva, prologue, sizeof(prologue)) == 0;
    }
} // namespace bwcoop

class BWCoopNative : public CppUserModBase
{
public:
    BWCoopNative() : CppUserModBase()
    {
        ModName = STR("BWCoopNative");
        ModVersion = STR("0.4.6");
        ModDescription = STR("Lets the BWCoop Lua mod skip guarded game functions");
        ModAuthors = STR("Parakalix");
        register_tab(STR("BWCoop"), [](CppUserModBase*) { bwcoop::gui_render(); });
    }

    ~BWCoopNative() override
    {
        bwcoop::sleep_shutdown();
        bwcoop::rates_shutdown();
        disarmAll();
    }

    auto on_unreal_init() -> void override
    {
        armAll();
        resolveGameCalls();
        bwcoop::rates_init();
        bwcoop::sleep_init();
    }

    auto on_ui_init() -> void override
    {
        UE4SS_ENABLE_IMGUI()
    }

    auto on_lua_start(StringViewType mod_name,
                      LuaMadeSimple::Lua& lua,
                      LuaMadeSimple::Lua& main_lua,
                      LuaMadeSimple::Lua& async_lua,
                      LuaMadeSimple::Lua* hook_lua) -> void override
    {
        if (mod_name != STR("BWCoop")) return;
        registerLua(lua);
        registerLua(main_lua);
        if (hook_lua) registerLua(*hook_lua);
        log(STR("Lua functions registered for BWCoop"));
    }
};

#define BWCOOP_NATIVE_API __declspec(dllexport)
extern "C"
{
    BWCOOP_NATIVE_API CppUserModBase* start_mod()
    {
        return new BWCoopNative();
    }

    BWCOOP_NATIVE_API void uninstall_mod(CppUserModBase* mod)
    {
        delete mod;
    }
}
