// Shared declarations for the BWCoopNative source files.
#pragma once

#include <cstdint>
#include <string>

#include <LuaMadeSimple/LuaMadeSimple.hpp>

namespace RC::Unreal
{
    class UObject;
}

namespace bwcoop
{
    // dllmain.cpp
    void log(const std::wstring& msg);
    // Lua argument helpers: each consumes the value at the bottom of the argument stack. Objects
    // arrive as addresses (obj:GetAddress()) and must be live objects in the global object array.
    RC::Unreal::UObject* takeObject(const RC::LuaMadeSimple::Lua& lua);
    double takeNumber(const RC::LuaMadeSimple::Lua& lua);
    bool takeBool(const RC::LuaMadeSimple::Lua& lua);
    std::string takeString(const RC::LuaMadeSimple::Lua& lua);
    // True when the 16 bytes at module base + rva match (the game build this was made for).
    bool prologueOk(uintptr_t rva, const uint8_t (&prologue)[16]);

    // rates.cpp: per-player XP, crafting speed/cost and the game's global multipliers.
    void rates_init();
    void rates_shutdown();
    void rates_register(const RC::LuaMadeSimple::Lua& lua);

    // sleep.cpp: the night skip rule (how many players must be in bed).
    void sleep_init();
    void sleep_shutdown();
    void sleep_register(const RC::LuaMadeSimple::Lua& lua);

    // gui.cpp: the "BWCoop" tab in the UE4SS window (Ctrl+O), a remote control for the Lua mod.
    void gui_register(const RC::LuaMadeSimple::Lua& lua);
    void gui_render();
} // namespace bwcoop
