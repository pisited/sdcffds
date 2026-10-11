# BeamRT v0.066 first in-game test

Keep the camera fixed and let history warm after every sequence switch.

## Reload

```lua
beamrt_main.disable(); extensions.unload("beamrt_main"); extensions.load("beamrt_main")
print("BeamRT version: " .. tostring(beamrt_main.getVersion()))
beamrt_main.start()
```

Expected version: `0.066`. Check `beamng.log` for shader, Lua, texture, or
constant-binding errors before judging the image.

## Lowest-cost A/B

Use the interior test view and select screen-only GI first so world-cache
history does not obscure the sampling comparison:

```lua
beamrt_main.setGISource("screen")
beamrt_main.setGIPathCount(1)
beamrt_main.setBlueNoiseStrength(0)
```

Wait several frames and capture. Then:

```lua
beamrt_main.setBlueNoiseStrength(1)
```

Wait for the reset history to warm and capture again. Repeat at 2 and 4 paths.

Expected difference: strength one should trade clumped/pulsing or wave-like
hash noise for a finer, more evenly distributed pattern. It does not increase
ray count and is not expected to look fully denoised by itself.

## Keep v0.065 hit/emissive tests

The v0.065 controls remain valid:

```lua
beamrt_main.setCandidateContinuation(1)
beamrt_main.setCandidateRetryCount(4)
beamrt_main.setEmissiveSeparation(1)
```

## Fast rollback

```lua
beamrt_main.setBlueNoiseStrength(0)
```

That restores the exact v0.065 primary direction generator without changing
the other v0.065 features.
