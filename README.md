# Village Pact Host

Village Pact is a co-op mod for Bellwright with two parts:

- **Village Pact: Bellwright Co-op** on the Steam Workshop. Every player subscribes to it, the host included.
- **Village Pact Host**, this download. Only the host installs it; the rules and most features run on the host's game.

## What it adds
- **Your own village.** A friend's first building outside every village founds their village. Their buildings, villagers and recruits stay in it. Each friend may own one village; the host can allow more.
- **Land claims.** Land belongs to the village that built on it first. Other players, the host included, build there only if that village trusts them.
- **Your own army.** Each player commands their own companions, squads and reservists.
- **Villages panel** beside the village screen (N): people, storage, the full stock list, caravans and keep-stocked rules.
- **Halls for everyone.** Every player village can build its own Village Hall and Town Hall.
- **Newcomers.** Every hour of play, up to two travelers come to rest by a Village Hall in a village with a free bed. The village's owner can recruit them; anyone not recruited moves on after 30 minutes.
- **Night skip** once half the players are in bed. The host can change the rule.
- **Host admin window** (Ctrl+O, BWCoop tab): per-player settings and tools.

## What you need
- Bellwright on Steam, on Windows. This release is tested with Steam build 24840601 (October 2026).
- The Workshop part, for every player. Everyone needs the same version; Steam keeps it up to date.

## Install
1. Close Bellwright.
2. Download VillagePactHost-<version>.zip from the Releases section of this page. Right-click it and choose Extract All.
3. In the extracted folder, double-click Install.bat. If Windows says "Windows protected your PC", choose More info, then Run anyway. The installer finds Bellwright through Steam, or asks where the game is.
4. Start Bellwright and host as usual.

UE4SS is the tool that loads the host mod, and the download includes it. If you already use UE4SS, the installer moves it and your other UE4SS mods to a VillagePact-backup folder, and Uninstall.bat puts them back. All of these folders are in the game's Bellwright\Binaries\Win64 folder.

## Commands
The host can type `bwcoop` in the game console (~ or F10) to see the mod's status. The full command list is in COMMANDS.md.

## Update
Close the game, extract the new zip and run its Install.bat. Your world settings are kept.

## Uninstall
Close the game and run Uninstall.bat. It moves Village Pact Host to a VillagePact-removed folder, with your world settings inside, and puts back any UE4SS you had before.

## After a Bellwright update
A game update can stop the host part from working until a matching Village Pact Host release is out. If the game won't start or the features stop working, run Uninstall.bat and check Releases. The Workshop part may also show as Outdated in the game's Mods menu until it is updated.

## Antivirus
UE4SS loads through a file called dwmapi.dll in the game's folder, and some antivirus tools flag files like that. SHA256SUMS.txt in the zip lists the checksum of every file the installer copies.

## License
Copyright (c) 2026 Parakalix Studios. All rights reserved; see LICENSE.txt. Third-party parts keep their own licenses; see THIRD-PARTY-NOTICES.txt. Village Pact is a fan-made mod, not made by or affiliated with the developers or publishers of Bellwright.
