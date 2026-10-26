#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build only project-owned ARMv5 hooks; no cartridge bytes are included."""
import argparse
from pathlib import Path
import subprocess
import tempfile

SPECS = {
 'packed_video_color': (0x1fff600, []),
 'packed_chrono_video_color': (0x1fff600, []),
 'packed_nino_video_color': (0x1fff600, []),
 'packed_video_decode_j': (0x1fffa80, []),
 'packed_nino_video_decode_j': (0x1fffa80, []),
 'sj_queue_rebase': (0x1fffa00, []),
 'ff12_wait_before_header': (0x1fffcc0, []),
}
for game,table,decoder in [('ff12',0x27e0b40,0x1ff82f0),('sonic',0x27e0ae0,0x1ff8000)]:
 SPECS['packed_vx_'+game+'_color']=(0x1fff600,['-DOLD_COLOR_TABLE='+hex(table)])
 SPECS['packed_vx_'+game+'_decode']=(0x1fffa80,['-DORIGINAL_DECODER='+hex(decoder)])

# Portrait uses the same qualified VX converter with a different table address.
# Japanese Rev 1 moved the original decoder; retain its own fallback target.
SPECS.update({
 'packed_vx_portrait_color': (0x1fff600, ['-DOLD_COLOR_TABLE=0x027c1080']),
 'packed_vx_portrait_decode': (0x1fffa80, ['-DORIGINAL_DECODER=0x01ff81a0']),
 'packed_vx_portrait_jp1_decode': (0x1fffa80, ['-DORIGINAL_DECODER=0x01ff8180']),
})

SPECS.update({
 'packed_sj_jp_color': (0x1fff600, ['-DFILTER_ENTRY=0x0213aa14']),
 'sj_jp_queue_rebase': (0x1fffa00, ['-DQUEUE_RESUME=0x0208e068']),
 'ff12_eu_wait_before_header': (0x1fffcc0, ['-DWAIT_RESUME=0x02086640']),
 'ff12_jp_wait_before_header': (0x1fffcc0, ['-DWAIT_RESUME=0x02086738', '-DJAPANESE_PLAYER=1']),
 'packed_vx_ff12_jp_decode': (0x1fffa80, ['-DORIGINAL_DECODER=0x01ff8310']),
})
ALIASES = {'packed_sj_jp_color':'packed_video_color',
           'sj_jp_queue_rebase':'sj_queue_rebase',
           'ff12_eu_wait_before_header':'ff12_wait_before_header',
           'ff12_jp_wait_before_header':'ff12_wait_before_header'}

# Complete the existing asynchronous file read before inspecting its packet
# header. Faster decoding otherwise exposes a stale ping-pong buffer header.
for region,resume,reload in [('us',0x02089914,True),('eu',0x0208a68c,True),
                             ('jp',0x0208999c,True),('jp1',0x02082a38,False)]:
 name='portrait_'+region+'_wait_before_header'
 SPECS[name]=(0x1fffcc0,['-DWAIT_RESUME='+hex(resume)]+(['-DJAPANESE_PLAYER=1'] if reload else []))
 ALIASES[name]='ff12_wait_before_header'

def main():
 p=argparse.ArgumentParser();p.add_argument('--prefix',default='arm-linux-gnueabihf-');a=p.parse_args()
 root=Path(__file__).resolve().parent
 with tempfile.TemporaryDirectory() as temp:
  for name,(address,defines) in SPECS.items():
   source=ALIASES.get(name,name)
   if name.startswith('packed_vx_'):source='packed_vx_'+name.rsplit('_',1)[1]
   obj=Path(temp)/'hook.o';elf=Path(temp)/'hook.elf'
   subprocess.run([a.prefix+'gcc','-c','-march=armv5te','-marm','-mfloat-abi=soft',*defines,str(root/'guest'/(source+'.S')),'-o',str(obj)],check=True)
   subprocess.run([a.prefix+'ld','-Ttext='+hex(address),str(obj),'-o',str(elf)],check=True)
   subprocess.run([a.prefix+'objcopy','-O','binary',str(elf),str(root/'guest'/(name+'.bin'))],check=True)
if __name__=='__main__':main()
