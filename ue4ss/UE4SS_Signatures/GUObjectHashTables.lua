-- Bellwright UE5.7.4, Steam build 24840601. Pattern first published by HearthServer
-- (github.com/humangenome/HearthServer, MIT license, Copyright (c) 2026 HumanGenome).
-- Checked with tools/verify_sigs.py: one match in .text, resolves to the PDB symbol below.
-- PDB ?Get@FUObjectHashTables@@SAAEAV1@XZ  RVA 0x015f2c60
-- Contains fixed RIP displacements: re-derive after every game update.
function Register()
    return "40 53 48 83 EC 20 8B 0D C4 C1 C5 0A 65 48 8B 04 25 58 00 00 00 BA 84 1A 00 00 48 8B 04 C8 8B 04 02 39 05 81 C8 98 0A"
end

function OnMatchFound(MatchAddress)
    return MatchAddress
end
