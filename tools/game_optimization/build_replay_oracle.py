#!/usr/bin/env python3
"""Build a debug-only instruction-sampling oracle using an existing Ninja build.

The normal emulator and hardware images are unchanged. Compile a private copy
of ARM.cpp whose existing instruction-entry point invokes the sampler.
"""
import argparse
from pathlib import Path
import shlex
import subprocess
from instrument_spu_trace import instrument as instrument_spu
from instrument_ram_trace import instrument as instrument_ram
from instrument_itcm_trace import instrument as instrument_itcm

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--build', required=True, type=Path)
p.add_argument('--out', required=True, type=Path)
p.add_argument('--ninja', default='ninja')
p.add_argument('--trace-spu-writes', action='store_true',
               help='Include optional private audio-register/mix-boundary observation')
p.add_argument('--trace-spu-samples', action='store_true',
               help='Also observe existing FIFO/sample values and channel output; implies --trace-spu-writes')
p.add_argument('--trace-ram-bus', action='store_true',
               help='Observe private NDS main-RAM bus stores; add SPU sample tracing to interleave actual sound reads')
p.add_argument('--trace-itcm-writes', action='store_true',
               help='Also observe ARM9 interpreter ITCM stores; implies --trace-ram-bus')
args = p.parse_args()
args.trace_spu_writes = args.trace_spu_writes or args.trace_spu_samples
args.trace_ram_bus = args.trace_ram_bus or args.trace_itcm_writes
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
objects = [
    ('/ARM.cpp', out / 'ARM.oracle.cpp', 'ARM.oracle.o'),
    ('/src/replay/LayerCapture.cpp', source / 'tools/game_optimization/replay_oracle.cpp', 'oracle.o'),
]
if args.trace_spu_writes:
    (out / 'SPU.oracle.cpp').write_text(instrument_spu(
        (source / 'third_party/melonDS/src/SPU.cpp').read_text(), samples=args.trace_spu_samples))
    objects.append(('/SPU.cpp', out / 'SPU.oracle.cpp', 'SPU.oracle.o'))
if args.trace_ram_bus:
    (out / 'NDS.oracle.cpp').write_text(instrument_ram(
        (source / 'third_party/melonDS/src/NDS.cpp').read_text()))
    objects.append(('/NDS.cpp', out / 'NDS.oracle.cpp', 'NDS.oracle.o'))
if args.trace_itcm_writes:
    (out / 'CP15.oracle.cpp').write_text(instrument_itcm(
        (source / 'third_party/melonDS/src/CP15.cpp').read_text()))
    objects.append(('/CP15.cpp', out / 'CP15.oracle.cpp', 'CP15.oracle.o'))
for original, replacement, obj in objects:
    command = next(line for line in commands if ' -c ' in line and line.rstrip('\'"').endswith(original))
    command = shlex.split(command)
    command[command.index('-o') + 1] = str(out / obj)
    command[command.index('-c') + 1] = str(replacement)
    for flag in ['-MT', '-MF']:
        index = command.index(flag)
        del command[index:index + 2]
    command.remove('-MD')
    command += ['-fno-access-control', '-I' + str(source / 'third_party/melonDS/src')]
    if args.trace_ram_bus and obj == 'oracle.o':
        command += ['-DNDS_REPLAY_HAS_RAM_BUS=1']
    if args.trace_itcm_writes and obj == 'oracle.o':
        command += ['-DNDS_REPLAY_HAS_ITCM_BUS=1']
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
if args.trace_spu_writes:
    link.insert(1, str(out / 'SPU.oracle.o'))
if args.trace_ram_bus:
    link.insert(1, str(out / 'NDS.oracle.o'))
if args.trace_itcm_writes:
    link.insert(1, str(out / 'CP15.oracle.o'))
subprocess.run(link, cwd=build, check=True)
print(out / 'replay_oracle')
