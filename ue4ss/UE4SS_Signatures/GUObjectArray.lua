-- Bellwright UE5.7.4, Steam build 24840601. Pattern first published by HearthServer
-- (github.com/humangenome/HearthServer, MIT license, Copyright (c) 2026 HumanGenome).
-- Checked with tools/verify_sigs.py: one match in .text, resolves to the PDB symbol below.
-- PDB ?GUObjectArray@@3VFUObjectArray@@A  RVA 0x0bf7f120 (lea rcx,[rip+GUObjectArray] at match+13)
function Register()
    return "48 83 C4 38 E9 ?? ?? ?? ?? 48 83 EC 28 48 8D 0D ?? ?? ?? ?? E8 ?? ?? ?? ?? 48 8D 0D ?? ?? ?? ??"
end

function OnMatchFound(MatchAddress)
    local leaInstr = MatchAddress + 13
    return leaInstr + 7 + DerefToInt32(leaInstr + 3)
end
