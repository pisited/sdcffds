"""Compile prepared native sunlight hook variants against installed headers.

Does not generate/rebind hooks or load BeamNG. Requires a current, explicitly
prepared manifest; preserves the distinction between compilation and execution.
"""
import argparse
import json
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game-root', required=True)
    parser.add_argument('--compiler', required=True)
    args = parser.parse_args()
    game = Path(args.game_root).resolve()
    manifest = json.loads((ROOT / 'shaders/beamrt/generated/nativeSunHook.json').read_text())
    if manifest['schema'] != 'beamrt.native.sun.hook.v2':
        raise ValueError('Prepared comparison manifest required.')
    if (game / manifest['nativePath']).read_text() != manifest['nativeSource']:
        raise ValueError('Native shader changed; explicitly prepare against this installation.')
    for path, expected in manifest['dependencies'].items():
        base = ROOT if path.startswith('shaders/beamrt/') else game
        if (base / path).read_text() != expected:
            raise ValueError('Dependency changed: ' + path)
    output = ROOT / '.beamrt-validation' / ('sun-native-compile-' + uuid.uuid4().hex)
    output.mkdir(parents=True, exist_ok=False)
    count = 0
    for mode in ('hybrid', 'beamrt-only', 'unshadowed', 'split'):
        entry = manifest['variants'][mode]
        source = ROOT / entry['shaderPath']
        if source.read_text() != entry['generatedSource']:
            raise ValueError('Prepared native variant changed: ' + mode)
        for bits in range(8):
            cmd = [args.compiler, '/nologo', '/Ges', '/WX', '/O3', '/T', 'ps_5_0', '/E', 'main',
                   '/I', str(ROOT), '/I', str(game),
                   '/I', str(game / 'shaders/common/lighting/advanced'),
                   '/Fo', str(output / (mode + '-' + str(bits) + '.ps.cso'))]
            for index, define in enumerate(('NO_SHADOW', 'USE_SSAO_MASK', 'USE_SSS_MASK')):
                if bits & (1 << index):
                    cmd += ['/D', define + '=1']
            result = subprocess.run(cmd + [str(source)], capture_output=True, text=True, timeout=120)
            (output / (mode + '-' + str(bits) + '.log')).write_text(result.stdout + result.stderr)
            if result.returncode:
                raise RuntimeError(mode + ': ' + result.stdout + result.stderr)
            count += 1
        print('PASS: ' + mode + ' native sun-light permutations', flush=True)
    print('PASS: ' + str(count) + ' prepared native sunlight PS compilations; no game execution.')
    print('Artifacts: ' + str(output))


if __name__ == '__main__':
    main()
