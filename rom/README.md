# The cartridge is not in this repository

Dodge 'Em is Atari's, 1980 — CX2637, by Carla Meninsky. This project is a patch
and a server, not a place to redistribute it, and the generated disassembly is
the game just as much as the dump is. Both are gitignored.

Put your own dump here as `rom/dodgem.bin`. The build checks it against:

```
md5    83bdc819980db99bf89a7f2ed6a2de59
size   4096 bytes
name   Dodge 'Em (1980) (Atari) [fixed]   -- NTSC
```

`rom/dodgem.asm` is generated from it by `make disasm` and is never
hand-edited. Every change this port makes to the game is declared in
`tools/patches.py` and audited byte for byte by `tools/check_patch.py`.
