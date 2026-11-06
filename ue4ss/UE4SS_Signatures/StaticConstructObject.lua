-- Bellwright UE5.7.4, Steam build 24840601. Pattern first published by HearthServer
-- (github.com/humangenome/HearthServer, MIT license, Copyright (c) 2026 HumanGenome).
-- Checked with tools/verify_sigs.py: one match in .text, resolves to the PDB symbol below.
-- PDB ?StaticConstructObject_Internal@@...  RVA 0x015e8140
function Register()
    return "4C 8B DC 55 53 41 56 49 8D AB 38 FE FF FF"
end

function OnMatchFound(MatchAddress)
    return MatchAddress
end
