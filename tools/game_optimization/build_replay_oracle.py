#!/usr/bin/env python3
"""Build a debug-only instruction-sampling oracle using an existing Ninja build.

The normal emulator and hardware images are unchanged. Compile a private copy
of ARM.cpp whose existing instruction-entry point invokes the sampler.
"""
import argparse
from pathlib import Path
import shlex
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--build', required=True, type=Path)
p.add_argument('--out', required=True, type=Path)
p.add_argument('--ninja', default='ninja')
args = p.parse_args()
source = Path(__file__).resolve().parents[2]
build, out = args.build.resolve(), args.out.resolve()
out.mkdir(parents=True, exist_ok=True)
subprocess.run([args.ninja, '-C', str(build), 'nds_layer_capture'], check=True)
arm = (source / 'third_party/melonDS/src/ARM.cpp').read_text()
entry = 'void ARM::TraceInstructionEntry()\n{'
assert arm.count(entry) == 1
arm = arm.replace(entry, '''extern bool replay_profile_active;
extern void replay_instruction(unsigned,u32,u32,const u32*);
void ARM::TraceInstructionEntry()
{
    if(replay_profile_active)
        replay_instruction(Num,R[15]-((CPSR&0x20)?4u:8u),CurInstr,R);''')
(out / 'ARM.oracle.cpp').write_text(arm)
commands = subprocess.check_output(
    [args.ninja, '-C', str(build), '-t', 'commands', 'nds_layer_capture'], text=True).splitlines()
for original, replacement, obj in [
    ('/ARM.cpp', out / 'ARM.oracle.cpp', 'ARM.oracle.o'),
    ('/src/replay/LayerCapture.cpp', source / 'tools/game_optimization/replay_oracle.cpp', 'oracle.o'),
]:
    command = next(line for line in commands if ' -c ' in line and line.rstrip('\'"').endswith(original))
    command = shlex.split(command)
    command[command.index('-o') + 1] = str(out / obj)
    command[command.index('-c') + 1] = str(replacement)
    for flag in ['-MT', '-MF']:
        index = command.index(flag)
        del command[index:index + 2]
    command.remove('-MD')
    command += ['-fno-access-control', '-I' + str(source / 'third_party/melonDS/src')]
    subprocess.run(command, cwd=build, check=True)
# Reuse the configured compiler and platform/link flags rather than assuming
# a host architecture. Replace only the original front-end object list.
link = shlex.split(next(part.strip() for line in commands for part in line.split('&&')
                        if ' -o nds_layer_capture ' in part))
link = [word for word in link if word not in [
    'CMakeFiles/nds_layer_capture.dir/src/replay/LayerCapture.cpp.o',
    'CMakeFiles/nds_layer_capture.dir/src/melonds/MelonDsBackend.cpp.o']]
link[link.index('-o') + 1] = str(out / 'replay_oracle')
link[1:1] = [str(out / 'oracle.o'), str(out / 'ARM.oracle.o')]
subprocess.run(link, cwd=build, check=True)
print(out / 'replay_oracle')
