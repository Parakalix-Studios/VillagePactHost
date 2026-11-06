// Night skip rule (0.4.0): how many players must be in bed before the night is skipped.
//
// Lying down in a bed (or a paid tavern bed, which goes through the same code) runs
// UMistPlayerBedComponent::Interact on the host: it compares NumberPlayersSleep() with
// TotalNumberPlayers() and skips the night when sleepers >= total, else shows the "waiting for
// others" screen. CancelSleep uses the same pair for that screen. TotalNumberPlayers is detoured to
// return how many sleepers the host's rule needs instead:
//   all   every player (the game's own rule)
//   half  half of the players, rounded up
//   one   any one player
//   host  the host alone is enough (otherwise everyone, as in the game)
// Players who stay up see the night pass like the sleepers do.
//
// Addresses from the shipped PDB, Bellwright build 24840601, all byte-checked:
//   UMistPlayerBedComponent::TotalNumberPlayers  0x067A23E0  (detoured)
//   UMistPlayerBedComponent::NumberPlayersSleep  0x0679E4B0  (called)
//   UActorComponent::GetGameState                0x03A97980  (called)
// and the fields the two counters read: GameState PlayerArray (+0x2D8 data, +0x2E0 count),
// PlayerState pawn (+0x338), pawn controller (+0x2F0), AMistPlayer::BedComponent (+0x1130).
// 0.4.2: the log line names who is in bed and who is up, with the game's own player test
// (AMistPlayer::GetPrivateStaticClass 0x06259530, FObjectPtr::IsA 0x01537840, as NumberPlayersSleep
// calls them) and the name APlayerState::GetPlayerName reads (PlayerNamePrivate: +0x358 data, +0x360 count).
//
// Lua functions:
//   BWNative_SleepReady() -> bool
//   BWNative_SetSleepRule(rule, hostPawnAddress) -> bool    rule: all, half, one, host

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <Windows.h>

#include <algorithm>
#include <atomic>
#include <format>
#include <memory>
#include <string>

#include <polyhook2/Detour/x64Detour.hpp>

#include "bwcoop.hpp"

namespace bwcoop
{
    namespace
    {
        enum class Rule : int
        {
            All,
            Half,
            One,
            Host
        };
        const char* kRuleNames[] = {"all", "half", "one", "host"};
        const wchar_t* kRuleNamesW[] = {L"all", L"half", L"one", L"host"};

        std::atomic<int> g_rule{static_cast<int>(Rule::All)};
        std::atomic<void*> g_hostPawn{nullptr};
        bool g_ready = false;

        constexpr uintptr_t kTotalRva = 0x067A23E0;
        constexpr uintptr_t kSleepersRva = 0x0679E4B0;
        constexpr uintptr_t kGameStateRva = 0x03A97980;
        constexpr uintptr_t kPlayerClassRva = 0x06259530;
        constexpr uintptr_t kIsARva = 0x01537840;
        constexpr uintptr_t kNameReadRva = 0x040D3C9B; // inside APlayerState::GetPlayerName
        const uint8_t kTotalPrologue[16] = {0x48, 0x89, 0x5C, 0x24, 0x10, 0x48, 0x89, 0x6C, 0x24, 0x18, 0x56, 0x48, 0x83, 0xEC, 0x20, 0x33};
        const uint8_t kSleepersPrologue[16] = {0x48, 0x89, 0x5C, 0x24, 0x10, 0x48, 0x89, 0x6C, 0x24, 0x18, 0x56, 0x48, 0x83, 0xEC, 0x20, 0x33};
        const uint8_t kGameStatePrologue[16] = {0x48, 0x83, 0xEC, 0x28, 0xE8, 0x37, 0x7A, 0x0F, 0xFF, 0x48, 0x85, 0xC0, 0x74, 0x0C, 0x48, 0x8B};
        const uint8_t kPlayerClassPrologue[16] = {0x4C, 0x8B, 0xDC, 0x48, 0x83, 0xEC, 0x78, 0x48, 0x8B, 0x05, 0xEA, 0xC1, 0xF2, 0x05, 0x48, 0x85};
        const uint8_t kIsAPrologue[16] = {0x48, 0x8B, 0x01, 0x48, 0x85, 0xC0, 0x74, 0x28, 0x48, 0x8B, 0x40, 0x10, 0x48, 0x85, 0xC0, 0x74};
        // The field reads inside the game's counters, so the offsets used below are the game's own:
        //   mov rbx,[rax+2D8h] / movsxd rax,[rax+2E0h]     cmp [rdi+338h],0
        //   cmp [rcx+2F0h],0                                cmp [rcx+1130h],0
        const uint8_t kArrayRead[16] = {0x48, 0x8B, 0x98, 0xD8, 0x02, 0x00, 0x00, 0x48, 0x63, 0x80, 0xE0, 0x02, 0x00, 0x00, 0x48, 0x8D};
        const uint8_t kPawnRead[16] = {0x48, 0x83, 0xBF, 0x38, 0x03, 0x00, 0x00, 0x00, 0x74, 0x30, 0xE8, 0x0C, 0x71, 0xAB, 0xFF, 0x48};
        const uint8_t kControllerRead[16] = {0x48, 0x83, 0xB9, 0xF0, 0x02, 0x00, 0x00, 0x00, 0x74, 0x02, 0xFF, 0xC6, 0x48, 0x83, 0xC3, 0x08};
        const uint8_t kBedRead[16] = {0x48, 0x83, 0xB9, 0x30, 0x11, 0x00, 0x00, 0x00, 0x74, 0x02, 0xFF, 0xC6, 0x48, 0x83, 0xC3, 0x08};
        // NumberPlayersSleep: call AMistPlayer::GetPrivateStaticClass / mov rdx,rax / lea rcx,[rdi+338h] /
        // call FObjectPtr::IsA. GetPlayerName: mov rsi,[rcx+358h] ... movsxd rdi,[rcx+360h].
        const uint8_t kPlayerClassCall[16] = {0xE8, 0x3C, 0xB0, 0xAB, 0xFF, 0x48, 0x8B, 0xD0, 0x48, 0x8D, 0x8F, 0x38, 0x03, 0x00, 0x00, 0xE8};
        const uint8_t kIsACall[16] = {0xE8, 0x3D, 0x93, 0xD9, 0xFA, 0x84, 0xC0, 0x74, 0x22, 0x48, 0x8B, 0x8F, 0x38, 0x03, 0x00, 0x00};
        const uint8_t kNameRead[16] = {0x48, 0x8B, 0xB1, 0x58, 0x03, 0x00, 0x00, 0x48, 0x89, 0xBC, 0x24, 0x80, 0x00, 0x00, 0x00, 0x48};
        const uint8_t kNameCountRead[16] = {0x48, 0x63, 0xB9, 0x60, 0x03, 0x00, 0x00, 0x48, 0x89, 0x44, 0x24, 0x40, 0x89, 0x7C, 0x24, 0x48};

        using CountFn = int32_t (*)(const void*);
        using GameStateFn = void* (*)(const void*);
        using ClassFn = void* (*)();
        using IsAFn = bool (*)(const void* objectPtr, const void* cls);

        uint64_t t_total = 0;
        CountFn g_sleepers = nullptr;
        GameStateFn g_gameState = nullptr;
        ClassFn g_playerClass = nullptr;
        IsAFn g_isA = nullptr;
        std::unique_ptr<PLH::x64Detour> g_detour;

        template <typename T> auto field(const void* base, uintptr_t offset) -> T
        {
            return *reinterpret_cast<T const*>(reinterpret_cast<const uint8_t*>(base) + offset);
        }

        // Is the host's pawn in bed? Only a pawn found in the live player list is read.
        auto hostInBed(const void* bed) -> bool
        {
            void* host = g_hostPawn.load();
            void* gs = host ? g_gameState(bed) : nullptr;
            if (!gs) return false;
            auto* states = field<void* const*>(gs, 0x2D8);
            int32_t n = field<int32_t>(gs, 0x2E0);
            for (int32_t i = 0; states && i < n; ++i)
            {
                void* ps = states[i];
                if (ps && field<void*>(ps, 0x338) == host) return field<void*>(host, 0x1130) != nullptr;
            }
            return false;
        }

        // A player's name as APlayerState::GetPlayerName reads it (an FString: data, then count with the zero).
        auto playerName(const void* ps) -> std::wstring
        {
            auto* data = field<const wchar_t*>(ps, 0x358);
            int32_t num = field<int32_t>(ps, 0x360);
            if (!data || num < 2 || num > 128) return L"?";
            return std::wstring(data, static_cast<size_t>(num - 1));
        }

        // Who is in bed and who is up, by the game's own test (a player pawn with a controller; in bed when
        // its BedComponent is set), for the log line.
        auto bedNames(const void* bed, std::wstring& asleep, std::wstring& awake) -> void
        {
            void* gs = g_gameState(bed);
            if (!gs) return;
            auto* states = field<void* const*>(gs, 0x2D8);
            int32_t n = field<int32_t>(gs, 0x2E0);
            void* playerClass = g_playerClass();
            for (int32_t i = 0; states && i < n; ++i)
            {
                const uint8_t* ps = static_cast<const uint8_t*>(states[i]);
                if (!ps || !field<void*>(ps, 0x338) || !g_isA(ps + 0x338, playerClass)) continue;
                void* pawn = field<void*>(ps, 0x338);
                if (!field<void*>(pawn, 0x2F0)) continue;
                std::wstring& list = field<void*>(pawn, 0x1130) ? asleep : awake;
                if (!list.empty()) list += L", ";
                list += playerName(ps);
            }
        }

        int32_t hk_total(const void* bed)
        {
            int32_t total = reinterpret_cast<CountFn>(t_total)(bed);
            auto rule = static_cast<Rule>(g_rule.load());
            if (rule == Rule::All || total <= 1) return total;
            int32_t sleepers = g_sleepers(bed);
            int32_t need = total;
            if (rule == Rule::Half) need = (total + 1) / 2;
            if (rule == Rule::One) need = 1;
            if (rule == Rule::Host && hostInBed(bed)) need = std::max(1, sleepers);
            need = std::clamp(need, 1, total);
            if (sleepers >= need && sleepers < total)
            {
                std::wstring asleep, awake;
                bedNames(bed, asleep, awake);
                log(std::format(L"night skip: {} of {} players in bed (rule {}). In bed: {}. Up: {}", sleepers, total,
                                kRuleNamesW[static_cast<int>(rule)], asleep.empty() ? L"?" : asleep,
                                awake.empty() ? L"nobody" : awake));
            }
            return need;
        }

        auto lua_ready(const RC::LuaMadeSimple::Lua& lua) -> int
        {
            lua.set_bool(g_ready);
            return 1;
        }

        // The pawn arrives as a plain address: it is never dereferenced unless it is found in the
        // game's live player list (hostInBed), so a stale one is harmless.
        auto lua_setRule(const RC::LuaMadeSimple::Lua& lua) -> int
        {
            std::string name = takeString(lua);
            auto host = static_cast<uintptr_t>(takeNumber(lua));
            int rule = -1;
            for (int i = 0; i < 4; ++i)
                if (name == kRuleNames[i]) rule = i;
            if (rule >= 0)
            {
                g_rule.store(rule);
                g_hostPawn.store(reinterpret_cast<void*>(host));
            }
            lua.set_bool(g_ready && rule >= 0);
            return 1;
        }
    } // namespace

    void sleep_init()
    {
        bool ok = prologueOk(kTotalRva, kTotalPrologue) && prologueOk(kSleepersRva, kSleepersPrologue) &&
                  prologueOk(kGameStateRva, kGameStatePrologue) && prologueOk(kTotalRva + 0x16, kArrayRead) &&
                  prologueOk(kTotalRva + 0x35, kPawnRead) && prologueOk(kTotalRva + 0x63, kControllerRead) &&
                  prologueOk(kSleepersRva + 0x6D, kBedRead) && prologueOk(kPlayerClassRva, kPlayerClassPrologue) &&
                  prologueOk(kIsARva, kIsAPrologue) && prologueOk(kSleepersRva + 0x3F, kPlayerClassCall) &&
                  prologueOk(kSleepersRva + 0x4E, kIsACall) &&
                  prologueOk(kNameReadRva, kNameRead) && prologueOk(kNameReadRva + 0x0F, kNameCountRead);
        if (!ok)
        {
            log(L"night skip: game code not as expected (game updated?); night skip rule off");
            return;
        }
        auto base = reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr));
        g_sleepers = reinterpret_cast<CountFn>(base + kSleepersRva);
        g_gameState = reinterpret_cast<GameStateFn>(base + kGameStateRva);
        g_playerClass = reinterpret_cast<ClassFn>(base + kPlayerClassRva);
        g_isA = reinterpret_cast<IsAFn>(base + kIsARva);
        g_detour = std::make_unique<PLH::x64Detour>(reinterpret_cast<uint64_t>(base + kTotalRva),
                                                    reinterpret_cast<uint64_t>(&hk_total), &t_total);
        g_ready = g_detour->hook();
        log(g_ready ? L"night skip ready" : L"night skip: could not hook TotalNumberPlayers; rule off");
    }

    void sleep_shutdown()
    {
        if (g_detour) g_detour->unHook();
        g_detour.reset();
        g_ready = false;
    }

    void sleep_register(const RC::LuaMadeSimple::Lua& lua)
    {
        lua.register_function("BWNative_SleepReady", lua_ready);
        lua.register_function("BWNative_SetSleepRule", lua_setRule);
    }
} // namespace bwcoop
