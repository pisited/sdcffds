# Legacy reflection snapshot

`legacy-reflections-v0.117-2026-10-20.zip` is a source snapshot made before the
v0.118 tabbed-tuner cleanup. It contains the complete old `main.lua` tuner/controller,
selected active legacy reflection entries, the owned SSSR traversal helper and
the native-comparison/compatibility/lab modules. It is **not** a self-contained
installable older mod or a snapshot of every dependency, shader include or saved
user setting. Do not install it as a second mod or overwrite newer source wholesale.

SHA256: `319968120aa4e58bfa3837b426bb568fb7ec4eda65ef3f9ff065f8f328a26a12`.

Original files were not deleted. Their reflection controls are now under the
Legacy tab, with audits and diagnostic views under Diagnostics. GI, its four
presets and saved tuning remain available under Lighting & GI. The current
screen-space reflection controls use their independent session-only parameters.
Opening a tab does not switch renderers, change settings or start a capture.

This is a development/rollback artifact, not a file to ship in the public
repository mod. Exclude this archive, native build products, tests and other
unused development files from any eventual release package.
