# SPDX-License-Identifier: GPL-3.0-only
"""Execute ARM shim guards and fallback paths; requires Python unicorn."""
from pathlib import Path
import struct, random, json, sys, importlib.util, os, hashlib
from unicorn import Uc, UC_ARCH_ARM, UC_MODE_ARM, UC_HOOK_CODE
from unicorn.arm_const import *
R=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(R/'tools/standalone_host/fmv'))
from nsmb_runtime import BONE_READS
stub=BONE_READS
entry=0x02000d00
returns=[0x0212c9e4,0x0212c9f8,0x0212ca0c,0x0212ca34,0x0212ca48,0x0212ca5c]
prefix=bytes.fromhex('30402de904d04de20050a0e1030c85e2')
rng=random.Random(20261023)
cases=0
for lr in returns+[0x0212c9c0,0x0212c9d0,0x0212ca20,0x0212ca70,0x0212c9c4,0x02010000,0x0212c9bc]:
 for corrupt in [-1,0,4,8,12]:
  for trial in range(8):
   uc=Uc(UC_ARCH_ARM,UC_MODE_ARM);uc.mem_map(0x02000000,0x400000)
   uc.mem_write(entry,stub);live=bytearray(prefix)
   if corrupt>=0:live[corrupt]^=1
   uc.mem_write(0x0212c98c,bytes(live))
   obj=0x02200000;uc.mem_write(obj+0x58,struct.pack('<I',0x02210000))
   values=[obj,rng.getrandbits(32),rng.getrandbits(32)]+[rng.getrandbits(32) for _ in range(10)]
   regs=[UC_ARM_REG_R0,UC_ARM_REG_R1,UC_ARM_REG_R2,UC_ARM_REG_R3,UC_ARM_REG_R4,UC_ARM_REG_R5,UC_ARM_REG_R6,UC_ARM_REG_R7,UC_ARM_REG_R8,UC_ARM_REG_R9,UC_ARM_REG_R10,UC_ARM_REG_R11,UC_ARM_REG_R12]
   for reg,value in zip(regs,values):uc.reg_write(reg,value)
   uc.reg_write(UC_ARM_REG_SP,0x023ff000);uc.reg_write(UC_ARM_REG_LR,lr)
   stopped=[]
   def stop(vm,address,size,user):
    if address in [lr,0x02019740]:stopped.append(address);vm.emu_stop()
   uc.hook_add(UC_HOOK_CODE,stop);uc.emu_start(entry,0,count=400)
   skipped=lr in returns and corrupt<0
   assert stopped==[lr if skipped else 0x02019740],(lr,corrupt,stopped)
   assert uc.reg_read(UC_ARM_REG_R0)==(1 if skipped else 0x02210040)
   for i in [1,2,4,5,6,7,8,9,10,11]:assert uc.reg_read(regs[i])==values[i]
   assert uc.reg_read(UC_ARM_REG_SP)==0x023ff000 and uc.reg_read(UC_ARM_REG_LR)==lr
   cases+=1
print(f"PASS: {cases} ARM guard/fallback/register-preservation cases")
