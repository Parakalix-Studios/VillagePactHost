# Village Pact Host commands

The host types these in the game console: press ~ or F10, type the command, press Enter. Other players don't use the console.

A player is named by their character name, or `me` for the host. A village is named as it appears in the game. The examples use the villages Oakhold and Riverside and the player Ann. Settings are kept per world unless a line says otherwise.

## Status
- `bwcoop`: the rule mode, every village with its owner, and the players online.
- `bwcoop players`: the players online.

## Villages and owners
- `bwcoop assign Oakhold = Ann`: makes Ann the owner of Oakhold.
- `bwcoop unassign Oakhold`: opens Oakhold to everyone.
- `bwcoop trust Oakhold = Ann`: lets Ann build and manage in Oakhold like its owner. `bwcoop untrust Oakhold = Ann` takes it back; `bwcoop trust` lists who is trusted.
- `bwcoop limit 2`: how many villages each friend may own (default 1). The host has no limit.
- `bwcoop move Riverside`: moves the village building nearest you (within 15 m) to Riverside.
- `bwcoop color Ann = blue`: Ann's village color on everyone's map; `auto` lets the mod pick. `bwcoop color` lists the colors.

## Land
Land is claimed in 10 m squares. Each building claims the free land around it: large buildings such as halls, farms and barns 100 m; houses, workshops and anything not listed 50 m; resource camps 40 m; walls, fences and towers 25 m; small items such as traps, chests and decorations only their own square; fast travel signs nothing.
- `bwcoop claims`: the land of each village.
- `bwcoop claims reset`: forgets the saved claims and claims the land again from today's buildings.
- `bwcoop founding`: the order that decides contested land (the host's villages first, then the order the villages were founded). `bwcoop founding Oakhold, Riverside` sets that order by hand.
- `bwcoop buildings`: the building types in player villages and how far each one claims.
- `bwcoop range camps = 30`: how far a building type, game group or size (large, medium, camps, defenses, small) claims, in meters. 0 = its own square, -1 = no land, `default` undoes the change.
- `bwcoop overlaps`: buildings that stand inside another village's area.

## Rules
- `bwcoop mode enforce`: blocks what the rules don't allow. New worlds start here.
- `bwcoop mode warn`: allows it, but tells the player and writes it to the log.
- `bwcoop mode off`: turns the rules off.
- `bwcoop cheats host`: the game's cheats work for the host only (default). `bwcoop cheats open` opens them to everyone.
- `bwcoop sleep half`: how many players must be in bed to skip the night: `all`, `half` (default), `one` or `host`.

## Villagers and squads
- `bwcoop people`: the residents of each village, and villagers registered somewhere other than where they live. `bwcoop people fix` registers them where they live.
- `bwcoop squads`: each squad's owner and what each player commands.
- `bwcoop squads split`: moves each player's people into their own squads. Dismiss raised squads first.
- `bwcoop setup`: runs the world setup again. It also runs by itself about 15 seconds after each load; `bwcoop auto off` and `bwcoop auto on` turn that off and on.

## Newcomers
- `bwcoop newcomers`: who is waiting where, and which villages qualify.
- `bwcoop newcomers off` / `bwcoop newcomers on`: turns newcomers off or on for this world.
- `bwcoop newcomers now`: brings one now to a village that qualifies. `bwcoop newcomers now Oakhold` brings one to Oakhold even without a hall or a free bed.
- `bwcoop newcomers spot`: stand where newcomers should wait, near a finished hall, and run this. Every hall of that kind, in every world, then uses the same spot. `bwcoop newcomers spot reset` goes back to the built-in spot.

## Goods and caravans
- `bwcoop stock`: item counts per village. `bwcoop stock Oakhold 20` shows Oakhold's top 20.
- `bwcoop caravans`: caravan stations, routes and the caravans out now. Add a village name to see one village.
- `bwcoop keep Riverside planks 200 from Oakhold keeping 100`: keeps Riverside topped up to 200 planks with Oakhold's caravans, leaving at least 100 in Oakhold. `keeping` is optional.
- `bwcoop keep remove Riverside planks`: ends that rule. `bwcoop keep` lists the rules, and why a caravan didn't leave.
- `bwcoop balance`: this world's balance settings.
- `bwcoop balance carts 250`: changes one: `carts` (space per caravan cart, game 50), `storage x3` (capacity of every storage), `hiring x0.5` (renown cost of hiring), `roads 1.5` (road speed bonus, game 1.2), `carry x2` (how much a villager carries). `bwcoop balance carts default` undoes it.
- `bwcoop deliveries on` / `bwcoop deliveries off`: the game's older instant deliveries between villages at midnight (default off).

## Per-player rates
- `bwcoop rates Ann xp=1.5 speed=2 cost=0.5 build=0 read=1`: Ann's XP multiplier, crafting speed (1000 = instant), crafting cost (0 = free), building cost (0 = free) and instant skill books (1 = on). Any of them can be left out; 1 is normal. `bwcoop rates` lists everyone's.
- `bwcoop levelup Ann Farming` / `bwcoop leveldown Ann Farming`: one skill level up or down. `look` instead of a name means the villager you are looking at.

## Admin tools
Nothing here is announced to other players. The host admin window (Ctrl+O, BWCoop tab) has the same tools.
- `bwcoop give Ann Piece of Smoked Meat 5`: puts items in Ann's inventory, by the name shown in the game. `bwcoop items smoked meat` searches item names.
- `bwcoop money 500` / `bwcoop renown 100`: adds shared money or renown.
- `bwcoop perk Ann warrior 2`: adds perk points (`warrior`, `rogue` or `explorer`).
- `bwcoop xp Ann Archery 500` / `bwcoop skill Ann Archery 5`: adds skill XP / sets a skill level.
- `bwcoop vxp Farming 500` / `bwcoop vskill Farming 5`: the same for the villager you are looking at.
- `bwcoop time 6`: moves the clock forward 6 hours.

Skills: Strength, Agility, OneHanded, TwoHanded, Polearms, Shields, Archery, Harvesting, Farming, AnimalHandling, Cooking, Crafting, Researching, Laborer.

## If something goes wrong
- `bwcoop mode warn` stops the rules from blocking anything while you sort it out.
- Every block and error is written to BWCoop.log in the game's Bellwright\Binaries\Win64\ue4ss\Mods\BWCoop folder.
