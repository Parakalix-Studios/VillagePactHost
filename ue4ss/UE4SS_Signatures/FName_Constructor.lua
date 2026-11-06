-- Bellwright UE5.7.4, Steam build 24840601. Pattern first published by HearthServer
-- (github.com/humangenome/HearthServer, MIT license, Copyright (c) 2026 HumanGenome).
-- Checked with tools/verify_sigs.py: one match in .text, resolves to the PDB symbol below.
-- PDB ??0FName@@QEAA@PEB_WW4EFindName@@@Z  RVA 0x013bb710
function Register()
    return "48 89 5C 24 08 57 48 83 EC 30 48 8B D9 48 89 54 24 20"
end

function OnMatchFound(MatchAddress)
    return MatchAddress
end
