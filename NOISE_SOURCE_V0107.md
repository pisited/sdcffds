# v0.107 — rejected optional noise atlas no longer loaded

## What was wrong

The latest BeamNG log rejects the v094 custom atlas DDS with "only RGB formats
are supported". Its local header already declares RGB-only DDPF_RGB 0x40 and
matches the earlier native-header repair. This failure survived the previous
container/header attempts. No additional header tweak or sampling-quality claim
is justified by that evidence.

Normal startup bound the rejected DDS even when the selected source was native
BeamNG noise. The tuner and setter also allowed users to select STBN as if that
resource had loaded. File existence and Lua selection were not GPU loading proof.

## What changed / now implemented

Main v0.107 uses a small noise-source policy module. Native BeamNG/GTAO aliases
retain the existing mode 0 and native noiseBlue.png resource. Experimental STBN
aliases return false with a clear unavailable reason, without mutating the
current source or resetting history. Saved STBN selection is refused on reload;
other tuning still applies. No settings file is rewritten.

The auxiliary pack binds a valid native resource in the inactive slot instead
of requesting the failing DDS. Its v002 wrapper clears the reserved STBN bank,
leaving history, velocity, native-noise bank, surfel layout and six-input ABI
unchanged. The v001 behavior is preserved when the wrapper define is absent.
The tuner explicitly reports the experimental atlas unavailable.

Original DDS/PNG atlas assets remain untouched for later recovery. No texture
regeneration, format/cooker gamble, filter, shader GI/SSR arithmetic or preset
retune was introduced. Current reflection GGX sampling uses its existing hash
sequence, not this STBN bank; this is not a reflection-noise repair.

## Verified / still unverified

- Six new real-Lua policy/main-setter/binding regressions pass; all 95 retained
  and new Python/Lua tests pass. Main compiles in Lua 5.1 and LuaJIT.
- Both auxiliary shader variants compile as strict SM5 vertex and pixel stages
  with FXC /Ges /WX. Original data files are unchanged.
- Fresh in-game v0.107 uptake and absence of a NEW DDS request in its reload log
  remain unverified. Historical startup errors remain in the same log and are
  not evidence that a later reload still attempted the DDS.
- Custom STBN loading/quality remain unsupported, not fixed. Native-source
  behavior and shader compilation do not establish final-image quality.

## Reload / next milestone

Use the one-line GE Lua reload at the top of README. It preserves tuning and
clears BeamRT helper caches after unloading its extensions; expected runtime is
v0.107. No scene change, photo audit or reflection comparison is requested.

The next substantial renderer milestone remains the no-ReShade native-to-BeamNG
resource connection. Do not restart atlas diagnosis or add denoisers to claim
that independent integration boundary has been resolved.
