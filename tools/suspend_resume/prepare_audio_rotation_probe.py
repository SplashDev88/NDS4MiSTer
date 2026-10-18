#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate a frozen, isolated audio channel-rotation experiment.

Not a product implementation or a complete-machine checkpoint. The private
variant reuses live channel registers; the scan guard must hold every owner
until channel order is canonical, including cancellation and owner loss.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

SOUND = 'third_party/Nitro_DarkSide/d2dabe/rtl/nds_sound.vhd'
REFERENCE = '7e94517190a1328cf64fa46d964a530e0fdbfe1f'


def rotate_sound(s):
    def once(a,b):
     nonlocal s
     assert s.count(a)==1,(a[:60],s.count(a));s=s.replace(a,b,1)
    once('   signal stop_playback : std_logic;','''   -- Private area/continuation experiment: rotate hidden channel fields to
   -- one fixed maintenance port. NOT a deployable console implementation.
   -- Outer release must wait for index zero through the all-owner scan guard.
   signal stop_playback : std_logic;
   signal rotate_index, rotate_goal : natural range 0 to 15 := 0;
   signal rotate_step : std_logic;''')
    once("   stop_playback <= checkpoint_stop when EXPERIMENTAL_CHECKPOINT else '0';",'''   rotate_goal <= to_integer(checkpoint_address(7 downto 4)) when EXPERIMENTAL_CHECKPOINT and
      checkpoint_stop = '1' and (checkpoint_stopped = '1' or restore_active = '1') and
      checkpoint_address < 256 and checkpoint_address(3 downto 0) >= 4 and checkpoint_address(3 downto 0) <= 11 else 0;
   rotate_step <= '1' when EXPERIMENTAL_CHECKPOINT and rotate_index /= rotate_goal and
      restore_curw_pending = '0' and (reset = '0' or restore_active = '1') else '0';
   stop_playback <= '1' when EXPERIMENTAL_CHECKPOINT and (checkpoint_stop = '1' or rotate_index /= 0) else '0';
   process(clk) begin
      if rising_edge(clk) then
         if reset = '1' and restore_active = '0' then rotate_index <= 0;
         elsif rotate_step = '1' then
            if rotate_index = 15 then rotate_index <= 0; else rotate_index <= rotate_index + 1; end if;
         end if;
      end if;
   end process;''')
    # The saved round-robin lookup cache is channel state too.
    once("         if restore_active = '1' then\n            if restore_write_valid = '1' then\n               a := to_integer(checkpoint_address);",'''         if rotate_step = '1' then
            for i in 0 to 15 loop adstep_q(i) <= adstep_q((i+1) mod 16); end loop;
         elsif restore_active = '1' then
            if restore_write_valid = '1' then
               a := to_integer(checkpoint_address);''')
    once('adstep_q(a/16) <= to_integer(unsigned(checkpoint_write_data(14 downto 0)));','adstep_q(0) <= to_integer(unsigned(checkpoint_write_data(14 downto 0)));')
    start=s.index('            when 4 =>\n               mask :=');end=s.index('            when 12 | 13 =>',start)
    x=s[start:end].replace('chan(c)','chan(0)').replace('fetch_read_state.nxtv','chan(0).nxtv').replace('mix_read_state.cursmp','chan(0).cursmp').replace('adstep_q(c)','adstep_q(0)');s=s[:start]+x+s[end:]
    once("restore_next = 270 and restore_settle = 2 and checkpoint_write = '0' and restore_curw_pending = '0' and", "restore_next = 270 and restore_settle = 2 and checkpoint_write = '0' and restore_curw_pending = '0' and rotate_index = 0 and")
    once("if restore_active = '1' and restore_error = '0' and a < 270 and ram_ready and restore_curw_pending = '0' then", "if restore_active = '1' and restore_error = '0' and a < 270 and ram_ready and restore_curw_pending = '0' and rotate_index = rotate_goal then")
    once('if EXPERIMENTAL_CHECKPOINT and a < 270 and ram_ready and','if EXPERIMENTAL_CHECKPOINT and a < 270 and ram_ready and rotate_index = rotate_goal and')
    start=s.index('                        when 4 =>\n                           chan(n).timer');end=s.index('                        when others => null;',start)
    x=s[start:end].replace('chan(n)','chan(0)').replace('restore_curw_channel <= n;','restore_curw_channel <= 0;');s=s[:start]+x+s[end:]
    fields=['timer','remwords','subpos','startdel','curw','nxtw','curv','nxtv','adhdr','adval','adidx','adval_l','adidx_l','noise','psgpos','cursmp']
    rotate="         elsif rotate_step = '1' then\n            for i in 0 to 15 loop\n"+'\n'.join('               chan(i).'+f+' <= chan((i+1) mod 16).'+f+';' for f in fields)+"\n            end loop;\n"
    once("         elsif restore_active = '1' then\n               -- Restore the current word", rotate+"         elsif restore_active = '1' then\n               -- Restore the current word")
    once('   signal restore_active, restore_write_valid : std_logic;',
         '   signal restore_active, restore_write_valid, restore_image_complete : std_logic;')
    once("      checkpoint_restore_error : out std_logic := '0'",
         "      checkpoint_restore_error : out std_logic := '0';\n      checkpoint_release_ready : out std_logic := '1'")
    once("   checkpoint_restore_ready <= '1' when",
         "   checkpoint_release_ready <= '1' when not EXPERIMENTAL_CHECKPOINT or rotate_index = 0 else '0';\n"
         "   checkpoint_restore_ready <= restore_image_complete when rotate_index = 0 else '0';\n"
         "   restore_image_complete <= '1' when")
    once("restore_curw_pending = '0' and rotate_index = 0 and", "restore_curw_pending = '0' and")
    once("or checkpoint_restore_ready = '1') then", "or restore_image_complete = '1') then")
    return s


def prepare(repo, output):
    if output == repo or repo in output.parents:
        raise ValueError('Experiment output must be outside the checkout')
    output.mkdir(parents=True, exist_ok=False)
    source = output/'source'
    (output/'run').mkdir()
    files = [SOUND, 'third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd',
             'rtl/tb_mem_sync_ram_dual_byte_enable.vhd', 'rtl/tb_nds_sound_fetch_state_ram.vhd',
             'rtl/nds_checkpoint_audio_scan_guard.vhd', 'rtl/tb_nds_checkpoint_sound_rotation.vhd',
             'tools/test_checkpoint_audio_rotation.sh', 'tools/suspend_resume/prepare_audio_rotation_probe.py']
    original = {}
    for name in files:
        (source/name).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(repo/name, source/name)
        original[name] = hashlib.sha256((source/name).read_bytes()).hexdigest()
    (source/SOUND).write_text(rotate_sound((source/SOUND).read_text()))
    reference = subprocess.check_output(['git','show',REFERENCE+':'+SOUND], cwd=repo).decode()
    # This constant observation output is the sole reference instrumentation.
    old = "      checkpoint_restore_error : out std_logic := '0'"
    if reference.count(old) != 1:
        raise ValueError('Pinned reference port anchor changed')
    instrumented = reference.replace(old, old+";\n      checkpoint_release_ready : out std_logic := '1'")
    (output/'run/sound-baseline.vhd').write_text(instrumented)
    generated = {str(p.relative_to(output)):hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in output.rglob('*') if p.is_file()}
    receipt = dict(scope='Private component experiment, not a gameplay beta or full-machine proof.',
                   original=original, generated=generated, reference_commit=REFERENCE,
                   reference_sha256=hashlib.sha256(reference.encode()).hexdigest())
    manifest = json.dumps(receipt, sort_keys=True, indent=2)+'\n'
    (output/'INPUTS.json').write_text(manifest)
    print('AUDIO_ROTATION_INPUT_SHA256', hashlib.sha256(manifest.encode()).hexdigest(), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    prepare(Path(__file__).resolve().parents[2], args.output.resolve())
