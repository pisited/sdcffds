"""Compile literal PostFX shader entries registered by BeamRT main.lua.

Requires the user's installed BeamNG headers and FXC. Produces isolated,
ignored compiler artifacts only; never loads a DLL, edits settings or runs
BeamNG. Offline SM5/SM6 compilation is not proof of game shader execution.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]


def shader_entries(source):
    return sorted(set(re.findall(r"['\"](shaders/beamrt/[^'\"\r\n]+\.hlsl)['\"]", source)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game-root', required=True)
    parser.add_argument('--compiler', required=True)
    parser.add_argument('--coherent', action='store_true', help='Compile the opt-in Coherent SSR pass graph instead.')
    parser.add_argument('--volumes', action='store_true', help='Compile the opt-in local spotlight haze shader instead.')
    parser.add_argument('--shader-model', choices=('5_0', '6_0'), default='5_0', help='Use 6_0 with installed DXC for wave branches.')
    args = parser.parse_args()
    game = Path(args.game_root).resolve()
    compiler = Path(args.compiler).resolve()
    if not (game / 'shaders/common/postFx/postFx.h.hlsl').is_file():
        parser.error('Installed BeamNG PostFX headers missing; no substitutes bundled.')
    if not compiler.is_file():
        parser.error('Compiler missing; no installer will be run.')
    entries = shader_entries((ROOT / 'lua/ge/extensions/beamrt/main.lua').read_text())
    if args.coherent:
        entries = sorted(str(p.relative_to(ROOT)).replace('\\', '/') for p in
                         (ROOT / 'shaders/beamrt/coherent').glob('*pass*_p.hlsl'))
        entries.append('shaders/beamrt/coherent/beamrt_coherent_v.hlsl')
    if args.volumes:
        entries = ['shaders/beamrt/beamrtLocalVolumeP_v004.hlsl']
    if not entries:
        raise RuntimeError('No literal BeamRT shader entries found.')
    output = ROOT / '.beamrt-validation' / ('postfx-compile-' + uuid.uuid4().hex)
    output.mkdir(parents=True, exist_ok=False)
    results = []
    for entry in entries:
        for stage in ('vs', 'ps'):
            if args.coherent and (stage == 'vs') != entry.endswith('_v.hlsl'):
                continue
            artifact = output / (Path(entry).name + '.' + stage + '.cso')
            cmd = [str(compiler), '/nologo', '/Ges', '/WX', '/O3', '/T', stage + '_' + args.shader_model,
                   '/E', 'main', '/I', str(ROOT), '/I', str(game), '/Fo', str(artifact)]
            if stage == 'vs':
                cmd += ['/D', 'SHADER_STAGE_VS=1']
            result = subprocess.run(cmd + [str(ROOT / entry)], capture_output=True, text=True, timeout=120)
            message = result.stdout + result.stderr
            (output / (artifact.name + '.log')).write_text(message)
            results.append({'source': entry, 'stage': stage, 'exit': result.returncode})
            print(('PASS' if result.returncode == 0 else 'FAIL') + ': ' + entry + ' (' + stage + ')', flush=True)
            if result.returncode:
                print(message, flush=True)
    (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print('Compiler artifacts: ' + str(output), flush=True)
    failures = sum(item['exit'] != 0 for item in results)
    if failures:
        raise SystemExit(str(failures) + ' shader entries failed compilation.')
    print('PASS: ' + str(len(results)) + ' PostFX vertex/pixel compilations; no game execution.')


if __name__ == '__main__':
    main()
