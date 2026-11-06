// Per-player rates: skill XP, crafting speed and crafting cost, plus the game's global multipliers.
//
// The game has no per-player rates; its cheats set server-wide globals (GCraftingSpeedMultiplier,
// GCraftingCostMultiplier, GBuildingCostMultiplier, GCraftingResultMultiplier, set through
// AMistOasisGameState::Set*Multiplier). These detours apply a player's own rate only inside that
// player's own calls (addresses from the shipped PDB, Bellwright build 24840601, prologue-checked):
//   AMistHuman::ImproveSkill(skill, amount)          every skill XP gain; amount *= the human's XP rate
//   UMistTownCraftingComponent::CalculatePlayerCraftingTime(player, recipe, item)
//                                                    time / GCraftingSpeedMultiplier; swapped per player
//   FMistCraftingState::SetContainersFromPlayer(player)  start of a player's craft (station or by hand)
//   FMistItemRecipe::GetInputs()                     materials * GCraftingCostMultiplier; swapped only inside
//                                                    a player's own craft calls (below). 0.4.2: it used to be a
//                                                    100 ms window after SetContainersFromPlayer, which leaked
//                                                    into the settlement ledger's timer (GetItemCost): a 0 count
//                                                    there divides by zero (crash 2026-10-11 20:04, cost x0).
//   Scope of a player's own craft (0.4.2): UMistCraftingComponent::CraftItem (hand crafting),
//   UMistTownCraftingComponent::StartPlayerOrder and ::CanPlayerCraft (stations),
//   UMistPersonalCraftListItemWidget::UpdateCraftingState (the host's own craft list); none divide by counts.
//   FMistCraftingState::Craft(player, ...)           end of that craft: context cleared
// Building cost (GBuildingCostMultiplier) is swapped by the Lua mod around the player's own placement
// requests with BWNative_SetGlobal.
//   UMistKnowledgeItemStatusEffect::GetDuration()    how long reading a skill book takes; 1 s while the
//                                                    Lua mod flags a player's own ServerReadBook (0.3.1)
//   UMistKnowledgeItemTemplate::ApplyEffects(human)  0.4.2: where the reading effect is really added (when the
//                                                    read finishes, after ServerReadBook has returned, so the
//                                                    0.3.1 flag missed it); 1 s for humans with instant books
// Skills (0.3.1): AMistHuman::GetSkillLevel / AMistHuman::SetSkill (what the game's set-skill cheats
// call), and GetLookAtActor(player, out actor, out index) (what its "villager you look at" cheats use).
// 0.4.2: SetSkill is followed by the rest of the cheat's steps (XP to next level, UpdateStats), so the new
// level shows and sticks.
//
// Lua functions:
//   BWNative_RatesReady() -> bool
//   BWNative_ClearPlayerRates()
//   BWNative_SetPlayerRates(humanAddress, xp, craftSpeed, craftCost)
//   BWNative_GetGlobal(name) -> number|nil        name: craft_speed, craft_cost, build_cost, craft_result
//   BWNative_SetGlobal(name, value) -> bool
//   BWNative_SetInstantRead(bool)                 while true, skill books take 1 second (0.3.1)
//   BWNative_SetPlayerInstantRead(humanAddress, bool)   that human's books take 1 second (0.4.2)
//   BWNative_LookAtActor(playerPawnAddress) -> actor address|0
//   BWNative_GetSkill(humanAddress, skill) -> level|nil      skill = EMistNpcSkill value 1..14
//   BWNative_SetSkill(humanAddress, skill, level) -> bool

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <Windows.h>

#include <format>
#include <memory>
#include <mutex>
#include <random>
#include <unordered_map>
#include <vector>

#include <polyhook2/Detour/x64Detour.hpp>

#include <DynamicOutput/DynamicOutput.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#include <Unreal/UObjectGlobals.hpp>

#include "bwcoop.hpp"

namespace bwcoop
{
    namespace
    {
        struct Rates
        {
            float Xp = 1.0f;
            float Speed = 1.0f;
            float Cost = 1.0f;
            bool Read = false;
        };

        std::mutex g_mx;
        std::unordered_map<const void*, Rates> g_rates;
        bool g_ready = false;

        auto lookup(const void* who) -> Rates
        {
            std::lock_guard lock(g_mx);
            auto it = g_rates.find(who);
            return it == g_rates.end() ? Rates{} : it->second;
        }

        auto random01() -> float
        {
            thread_local std::mt19937 rng{std::random_device{}()};
            return std::uniform_real_distribution<float>(0.0f, 1.0f)(rng);
        }

        // ---- globals, found through their setters: cmp byte [rcx+170h],3 / jne / movss [rip+disp],xmm1
        struct Global
        {
            const char* Name;
            uintptr_t SetterRva;
            float* Address = nullptr;
        };
        Global g_globals[] = {
            {"craft_speed", 0x064970E0},
            {"craft_cost", 0x064970A0},
            {"build_cost", 0x06496EA0},
            {"craft_result", 0x064970C0},
        };

        auto resolveGlobals() -> bool
        {
            static const uint8_t pattern[13] = {0x80, 0xB9, 0x70, 0x01, 0x00, 0x00, 0x03, 0x75, 0x08, 0xF3, 0x0F, 0x11, 0x0D};
            auto* base = reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr));
            for (auto& g : g_globals)
            {
                auto* p = base + g.SetterRva;
                if (memcmp(p, pattern, sizeof(pattern)) != 0) return false;
                int32_t disp = 0;
                memcpy(&disp, p + 13, 4);
                g.Address = reinterpret_cast<float*>(p + 17 + disp);
            }
            return true;
        }

        auto findGlobal(const std::string& name) -> float*
        {
            for (auto& g : g_globals)
                if (name == g.Name) return g.Address;
            return nullptr;
        }

        float* g_speed = nullptr;
        float* g_cost = nullptr;

        // ---- detours
        struct Hook
        {
            const wchar_t* Name;
            uintptr_t Rva;
            uint8_t Prologue[16];
            uint64_t* Trampoline;
            void* Callback;
            std::unique_ptr<PLH::x64Detour> Detour;
        };

        uint64_t t_improve = 0, t_calcTime = 0, t_setContainers = 0, t_getInputs = 0, t_craft = 0, t_bookDuration = 0,
                 t_applyBook = 0;

        using ImproveSkillFn = void (*)(void*, int32_t, int32_t);
        using CalcTimeFn = float (*)(void*, void*, const void*, const void*);
        using SetContainersFn = void (*)(void*, void*);
        using GetInputsFn = void* (*)(const void*, void*);
        using CraftFn = bool (*)(void*, void*, void*, void*);
        using BookDurationFn = float (*)(void*);
        using ApplyBookFn = void (*)(const void*, void*);

        thread_local bool t_instantRead = false;

        float hk_bookDuration(void* effect)
        {
            if (t_instantRead) return 1.0f;
            return reinterpret_cast<BookDurationFn>(t_bookDuration)(effect);
        }

        void hk_applyBook(const void* book, void* human)
        {
            bool before = t_instantRead;
            if (lookup(human).Read) t_instantRead = true;
            reinterpret_cast<ApplyBookFn>(t_applyBook)(book, human);
            t_instantRead = before;
        }

        // ---- skills (direct calls, game thread)
        struct Direct
        {
            uintptr_t Rva;
            uint8_t Prologue[16];
            void* Address = nullptr;
        };
        Direct g_getSkill{0x06365FF0, {0x48, 0x8B, 0x81, 0x80, 0x0C, 0x00, 0x00, 0x4C, 0x63, 0xC2, 0x4D, 0x03, 0xC0, 0x42, 0x8B, 0x84}};
        Direct g_setSkill{0x0636D340, {0x40, 0x53, 0x48, 0x83, 0xEC, 0x20, 0x48, 0x8B, 0x81, 0x80, 0x0C, 0x00, 0x00, 0x48, 0x8B, 0xD9}};
        Direct g_lookAt{0x06B25F50, {0x40, 0x55, 0x53, 0x56, 0x57, 0x41, 0x56, 0x48, 0x8D, 0xAC, 0x24, 0xC0, 0xFE, 0xFF, 0xFF, 0x48}};
        // 0.4.2: after SetSkill, the rest of what the game's own set-skill cheat does
        // (UMistCheatingComponent::ServerSetAllPlayerSkills): XP to the next level from the progression
        // curve (settings +0x190, a soft pointer to a UCurveFloat), then UpdateStats, which recomputes the
        // level the game shows and uses (GetSkillLevel reads that one). Without UpdateStats nothing changed.
        Direct g_updateStats{0x0636FE50, {0x48, 0x8B, 0xC4, 0x57, 0x48, 0x83, 0xEC, 0x60, 0x80, 0xB9, 0x70, 0x01, 0x00, 0x00, 0x03, 0x48}};
        Direct g_setExpToNext{0x0636D230, {0x40, 0x53, 0x48, 0x83, 0xEC, 0x20, 0x48, 0x8B, 0x81, 0x80, 0x0C, 0x00, 0x00, 0x48, 0x8B, 0xD9}};
        Direct g_progression{0x0654E460, {0x40, 0x53, 0x48, 0x83, 0xEC, 0x20, 0xE8, 0xB5, 0xFA, 0xB2, 0xFF, 0x48, 0x8B, 0xD8, 0x48, 0x83}};
        Direct g_loadCurve{0x063AC9C0, {0x48, 0x89, 0x5C, 0x24, 0x08, 0x57, 0x48, 0x83, 0xEC, 0x30, 0x0F, 0x29, 0x74, 0x24, 0x20, 0x48}};
        Direct g_curveValue{0x03BE4440, {0x48, 0x83, 0xC1, 0x30, 0x0F, 0x57, 0xD2, 0xE9, 0x44, 0x96, 0xFF, 0xFF, 0xCC, 0xCC, 0xCC, 0xCC}};
        // In the cheat: movaps xmm1,xmm6 (-1.0) / lea rcx,[rax+190h] / call LoadAssetSynchronous<UCurveFloat>
        const uint8_t kCurveFieldRead[16] = {0x0F, 0x28, 0xCE, 0x48, 0x8D, 0x88, 0x90, 0x01, 0x00, 0x00, 0xE8, 0xAF, 0xA6, 0x87, 0xFF, 0x48};
        bool g_expReady = false;
        using GetSkillFn = int32_t (*)(const void*, int32_t);
        using SetSkillFn = void (*)(void*, int32_t, int32_t);
        using UpdateStatsFn = void (*)(void*);
        using ProgressionFn = const uint8_t* (*)();
        using LoadCurveFn = void* (*)(const void* softPtr, float);
        using CurveValueFn = float (*)(const void* curve, float);
        using LookAtFn = bool (*)(void*, void**, int32_t*);
        RC::Unreal::UClass* g_humanClass = nullptr;
        RC::Unreal::UClass* g_playerClass = nullptr;

        auto resolveDirect(Direct& d) -> bool
        {
            if (!prologueOk(d.Rva, d.Prologue)) return false;
            d.Address = reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr)) + d.Rva;
            return true;
        }

        void hk_improveSkill(void* human, int32_t skill, int32_t amount)
        {
            if (amount > 0)
            {
                float rate = lookup(human).Xp;
                if (rate != 1.0f)
                {
                    float v = amount * (rate < 0.0f ? 0.0f : rate);
                    int32_t whole = static_cast<int32_t>(v);
                    if (random01() < v - static_cast<float>(whole)) ++whole;
                    if (whole <= 0) return;
                    amount = whole;
                }
            }
            reinterpret_cast<ImproveSkillFn>(t_improve)(human, skill, amount);
        }

        float hk_calcTime(void* component, void* player, const void* recipe, const void* item)
        {
            float rate = lookup(player).Speed;
            if (rate != 1.0f && rate > 0.0f && g_speed)
            {
                float saved = *g_speed;
                *g_speed = saved * rate;
                float result = reinterpret_cast<CalcTimeFn>(t_calcTime)(component, player, recipe, item);
                *g_speed = saved;
                return result;
            }
            return reinterpret_cast<CalcTimeFn>(t_calcTime)(component, player, recipe, item);
        }

        thread_local void* t_ctxPlayer = nullptr;
        thread_local ULONGLONG t_ctxTick = 0;
        thread_local int t_craftScope = 0; // > 0 inside a player's own craft call

        // Marks the dynamic extent of a player's own craft call; the craft context ends with the outermost one.
        struct CraftScope
        {
            CraftScope()
            {
                if (t_craftScope++ == 0) t_ctxPlayer = nullptr; // only this call's SetContainersFromPlayer counts
            }
            ~CraftScope()
            {
                if (--t_craftScope == 0) t_ctxPlayer = nullptr;
            }
        };

        void hk_setContainers(void* state, void* player)
        {
            t_ctxPlayer = player;
            t_ctxTick = GetTickCount64();
            reinterpret_cast<SetContainersFn>(t_setContainers)(state, player);
        }

        void* hk_getInputs(const void* recipe, void* result)
        {
            if (t_craftScope > 0 && t_ctxPlayer && g_cost)
            {
                float rate = lookup(t_ctxPlayer).Cost;
                if (rate != 1.0f && rate >= 0.0f)
                {
                    float saved = *g_cost;
                    *g_cost = saved * rate;
                    void* r = reinterpret_cast<GetInputsFn>(t_getInputs)(recipe, result);
                    *g_cost = saved;
                    return r;
                }
            }
            return reinterpret_cast<GetInputsFn>(t_getInputs)(recipe, result);
        }

        bool hk_craft(void* state, void* player, void* outItems, void* outSlot)
        {
            bool r = reinterpret_cast<CraftFn>(t_craft)(state, player, outItems, outSlot);
            t_ctxPlayer = nullptr;
            return r;
        }

        uint64_t t_craftItem = 0, t_startOrder = 0, t_canPlayerCraft = 0, t_craftListState = 0;
        using CraftItemFn = void (*)(void*, const void*, int32_t);
        using StartOrderFn = void (*)(void*);
        using CanPlayerCraftFn = bool (*)(void*, void*, const void*, int32_t, const void*);
        using CraftListStateFn = void (*)(void*);

        void hk_craftItem(void* component, const void* item, int32_t count)
        {
            CraftScope scope;
            reinterpret_cast<CraftItemFn>(t_craftItem)(component, item, count);
        }

        void hk_startOrder(void* component)
        {
            CraftScope scope;
            reinterpret_cast<StartOrderFn>(t_startOrder)(component);
        }

        bool hk_canPlayerCraft(void* component, void* player, const void* item, int32_t count, const void* withItem)
        {
            CraftScope scope;
            return reinterpret_cast<CanPlayerCraftFn>(t_canPlayerCraft)(component, player, item, count, withItem);
        }

        void hk_craftListState(void* widget)
        {
            CraftScope scope;
            reinterpret_cast<CraftListStateFn>(t_craftListState)(widget);
        }

        std::vector<Hook> g_hooks;

        auto installHooks() -> bool
        {
            g_hooks.clear();
            g_hooks.push_back({L"ImproveSkill", 0x06366720,
                               {0x45, 0x85, 0xC0, 0x0F, 0x8E, 0x52, 0x02, 0x00, 0x00, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57, 0x48},
                               &t_improve, reinterpret_cast<void*>(&hk_improveSkill)});
            g_hooks.push_back({L"CalculatePlayerCraftingTime", 0x063B0DF0,
                               {0x48, 0x89, 0x74, 0x24, 0x20, 0x41, 0x56, 0x48, 0x83, 0xEC, 0x50, 0x49, 0x8B, 0x40, 0x08, 0x4D},
                               &t_calcTime, reinterpret_cast<void*>(&hk_calcTime)});
            g_hooks.push_back({L"SetContainersFromPlayer", 0x063BFBE0,
                               {0x48, 0x89, 0x5C, 0x24, 0x18, 0x55, 0x56, 0x57, 0x41, 0x56, 0x41, 0x57, 0x48, 0x81, 0xEC, 0x10},
                               &t_setContainers, reinterpret_cast<void*>(&hk_setContainers)});
            g_hooks.push_back({L"GetInputs", 0x0651CF90,
                               {0x48, 0x8B, 0xC4, 0x48, 0x89, 0x58, 0x18, 0x48, 0x89, 0x70, 0x20, 0x55, 0x57, 0x41, 0x54, 0x41},
                               &t_getInputs, reinterpret_cast<void*>(&hk_getInputs)});
            g_hooks.push_back({L"KnowledgeItemStatusEffect::GetDuration", 0x06752BA0,
                               {0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x74, 0x24, 0x10, 0x57, 0x48, 0x83, 0xEC, 0x20, 0x48},
                               &t_bookDuration, reinterpret_cast<void*>(&hk_bookDuration)});
            g_hooks.push_back({L"Craft", 0x063B2990,
                               {0x40, 0x55, 0x56, 0x41, 0x54, 0x41, 0x56, 0x41, 0x57, 0x48, 0x8D, 0xAC, 0x24, 0xE0, 0xFE, 0xFF},
                               &t_craft, reinterpret_cast<void*>(&hk_craft)});
            g_hooks.push_back({L"CraftItem", 0x063B3560,
                               {0x48, 0x89, 0x5C, 0x24, 0x20, 0x55, 0x56, 0x57, 0x48, 0x8D, 0xAC, 0x24, 0x50, 0xFF, 0xFF, 0xFF},
                               &t_craftItem, reinterpret_cast<void*>(&hk_craftItem)});
            g_hooks.push_back({L"StartPlayerOrder", 0x063C1680,
                               {0x40, 0x55, 0x57, 0x48, 0x8D, 0xAC, 0x24, 0x18, 0xFF, 0xFF, 0xFF, 0x48, 0x81, 0xEC, 0xE8, 0x01},
                               &t_startOrder, reinterpret_cast<void*>(&hk_startOrder)});
            g_hooks.push_back({L"CanPlayerCraft", 0x063B1800,
                               {0x40, 0x55, 0x53, 0x56, 0x57, 0x41, 0x54, 0x41, 0x57, 0x48, 0x8D, 0xAC, 0x24, 0x48, 0xFF, 0xFF},
                               &t_canPlayerCraft, reinterpret_cast<void*>(&hk_canPlayerCraft)});
            g_hooks.push_back({L"PersonalCraftListItemWidget::UpdateCraftingState", 0x06959010,
                               {0x40, 0x53, 0x48, 0x81, 0xEC, 0x80, 0x00, 0x00, 0x00, 0x48, 0x8B, 0x05, 0xA0, 0x25, 0x4C, 0x05},
                               &t_craftListState, reinterpret_cast<void*>(&hk_craftListState)});
            g_hooks.push_back({L"KnowledgeItemTemplate::ApplyEffects", 0x06A37700,
                               {0x40, 0x53, 0x48, 0x83, 0xEC, 0x30, 0x80, 0x3D, 0xAC, 0x4E, 0x54, 0x05, 0x00, 0x48, 0x8B, 0x89},
                               &t_applyBook, reinterpret_cast<void*>(&hk_applyBook)});
            for (auto& h : g_hooks)
            {
                if (!prologueOk(h.Rva, h.Prologue))
                {
                    log(std::format(L"{} not at its expected address (game updated?); rates off", h.Name));
                    return false;
                }
            }
            auto base = reinterpret_cast<uint64_t>(GetModuleHandleW(nullptr));
            for (auto& h : g_hooks)
            {
                h.Detour = std::make_unique<PLH::x64Detour>(base + h.Rva, reinterpret_cast<uint64_t>(h.Callback), h.Trampoline);
                if (!h.Detour->hook())
                {
                    log(std::format(L"could not hook {}; rates off", h.Name));
                    return false;
                }
            }
            return true;
        }

        // ---- Lua
        auto lua_ready(const RC::LuaMadeSimple::Lua& lua) -> int
        {
            lua.set_bool(g_ready);
            return 1;
        }

        auto lua_clear(const RC::LuaMadeSimple::Lua& lua) -> int
        {
            std::lock_guard lock(g_mx);
            g_rates.clear();
            return 0;
        }

        auto lua_set(const RC::LuaMadeSimple::Lua& lua) -> int
        {
            auto* who = takeObject(lua);
            Rates r;
            r.Xp = static_cast<float>(takeNumber(lua));
            r.Speed = static_cast<float>(takeNumber(lua));
            r.Cost = static_cast<float>(takeNumber(lua));
            bool ok = who != nullptr;
            if (ok)
            {
                std::lock_guard lock(g_mx);
                r.Read = g_rates[who].Read;
                g_rates[who] = r;
            }
            lua.set_bool(ok);
            return 1;
        }

        auto lua_getGlobal(const RC::LuaMadeSimple::Lua& lua) -> int
        {
            float* p = findGlobal(takeString(lua));
            if (p)
                lua.set_number(*p);
            else
                lua.set_nil();
            return 1;
        }

        auto lua_setInstantRead(const RC::LuaMadeSimple::Lua& lua) -> int
        {
            t_instantRead = takeBool(lua);
            return 0;
        }

        auto lua_setPlayerRead(const RC::LuaMadeSimple::Lua& lua) -> int
        {
            auto* who = takeObject(lua);
            bool read = takeBool(lua);
            if (who)
            {
                std::lock_guard lock(g_mx);
                g_rates[who].Read = read;
            }
            lua.set_bool(who != nullptr);
            return 1;
        }

        auto isA(RC::Unreal::UObject* o, RC::Unreal::UClass* c) -> bool
        {
            return o && c && o->IsA(c);
        }

        auto lua_lookAt(const RC::LuaMadeSimple::Lua& lua) -> int
        {
            auto* pawn = takeObject(lua);
            void* actor = nullptr;
            int32_t index = 0;
            if (g_lookAt.Address && isA(pawn, g_playerClass))
            {
                reinterpret_cast<LookAtFn>(g_lookAt.Address)(pawn, &actor, &index);
            }
            lua.set_integer(static_cast<int64_t>(reinterpret_cast<uintptr_t>(actor)));
            return 1;
        }

        auto lua_getSkill(const RC::LuaMadeSimple::Lua& lua) -> int
        {
            auto* human = takeObject(lua);
            int32_t skill = static_cast<int32_t>(takeNumber(lua));
            if (g_getSkill.Address && isA(human, g_humanClass) && skill >= 1 && skill <= 14)
            {
                lua.set_integer(reinterpret_cast<GetSkillFn>(g_getSkill.Address)(human, skill));
            }
            else
            {
                lua.set_nil();
            }
            return 1;
        }

        auto lua_setSkill(const RC::LuaMadeSimple::Lua& lua) -> int
        {
            auto* human = takeObject(lua);
            int32_t skill = static_cast<int32_t>(takeNumber(lua));
            int32_t level = static_cast<int32_t>(takeNumber(lua));
            bool ok = g_setSkill.Address && isA(human, g_humanClass) && skill >= 1 && skill <= 14 && level >= 0;
            if (ok)
            {
                reinterpret_cast<SetSkillFn>(g_setSkill.Address)(human, skill, level);
                if (g_expReady)
                {
                    const uint8_t* settings = reinterpret_cast<ProgressionFn>(g_progression.Address)();
                    void* curve = settings ? reinterpret_cast<LoadCurveFn>(g_loadCurve.Address)(settings + 0x190, -1.0f) : nullptr;
                    if (curve)
                    {
                        float exp = reinterpret_cast<CurveValueFn>(g_curveValue.Address)(curve, static_cast<float>(level));
                        reinterpret_cast<SetSkillFn>(g_setExpToNext.Address)(human, skill, static_cast<int32_t>(exp));
                    }
                }
                reinterpret_cast<UpdateStatsFn>(g_updateStats.Address)(human);
            }
            lua.set_bool(ok);
            return 1;
        }

        auto lua_setGlobal(const RC::LuaMadeSimple::Lua& lua) -> int
        {
            float* p = findGlobal(takeString(lua));
            double v = takeNumber(lua);
            bool ok = p != nullptr && v >= 0.0;
            if (ok) *p = static_cast<float>(v);
            lua.set_bool(ok);
            return 1;
        }
    } // namespace

    void rates_init()
    {
        g_humanClass = RC::Unreal::UObjectGlobals::StaticFindObject<RC::Unreal::UClass*>(nullptr, nullptr, STR("/Script/Mist.MistHuman"));
        g_playerClass = RC::Unreal::UObjectGlobals::StaticFindObject<RC::Unreal::UClass*>(nullptr, nullptr, STR("/Script/Mist.MistPlayer"));
        bool skills = resolveDirect(g_getSkill) && resolveDirect(g_setSkill) && resolveDirect(g_updateStats) &&
                      resolveDirect(g_lookAt) && g_humanClass && g_playerClass;
        g_expReady = resolveDirect(g_setExpToNext) && resolveDirect(g_progression) && resolveDirect(g_loadCurve) &&
                     resolveDirect(g_curveValue) && prologueOk(0x06B32302, kCurveFieldRead);
        log(!skills ? L"skill calls NOT ready"
                    : g_expReady ? L"skill calls ready" : L"skill calls ready (without XP to next level)");
        if (!resolveGlobals())
        {
            log(L"game multipliers not found (game updated?); rates off");
            return;
        }
        g_speed = findGlobal("craft_speed");
        g_cost = findGlobal("craft_cost");
        g_ready = installHooks();
        log(g_ready ? L"rates ready (XP, crafting speed and cost per player)" : L"rates NOT ready");
    }

    void rates_shutdown()
    {
        for (auto& h : g_hooks)
            if (h.Detour) h.Detour->unHook();
        g_hooks.clear();
        g_ready = false;
    }

    void rates_register(const RC::LuaMadeSimple::Lua& lua)
    {
        lua.register_function("BWNative_RatesReady", lua_ready);
        lua.register_function("BWNative_ClearPlayerRates", lua_clear);
        lua.register_function("BWNative_SetPlayerRates", lua_set);
        lua.register_function("BWNative_GetGlobal", lua_getGlobal);
        lua.register_function("BWNative_SetGlobal", lua_setGlobal);
        lua.register_function("BWNative_SetInstantRead", lua_setInstantRead);
        lua.register_function("BWNative_SetPlayerInstantRead", lua_setPlayerRead);
        lua.register_function("BWNative_LookAtActor", lua_lookAt);
        lua.register_function("BWNative_GetSkill", lua_getSkill);
        lua.register_function("BWNative_SetSkill", lua_setSkill);
    }
} // namespace bwcoop
