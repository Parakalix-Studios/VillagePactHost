// The "BWCoop" tab in the UE4SS window (Ctrl+O on the host PC; friends see nothing).
//
// The window runs on its own thread, where touching the game is unsafe, so it is only a remote
// control: the Lua mod pushes a text snapshot of its state (BWNative_GuiSetState) and polls the
// commands the window queues (BWNative_GuiTakeCommand), running them on the game thread exactly like
// console "bwcoop ..." commands. Results come back as log lines (BWNative_GuiLog).
//
// State lines (tab separated):
//   VER <version> <save>
//   SET <name> <value>                     mode, tags, cheats, auto, limit, sleep
//   PLR <name> <host 0|1> <village> <xp> <craftSpeed> <craftCost> <buildCost> <instantBooks 0|1>
//   VIL <label> <owner> <GUID prefix> [<trusted player>...]
//
// Layout (0.4.0): a status line, tabs (Players, Give, Villager, World, Villages, Settings) and the log
// underneath, so every tab shows what its commands answered.

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <Windows.h>

#include <algorithm>
#include <cstdio>
#include <deque>
#include <format>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

#include <imgui.h>

#include "bwcoop.hpp"

namespace bwcoop
{
    namespace
    {
        std::mutex g_mx;
        std::string g_state;
        ULONGLONG g_stateTick = 0;
        std::deque<std::string> g_commands;
        std::deque<std::string> g_log;

        void queue(std::string cmd)
        {
            std::lock_guard lock(g_mx);
            g_commands.push_back(std::move(cmd));
        }

        auto split(const std::string& line, char sep) -> std::vector<std::string>
        {
            std::vector<std::string> out;
            std::string cur;
            for (char c : line)
            {
                if (c == sep)
                {
                    out.push_back(cur);
                    cur.clear();
                }
                else
                    cur += c;
            }
            out.push_back(cur);
            return out;
        }

        struct Player
        {
            std::string Name, Village;
            bool Host = false;
            float Xp = 1, Speed = 1, Cost = 1, Build = 1;
            bool Read = false;
        };
        struct Village
        {
            std::string Label, Owner, Key;
            std::vector<std::string> Trusted;
        };
        struct State
        {
            std::string Version, Save, Mode = "?", Tags, Cheats, Auto, Sleep = "all";
            int Limit = 1;
            std::vector<Player> Players;
            std::vector<Village> Villages;
        };

        auto parse(const std::string& text) -> State
        {
            State s;
            std::istringstream in(text);
            std::string line;
            while (std::getline(in, line))
            {
                auto f = split(line, '\t');
                if (f[0] == "VER" && f.size() >= 3)
                {
                    s.Version = f[1];
                    s.Save = f[2];
                }
                else if (f[0] == "SET" && f.size() >= 3)
                {
                    if (f[1] == "mode") s.Mode = f[2];
                    if (f[1] == "tags") s.Tags = f[2];
                    if (f[1] == "cheats") s.Cheats = f[2];
                    if (f[1] == "auto") s.Auto = f[2];
                    if (f[1] == "limit") s.Limit = std::atoi(f[2].c_str());
                    if (f[1] == "sleep") s.Sleep = f[2];
                }
                else if (f[0] == "PLR" && f.size() >= 8)
                {
                    Player p;
                    p.Name = f[1];
                    p.Host = f[2] == "1";
                    p.Village = f[3];
                    p.Xp = static_cast<float>(std::atof(f[4].c_str()));
                    p.Speed = static_cast<float>(std::atof(f[5].c_str()));
                    p.Cost = static_cast<float>(std::atof(f[6].c_str()));
                    p.Build = static_cast<float>(std::atof(f[7].c_str()));
                    p.Read = f.size() >= 9 && f[8] == "1";
                    s.Players.push_back(p);
                }
                else if (f[0] == "VIL" && f.size() >= 3)
                {
                    Village v{f[1], f[2], f.size() >= 4 ? f[3] : f[1], {}};
                    for (size_t i = 4; i < f.size(); ++i) v.Trusted.push_back(f[i]);
                    s.Villages.push_back(v);
                }
            }
            return s;
        }

        // A player's rate edits. While not dirty they follow the game's state (changes made from the
        // console show up too); once touched they wait for Apply.
        struct Edit
        {
            std::string Name;
            float Xp = 1, Speed = 1;
            bool FreeCraft = false, FreeBuild = false, InstantRead = false;
            bool Dirty = false;
        };
        std::vector<Edit> g_edits;

        auto editFor(const Player& p) -> Edit&
        {
            for (auto& e : g_edits)
                if (e.Name == p.Name) return e;
            g_edits.push_back(Edit{p.Name});
            return g_edits.back();
        }

        // Skill ids as the commands take them, and how the window shows them.
        const char* kSkills[] = {"Strength", "Agility", "OneHanded", "TwoHanded", "Polearms", "Shields", "Archery",
                                 "Harvesting", "Farming", "AnimalHandling", "Cooking", "Crafting", "Researching", "Labourer"};
        const char* kSkillLabels[] = {"Strength", "Agility", "One-handed", "Two-handed", "Polearms", "Shields", "Archery",
                                      "Harvesting", "Farming", "Animal handling", "Cooking", "Crafting", "Researching", "Laborer"};
        const char* kModes[] = {"enforce", "warn", "dryrun", "off"};
        const char* kModeLabels[] = {"Block (enforce)", "Warn only", "Log only (dry run)", "Off"};
        const char* kSleepRules[] = {"all", "half", "one", "host"};
        const char* kSleepLabels[] = {"Everyone in bed (the game's rule)", "Half of the players in bed", "Any one player in bed",
                                      "The host in bed is enough"};
        const char* kTrees[] = {"warrior", "rogue", "explorer"};
        const char* kTreeLabels[] = {"Warrior", "Rogue", "Explorer"};

        // The admin commands match a player by the start of their name; "me" is the host.
        auto who(const Player& p) -> std::string
        {
            if (p.Host) return "me";
            auto sp = p.Name.find(' ');
            return sp == std::string::npos ? p.Name : p.Name.substr(0, sp);
        }

        constexpr float kLabelW = 150.0f; // label column in the form-style tabs
        constexpr float kTextW = 260.0f;  // text inputs
        constexpr float kNumW = 110.0f;   // number inputs

        // Widths above are for UE4SS's normal 14 px font; scale them with GuiConsoleFontScaling.
        auto px(float v) -> float { return v * ImGui::GetFontSize() / 14.0f; }

        // A form row: label on the left, widgets after it.
        void label(const char* text)
        {
            ImGui::AlignTextToFramePadding();
            ImGui::TextUnformatted(text);
            ImGui::SameLine(px(kLabelW));
        }

        void textLine(const std::string& s) { ImGui::TextUnformatted(s.c_str()); }

        auto combo(const char* id, int& current, const char* const items[], int count, float width) -> bool
        {
            ImGui::SetNextItemWidth(width);
            return ImGui::Combo(id, &current, items, count);
        }

        auto numberInput(const char* id, int& v, int minimum) -> void
        {
            ImGui::SetNextItemWidth(px(kNumW));
            ImGui::InputInt(id, &v, 1, 10);
            v = std::max(minimum, v);
        }

        int g_target = 0;
        char g_item[96] = "Wood";
        int g_itemCount = 10;
        int g_money = 100, g_renown = 10, g_perk = 1, g_tree = 0;
        int g_skillP = 0, g_xpP = 100, g_levelP = 5;
        int g_skillV = 0, g_xpV = 100, g_levelV = 5;
        float g_happy = 1.0f;
        char g_npc[96] = "";
        int g_npcCount = 1;
        char g_animal[96] = "";
        bool g_animalMale = false;
        char g_actor[128] = "";
        int g_actorDistance = 400;
        int g_hours = 1;
        char g_weather[64] = "";
        int g_immigrants = 1;
        int g_limit = 1;
        bool g_limitActive = false;

        void playersTab(const State& s)
        {
            ImGui::TextWrapped("Rates apply to that player only. XP multiplies every skill gain; craft speed 1000 is instant. "
                               "Drag a value or double-click it to type, then Apply.");
            ImGui::Spacing();
            const ImGuiTableFlags flags = ImGuiTableFlags_RowBg | ImGuiTableFlags_BordersInnerH | ImGuiTableFlags_BordersOuter |
                                          ImGuiTableFlags_SizingFixedFit | ImGuiTableFlags_PadOuterX;
            if (!ImGui::BeginTable("players", 8, flags)) return;
            ImGui::TableSetupColumn("Player", ImGuiTableColumnFlags_WidthStretch);
            ImGui::TableSetupColumn("Village", ImGuiTableColumnFlags_WidthStretch);
            ImGui::TableSetupColumn("XP", ImGuiTableColumnFlags_WidthFixed, px(80));
            ImGui::TableSetupColumn("Craft speed", ImGuiTableColumnFlags_WidthFixed, px(90));
            ImGui::TableSetupColumn("Free crafting");
            ImGui::TableSetupColumn("Free building");
            ImGui::TableSetupColumn("Instant books");
            ImGui::TableSetupColumn("", ImGuiTableColumnFlags_WidthFixed, px(120));
            ImGui::TableHeadersRow();
            for (auto& p : s.Players)
            {
                auto& e = editFor(p);
                if (!e.Dirty)
                {
                    e.Xp = p.Xp;
                    e.Speed = p.Speed;
                    e.FreeCraft = p.Cost == 0.0f;
                    e.FreeBuild = p.Build == 0.0f;
                    e.InstantRead = p.Read;
                }
                bool boosted = p.Xp != 1.0f || p.Speed != 1.0f || p.Cost != 1.0f || p.Build != 1.0f || p.Read;
                ImGui::PushID(p.Name.c_str());
                ImGui::TableNextRow();
                ImGui::TableNextColumn();
                ImGui::AlignTextToFramePadding();
                textLine(p.Name);
                if (p.Host)
                {
                    ImGui::SameLine();
                    ImGui::TextDisabled("(host)");
                }
                if (boosted)
                {
                    ImGui::SameLine();
                    ImGui::TextColored(ImVec4(0.95f, 0.75f, 0.30f, 1.0f), "*");
                    ImGui::SetItemTooltip("This player has rates other than normal.");
                }
                ImGui::TableNextColumn();
                ImGui::AlignTextToFramePadding();
                if (p.Village.empty())
                    ImGui::TextDisabled("none yet");
                else
                    textLine(p.Village);
                ImGui::TableNextColumn();
                ImGui::SetNextItemWidth(-FLT_MIN);
                e.Dirty |= ImGui::DragFloat("##xp", &e.Xp, 0.05f, 0.0f, 100.0f, "x%.2f", ImGuiSliderFlags_AlwaysClamp);
                ImGui::SetItemTooltip("XP multiplier: 0 = no XP, 1 = normal, 2 = double.");
                ImGui::TableNextColumn();
                ImGui::SetNextItemWidth(-FLT_MIN);
                e.Dirty |= ImGui::DragFloat("##speed", &e.Speed, 1.0f, 0.01f, 1000.0f, "x%.1f",
                                            ImGuiSliderFlags_AlwaysClamp | ImGuiSliderFlags_Logarithmic);
                ImGui::SetItemTooltip("Crafting speed: 1 = normal, 1000 = instant.");
                ImGui::TableNextColumn();
                e.Dirty |= ImGui::Checkbox("##fc", &e.FreeCraft);
                ImGui::SetItemTooltip("Crafting uses no materials for this player.");
                ImGui::TableNextColumn();
                e.Dirty |= ImGui::Checkbox("##fb", &e.FreeBuild);
                ImGui::SetItemTooltip("Building costs nothing for this player.");
                ImGui::TableNextColumn();
                e.Dirty |= ImGui::Checkbox("##ib", &e.InstantRead);
                ImGui::SetItemTooltip("Skill books take 1 second to read for this player.");
                ImGui::TableNextColumn();
                ImGui::BeginDisabled(!e.Dirty);
                if (ImGui::Button("Apply"))
                {
                    // Keep a cost the console set (e.g. 0.5) unless the checkbox changed it.
                    float cost = e.FreeCraft ? 0.0f : (p.Cost == 0.0f ? 1.0f : p.Cost);
                    float build = e.FreeBuild ? 0.0f : (p.Build == 0.0f ? 1.0f : p.Build);
                    queue(std::format("rates {} xp={:.3f} speed={:.3f} cost={:g} build={:g} read={}", p.Name, e.Xp,
                                      std::max(0.01f, e.Speed), cost, build, e.InstantRead ? 1 : 0));
                    e.Dirty = false;
                }
                ImGui::EndDisabled();
                ImGui::SameLine();
                ImGui::BeginDisabled(!boosted && !e.Dirty);
                if (ImGui::Button("Normal"))
                {
                    queue(std::format("rates {} xp=1 speed=1 cost=1 build=1 read=0", p.Name));
                    e.Dirty = false;
                }
                ImGui::EndDisabled();
                ImGui::SetItemTooltip("Back to normal rates.");
                ImGui::PopID();
            }
            ImGui::EndTable();
        }

        void giveTab(const State& s)
        {
            if (s.Players.empty())
            {
                ImGui::TextDisabled("No players online.");
                return;
            }
            std::vector<std::string> names;
            for (auto& p : s.Players) names.push_back(p.Name + (p.Host ? " (host)" : ""));
            std::vector<const char*> items;
            for (auto& n : names) items.push_back(n.c_str());
            if (g_target >= static_cast<int>(items.size())) g_target = 0;
            label("Player");
            combo("##target", g_target, items.data(), static_cast<int>(items.size()), px(kTextW));
            const Player& t = s.Players[g_target];

            ImGui::SeparatorText("Items");
            label("Item");
            ImGui::SetNextItemWidth(px(kTextW));
            ImGui::InputTextWithHint("##item", "name as shown, or asset name", g_item, sizeof(g_item));
            ImGui::SetItemTooltip("Either the name shown in game (Piece of Smoked Meat) or the asset name "
                                  "(SmokedPieceMeat). Search lists matches in the log.");
            ImGui::SameLine();
            numberInput("##count", g_itemCount, 1);
            ImGui::SameLine();
            ImGui::BeginDisabled(g_item[0] == 0);
            if (ImGui::Button("Give")) queue(std::format("give {} {} {}", who(t), g_item, g_itemCount));
            ImGui::SameLine();
            if (ImGui::Button("Search")) queue(std::format("items {}", g_item));
            ImGui::EndDisabled();

            ImGui::SeparatorText("Skills");
            label("Skill");
            combo("##skillP", g_skillP, kSkillLabels, 14, px(kTextW));
            ImGui::SameLine();
            if (ImGui::Button("+1 level##P")) queue(std::format("levelup {} {}", who(t), kSkills[g_skillP]));
            ImGui::SameLine();
            if (ImGui::Button("-1 level##P")) queue(std::format("leveldown {} {}", who(t), kSkills[g_skillP]));
            label("Add XP");
            numberInput("##xpP", g_xpP, 1);
            ImGui::SameLine();
            if (ImGui::Button("Add##xpP")) queue(std::format("xp {} {} {}", who(t), kSkills[g_skillP], g_xpP));
            label("Set level");
            numberInput("##lvlP", g_levelP, 0);
            ImGui::SameLine();
            if (ImGui::Button("Set##lvlP")) queue(std::format("skill {} {} {}", who(t), kSkills[g_skillP], g_levelP));

            ImGui::SeparatorText("Perk points");
            label("Tree");
            combo("##tree", g_tree, kTreeLabels, 3, px(kTextW));
            ImGui::SameLine();
            numberInput("##perk", g_perk, 1);
            ImGui::SameLine();
            if (ImGui::Button("Give##perk")) queue(std::format("perk {} {} {}", who(t), kTrees[g_tree], g_perk));

            ImGui::SeparatorText("Shared by everyone");
            ImGui::TextDisabled("Money and renown belong to the whole world, so every player sees the change.");
            label("Money");
            numberInput("##money", g_money, 1);
            ImGui::SameLine();
            if (ImGui::Button("Add##money")) queue(std::format("money {}", g_money));
            label("Renown");
            numberInput("##renown", g_renown, 1);
            ImGui::SameLine();
            if (ImGui::Button("Add##renown")) queue(std::format("renown {}", g_renown));
        }

        void villagerTab()
        {
            ImGui::TextWrapped("Look at a villager in the game (center of the screen, within about 5 m), then use these.");
            ImGui::Spacing();
            label("Skill");
            combo("##skillV", g_skillV, kSkillLabels, 14, px(kTextW));
            ImGui::SameLine();
            if (ImGui::Button("+1 level##V")) queue(std::format("levelup look {}", kSkills[g_skillV]));
            ImGui::SameLine();
            if (ImGui::Button("-1 level##V")) queue(std::format("leveldown look {}", kSkills[g_skillV]));
            label("Add XP");
            numberInput("##xpV", g_xpV, 1);
            ImGui::SameLine();
            if (ImGui::Button("Add##xpV")) queue(std::format("vxp {} {}", kSkills[g_skillV], g_xpV));
            label("Set level");
            numberInput("##lvlV", g_levelV, 0);
            ImGui::SameLine();
            if (ImGui::Button("Set##lvlV")) queue(std::format("vskill {} {}", kSkills[g_skillV], g_levelV));
            ImGui::SeparatorText("Happiness");
            label("Happiness");
            ImGui::SetNextItemWidth(px(kNumW));
            ImGui::InputFloat("##happy", &g_happy, 0.1f, 0.5f, "%.2f");
            ImGui::SameLine();
            if (ImGui::Button("Set##happy")) queue(std::format("vhappy {:.2f}", g_happy));
            ImGui::SameLine();
            if (ImGui::Button("Back to normal")) queue("vhappy off");
        }

        void worldTab()
        {
            ImGui::SeparatorText("Spawn in front of you");
            label("NPC");
            ImGui::SetNextItemWidth(px(kTextW));
            ImGui::InputTextWithHint("##npc", "template, e.g. T1_Brigands_Melee_NpcTemplate", g_npc, sizeof(g_npc));
            ImGui::SameLine();
            numberInput("##npcn", g_npcCount, 1);
            ImGui::SameLine();
            ImGui::BeginDisabled(g_npc[0] == 0);
            if (ImGui::Button("Spawn##npc")) queue(std::format("spawnnpc {} {}", g_npc, g_npcCount));
            ImGui::EndDisabled();
            label("Creature");
            ImGui::SetNextItemWidth(px(kTextW));
            ImGui::InputTextWithHint("##actor", "e.g. Deer, Boar, Fox", g_actor, sizeof(g_actor));
            ImGui::SameLine();
            numberInput("##dist", g_actorDistance, 100);
            ImGui::SetItemTooltip("Distance in front of you, in cm.");
            ImGui::SameLine();
            ImGui::BeginDisabled(g_actor[0] == 0);
            if (ImGui::Button("Spawn##actor")) queue(std::format("spawn {} {}", g_actor, g_actorDistance));
            ImGui::EndDisabled();
            label("Farm animal");
            ImGui::SetNextItemWidth(px(kTextW));
            ImGui::InputTextWithHint("##animal", "template (needs a pen with space)", g_animal, sizeof(g_animal));
            ImGui::SameLine();
            ImGui::Checkbox("Male", &g_animalMale);
            ImGui::SameLine();
            ImGui::BeginDisabled(g_animal[0] == 0);
            if (ImGui::Button("Spawn##animal")) queue(std::format("animal {} {}", g_animal, g_animalMale ? "male" : "female"));
            ImGui::EndDisabled();

            ImGui::SeparatorText("Time and weather");
            label("Advance time");
            numberInput("##hours", g_hours, 1);
            ImGui::SameLine();
            if (ImGui::Button("Advance")) queue(std::format("time {}", g_hours));
            ImGui::SameLine();
            ImGui::TextDisabled("hours");
            label("Weather");
            ImGui::SetNextItemWidth(px(kTextW));
            ImGui::InputTextWithHint("##weather", "weather name", g_weather, sizeof(g_weather));
            ImGui::SameLine();
            ImGui::BeginDisabled(g_weather[0] == 0);
            if (ImGui::Button("Set##weather")) queue(std::format("weather {}", g_weather));
            ImGui::EndDisabled();

            ImGui::SeparatorText("Villagers");
            label("Immigrants");
            numberInput("##imm", g_immigrants, 1);
            ImGui::SameLine();
            if (ImGui::Button("Hire")) queue(std::format("immigrants {}", g_immigrants));
        }

        void villagesTab(const State& s)
        {
            ImGui::TextWrapped("Owner: who the village belongs to. Trusted: friends who may build and change things there like "
                               "the owner (squads stay with their owners). The host can always change everything.");
            ImGui::Spacing();
            if (s.Villages.empty())
            {
                ImGui::TextDisabled("No player villages yet.");
                return;
            }
            std::vector<std::string> owners = {"(nobody: open to all)"};
            for (auto& p : s.Players) owners.push_back(p.Name);
            const ImGuiTableFlags flags = ImGuiTableFlags_RowBg | ImGuiTableFlags_BordersInnerH | ImGuiTableFlags_BordersOuter |
                                          ImGuiTableFlags_SizingFixedFit | ImGuiTableFlags_PadOuterX;
            if (!ImGui::BeginTable("villages", 3, flags)) return;
            ImGui::TableSetupColumn("Village", ImGuiTableColumnFlags_WidthFixed, px(180));
            ImGui::TableSetupColumn("Owner", ImGuiTableColumnFlags_WidthFixed, px(230));
            ImGui::TableSetupColumn("Trusted friends", ImGuiTableColumnFlags_WidthStretch);
            ImGui::TableHeadersRow();
            for (auto& v : s.Villages)
            {
                ImGui::PushID(v.Key.c_str());
                ImGui::TableNextRow();
                ImGui::TableNextColumn();
                ImGui::AlignTextToFramePadding();
                textLine(v.Label);
                ImGui::TableNextColumn();
                int current = 0;
                for (size_t i = 1; i < owners.size(); ++i)
                    if (owners[i] == v.Owner) current = static_cast<int>(i);
                // An owner who is offline isn't in the list: show their name anyway.
                std::string preview = current == 0 && !v.Owner.empty() ? v.Owner : owners[current];
                ImGui::SetNextItemWidth(-FLT_MIN);
                if (ImGui::BeginCombo("##owner", preview.c_str()))
                {
                    for (size_t i = 0; i < owners.size(); ++i)
                    {
                        if (ImGui::Selectable(owners[i].c_str(), static_cast<int>(i) == current) && static_cast<int>(i) != current)
                        {
                            if (i == 0)
                                queue("unassign " + v.Key);
                            else
                                queue("assign " + v.Key + " = " + owners[i]);
                        }
                    }
                    ImGui::EndCombo();
                }
                ImGui::TableNextColumn();
                if (v.Owner.empty())
                {
                    ImGui::AlignTextToFramePadding();
                    ImGui::TextDisabled("open to everyone");
                }
                else
                {
                    bool any = false;
                    for (auto& p : s.Players)
                    {
                        if (p.Name == v.Owner || p.Host) continue;
                        bool on = std::find(v.Trusted.begin(), v.Trusted.end(), p.Name) != v.Trusted.end();
                        if (any) ImGui::SameLine();
                        if (ImGui::Checkbox(p.Name.c_str(), &on)) queue((on ? "trust " : "untrust ") + v.Key + " = " + p.Name);
                        any = true;
                    }
                    // Trusted friends who are offline still count; list them so they aren't forgotten.
                    for (auto& name : v.Trusted)
                    {
                        bool online = false;
                        for (auto& p : s.Players) online |= p.Name == name;
                        if (online) continue;
                        if (any) ImGui::SameLine();
                        ImGui::AlignTextToFramePadding();
                        ImGui::TextDisabled("%s (offline)", name.c_str());
                        any = true;
                    }
                    if (!any)
                    {
                        ImGui::AlignTextToFramePadding();
                        ImGui::TextDisabled("no other players online");
                    }
                }
                ImGui::PopID();
            }
            ImGui::EndTable();
        }

        void settingsTab(const State& s)
        {
            int mode = 0;
            for (int i = 0; i < 4; ++i)
                if (s.Mode == kModes[i]) mode = i;
            label("Village guard");
            if (combo("##mode", mode, kModeLabels, 4, px(kTextW)) && s.Mode != kModes[mode]) queue(std::string("mode ") + kModes[mode]);
            ImGui::SetItemTooltip("What happens when a friend changes a village that isn't theirs.");

            int sleep = 0;
            for (int i = 0; i < 4; ++i)
                if (s.Sleep == kSleepRules[i]) sleep = i;
            label("Night skip");
            if (combo("##sleep", sleep, kSleepLabels, 4, px(kTextW)) && s.Sleep != kSleepRules[sleep])
                queue(std::string("sleep ") + kSleepRules[sleep]);
            ImGui::SetItemTooltip("How many players must be in bed (or a paid tavern bed) to skip the night.");

            if (!g_limitActive) g_limit = s.Limit;
            label("Villages per friend");
            ImGui::SetNextItemWidth(px(kTextW));
            ImGui::SliderInt("##limit", &g_limit, 0, 5);
            g_limitActive = ImGui::IsItemActive();
            if (ImGui::IsItemDeactivatedAfterEdit() && g_limit != s.Limit) queue(std::format("limit {}", g_limit));
            ImGui::SetItemTooltip("A friend's first building outside every village founds their village, up to this many. "
                                  "You can always assign more.");

            ImGui::Spacing();
            bool tags = s.Tags == "on";
            if (ImGui::Checkbox("Owner names on villages and squads", &tags)) queue(tags ? "tags on" : "tags off");
            bool cheatsOpen = s.Cheats == "open";
            if (ImGui::Checkbox("Friends may use the game's cheats", &cheatsOpen)) queue(cheatsOpen ? "cheats open" : "cheats host");
            bool autoSetup = s.Auto == "on";
            if (ImGui::Checkbox("Run setup after every load", &autoSetup)) queue(autoSetup ? "auto on" : "auto off");
            ImGui::SetItemTooltip("About 15 s after a load: claim villages, redo transfers, re-register villagers, split squads.");

            ImGui::SeparatorText("Run now (answers go to the log)");
            if (ImGui::Button("Run setup")) queue("setup");
            ImGui::SameLine();
            if (ImGui::Button("Status")) queue("status");
            ImGui::SameLine();
            if (ImGui::Button("Squads")) queue("squads");
            ImGui::SameLine();
            if (ImGui::Button("People")) queue("people");
            ImGui::SameLine();
            if (ImGui::Button("Rates")) queue("rates");
            ImGui::SameLine();
            if (ImGui::Button("Trust list")) queue("trust");
        }

        void renderTab()
        {
            std::string text;
            ULONGLONG age = 0;
            std::deque<std::string> logCopy;
            {
                std::lock_guard lock(g_mx);
                text = g_state;
                age = GetTickCount64() - g_stateTick;
                logCopy = g_log;
            }
            if (text.empty())
            {
                ImGui::TextWrapped("BWCoop: waiting for the Lua mod. Load a save.");
                return;
            }
            State s = parse(text);

            textLine(std::format("BWCoop {}", s.Version));
            ImGui::SameLine();
            ImGui::TextDisabled("|");
            ImGui::SameLine();
            textLine(std::format("save: {}", s.Save));
            ImGui::SameLine();
            ImGui::TextDisabled("|");
            ImGui::SameLine();
            textLine(std::format("{} player{} online", s.Players.size(), s.Players.size() == 1 ? "" : "s"));
            if (age > 5000)
            {
                ImGui::SameLine();
                ImGui::TextColored(ImVec4(0.95f, 0.55f, 0.35f, 1.0f), "(not updating: in a menu or loading?)");
            }
            ImGui::TextDisabled("Quiet: nothing done here is announced to players.");

            if (ImGui::BeginTabBar("bwcoop_tabs"))
            {
                if (ImGui::BeginTabItem("Players"))
                {
                    playersTab(s);
                    ImGui::EndTabItem();
                }
                if (ImGui::BeginTabItem("Give"))
                {
                    giveTab(s);
                    ImGui::EndTabItem();
                }
                if (ImGui::BeginTabItem("Villager"))
                {
                    villagerTab();
                    ImGui::EndTabItem();
                }
                if (ImGui::BeginTabItem("World"))
                {
                    worldTab();
                    ImGui::EndTabItem();
                }
                if (ImGui::BeginTabItem("Villages"))
                {
                    villagesTab(s);
                    ImGui::EndTabItem();
                }
                if (ImGui::BeginTabItem("Settings"))
                {
                    settingsTab(s);
                    ImGui::EndTabItem();
                }
                ImGui::EndTabBar();
            }

            ImGui::Spacing();
            ImGui::SeparatorText("Log");
            if (ImGui::SmallButton("Clear"))
            {
                std::lock_guard lock(g_mx);
                g_log.clear();
                logCopy.clear();
            }
            float logH = std::max(px(140), ImGui::GetContentRegionAvail().y);
            if (ImGui::BeginChild("bwlog", ImVec2(0, logH), ImGuiChildFlags_Borders))
            {
                for (auto& l : logCopy)
                {
                    bool command = l.rfind("> ", 0) == 0;
                    bool failed = l.find("failed") != std::string::npos || l.find("error") != std::string::npos ||
                                  l.find("usage:") != std::string::npos;
                    if (command)
                        ImGui::TextColored(ImVec4(0.55f, 0.75f, 1.0f, 1.0f), "%s", l.c_str());
                    else if (failed)
                        ImGui::TextColored(ImVec4(0.95f, 0.55f, 0.35f, 1.0f), "%s", l.c_str());
                    else
                        ImGui::TextWrapped("%s", l.c_str());
                }
                if (ImGui::GetScrollY() >= ImGui::GetScrollMaxY()) ImGui::SetScrollHereY(1.0f);
            }
            ImGui::EndChild();
        }
    } // namespace

    void gui_render()
    {
        // UE4SS sizes its window to the OS window's outer size (frame and title bar included), so a tab's right
        // and bottom edges sit under the frame. Lay the tab out in a child that ends where the window is visible.
        const ImGuiViewport* vp = ImGui::GetMainViewport();
        ImVec2 pos = ImGui::GetWindowPos(), size = ImGui::GetWindowSize();
        float cutX = std::max(0.0f, pos.x + size.x - (vp->Pos.x + vp->Size.x));
        float cutY = std::max(0.0f, pos.y + size.y - (vp->Pos.y + vp->Size.y));
        ImVec2 avail = ImGui::GetContentRegionAvail();
        ImVec2 area(std::max(px(200), avail.x - cutX), std::max(px(200), avail.y - cutY));
        if (ImGui::BeginChild("bwcoop_root", area, ImGuiChildFlags_None, ImGuiWindowFlags_NoBackground)) renderTab();
        ImGui::EndChild();
    }

    namespace
    {
        auto lua_setState(const RC::LuaMadeSimple::Lua& lua) -> int
        {
            std::string s = takeString(lua);
            std::lock_guard lock(g_mx);
            g_state = std::move(s);
            g_stateTick = GetTickCount64();
            return 0;
        }

        auto lua_takeCommand(const RC::LuaMadeSimple::Lua& lua) -> int
        {
            std::lock_guard lock(g_mx);
            if (g_commands.empty())
            {
                lua.set_nil();
                return 1;
            }
            lua.set_string(g_commands.front());
            g_commands.pop_front();
            return 1;
        }

        auto lua_log(const RC::LuaMadeSimple::Lua& lua) -> int
        {
            std::string s = takeString(lua);
            std::lock_guard lock(g_mx);
            g_log.push_back(std::move(s));
            while (g_log.size() > 300) g_log.pop_front();
            return 0;
        }
    } // namespace

    void gui_register(const RC::LuaMadeSimple::Lua& lua)
    {
        lua.register_function("BWNative_GuiSetState", lua_setState);
        lua.register_function("BWNative_GuiTakeCommand", lua_takeCommand);
        lua.register_function("BWNative_GuiLog", lua_log);
    }
} // namespace bwcoop
