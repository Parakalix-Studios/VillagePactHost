-- Bellwright UE5.7.4, Steam build 24840601. Pattern first published by HearthServer
-- (github.com/humangenome/HearthServer, MIT license, Copyright (c) 2026 HumanGenome).
-- Checked with tools/verify_sigs.py: one match in .text, resolves to the PDB symbol below.
-- PDB ?GNatives@@...  RVA 0x0bc34ed0 (lea rdi,[rip+GNatives] at match+3)
function Register()
    return "48 8B D9 48 8D 3D ?? ?? ?? ?? 0F 1F 40 00"
end

function OnMatchFound(MatchAddress)
    local leaInstr = MatchAddress + 3
    return leaInstr + 7 + DerefToInt32(leaInstr + 3)
end
