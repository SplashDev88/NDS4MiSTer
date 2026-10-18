# SPDX-License-Identifier: GPL-3.0-only
"""Check that the NAND bench detects intentional protocol/address faults."""
from pathlib import Path
import json,subprocess,tempfile,shutil
import argparse
ap=argparse.ArgumentParser();ap.add_argument('--output',type=Path,required=True);args=ap.parse_args()
E=args.output;E.mkdir(parents=True,exist_ok=True);S=Path(__file__).resolve().parents[1]
original=(S/'third_party/Nitro_DarkSide/d2dabe/rtl/nds_card.vhd').read_text()
mutations={
 'zero_high_bank':("std_logic_vector(nand_addr(23 downto 20)) when nand_enabled = '1'", "x\"0\" when nand_enabled = '1'"),
 'ignore_cache_ready':("backup_cache_ready = '1'", "true"),
 'discard_commits':('''                  when x"84" =>
                     nand_page_valid <= '0'; nand_buffer_pos <= (others => '0'); nand_buffer_words <= 0;''','''                  when x"84" => null;'''),
 'no_read_page_wrap':("nand_addr(11 downto 0) <= nand_addr(11 downto 0)+1;","nand_addr <= nand_addr+1;"),
 'allow_id_region_program':('resize(nand_page_addr,32)+2048 <= nand_size-x"00020000"','resize(nand_page_addr,32)+2048 <= nand_size'),
}
results={}
for name,(old,new) in mutations.items():
 assert old in original,name
 with tempfile.TemporaryDirectory(prefix='nand-mutation-') as directory:
  d=Path(directory)
  (d/'card.vhd').write_text(original.replace(old,new))
  shutil.copy2(S/'third_party/Nitro_DarkSide/d2dabe/rtl/proc_bus_gba.vhd',d/'bus.vhd')
  shutil.copy2(S/'rtl/tb_nds_card_nand.vhd',d/'bench.vhd')
  command=['docker','run','--rm','--network','none','-v',str(d)+':/test','-w','/test','nds4mister-nvc-arm64:1.22.1','sh','-c','nvc --std=2008 -a bus.vhd card.vhd bench.vhd && nvc --std=2008 -e tb_nds_card_nand && nvc -H 256m --std=2008 -r tb_nds_card_nand --exit-severity=error']
  r=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=60)
  (E/('fault-'+name+'.log')).write_text(r.stdout)
  failures=[line for line in r.stdout.splitlines() if '** Failure:' in line]
  assert r.returncode!=0 and failures,(name,r.stdout[-1000:])
  results[name]=failures[-1]
(E/'FAULT_CONTROLS.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
