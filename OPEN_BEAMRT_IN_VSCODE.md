# Open BeamRT in Visual Studio Code

Open `BeamRT.code-workspace` in Visual Studio Code. The file list opens the actual
BeamNG unpacked mod folder, named **BeamRT Live Mod**.

VS Code 1.141.0 was installed for your Windows account. Double-click the desktop
shortcut **BeamRT - VS Code**, or search for that same shortcut in the Start
menu, to open this workspace directly. It opens the live mod, not the separate
older `beamrt` folder that already exists on the desktop.

The workspace was opened with `main.lua` selected. If VS Code presents a
Workspace Trust prompt, review it and choose whether to trust this folder;
the trust/security setting has not been disabled.

Useful places to start:

- `lua/ge/extensions/beamrt/main.lua`: BeamRT controls and game integration.
- `shaders/beamrt/`: rendering shader source files.
- `scripts/` and `tools/`: supporting scripts and development tools.
- `README.md`: mod notes and version history.

This is the live mod. Saving source changes here changes the files BeamNG uses;
you may need to reload the extension or game to see a change. Automatic saving is
turned off for this workspace so you choose when to save edits.

Generated validation output and Python cache folders are hidden from the file
list and searches. They remain on disk. Binary `.bin` files are also omitted from
searches; shader and Lua source files stay visible.

A new terminal starts in this folder using PowerShell 7. VS Code may offer the
optional Lua and PowerShell language extensions listed in the workspace.
