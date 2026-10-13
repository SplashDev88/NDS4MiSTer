#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Compare every bus cycle and architectural retirement against the pre-refactor CPU.
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-block-load-equiv.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
reference="${REFERENCE_REVISION:-d3878fe89883ee95ebd0d9f6b156fe3d606352f7}"
cpu_rel=third_party/Nitro_DarkSide/d2dabe/rtl/nds_cpu9.vhd
git -C "$repo_dir" show "$reference:$cpu_rel" > "$test_tmp/reference.vhd"
python3 - "$repo_dir" "$test_tmp" <<'PYSCRIPT'
import os,re,sys
from pathlib import Path
repo,tmp=map(Path,sys.argv[1:])
s=(tmp/'reference.vhd').read_text().replace('nds_cpu9','nds_cpu9_reference')
if os.environ.get('EQUIV_NEGATIVE_CONTROL')=='1':
    anchor='load_result := gb_bus_din;'
    assert s.count(anchor)==1
    s=s.replace(anchor,'load_result := gb_bus_din xor x"00000001";')
(tmp/'reference.vhd').write_text(s)
for name in ['load_retire','load_base']:
    path=repo/f'rtl/tb_nds_cpu9_{name}.vhd'
    s=path.read_text().replace(f'tb_nds_cpu9_{name}',f'tb_block_equiv_{name}')
    s=s.replace('use work.pProc_bus_gba.all;','use work.pProc_bus_gba.all;\nuse work.pexport.all;')
    declarations="""
  signal ref_addr,ref_dout,ref_pc,actual_reg,ref_reg: std_logic_vector(31 downto 0);
  signal ref_ena,ref_code,ref_rnw,actual_export_done,ref_export_done: std_logic;
  signal ref_acc: std_logic_vector(1 downto 0);
  signal actual_export,ref_export: cpu_export_type:=export_init;
"""
    # Architecture-level begin follows the init function and memory declaration.
    pos=s.index('\nbegin\n')
    s=s[:pos]+declarations+s[pos:]
    match=re.search(r"  dut: entity work.nds_cpu9\b.*?cache_op_busy=>'0'\);",s,re.S)
    assert match,name
    actual=match.group().replace("is_simu=>'0'","is_simu=>'1'")
    actual=actual.replace('port map(', 'port map(cpu_export=>actual_export,cpu_export_done=>actual_export_done,\n      dbg_regsel=>to_unsigned(ticks mod 17,5),dbg_regval=>actual_reg,',1)
    ref=actual.replace('dut: entity work.nds_cpu9','reference: entity work.nds_cpu9_reference')
    for left,right in [('addr','ref_addr'),('dout','ref_dout'),('pc','ref_pc'),('ena','ref_ena'),('code','ref_code'),('rnw','ref_rnw'),('acc','ref_acc'),('actual_reg','ref_reg'),('actual_export','ref_export'),('actual_export_done','ref_export_done')]:
        ref=re.sub(r'=>'+left+r'\b','=>'+right,ref)
    checker="""
  process(clk) begin
    if falling_edge(clk) and reset='0' then
      assert addr=ref_addr and dout=ref_dout and ena=ref_ena and
             code=ref_code and rnw=ref_rnw and acc=ref_acc and pc=ref_pc
        report "cycle-equivalence bus mismatch" severity failure;
      assert actual_reg=ref_reg
        report "cycle-equivalence register mismatch" severity failure;
      assert actual_export_done=ref_export_done
        report "cycle-equivalence retirement mismatch" severity failure;
      if actual_export_done='1' then
        assert actual_export=ref_export
          report "architectural retirement state mismatch" severity failure;
      end if;
    end if;
  end process;
"""
    s=s[:match.start()]+actual+'\n'+ref+'\n'+checker+s[match.end():]
    (tmp/f'tb_{name}.vhd').write_text(s)
PYSCRIPT
run_tests() {
    local repo=$1 delay step dma irq name
    local p="$repo/third_party/Nitro_DarkSide/d2dabe/rtl"
    nvc --std=2008 -a "$p/export.vhd" "$p/proc_bus_gba.vhd" \
        "$p/reg_savestates.vhd" \
        reference.vhd "$p/nds_cpu9.vhd" tb_load_retire.vhd tb_load_base.vhd
    for name in load_retire load_base; do
        for delay in 1 3 11; do
            for step in 1 2 5; do
                for dma in false true; do
                    for irq in false true; do
                        echo "equivalence=$name delay=$delay step=$step dma=$dma irq=$irq"
                        nvc --std=2008 -e -gREAD_DELAY="$delay" -gSTEP_PERIOD="$step" \
                            -gDMA_OVERLAP="$dma" -gIRQ_OVERLAP="$irq" "tb_block_equiv_$name"
                        nvc --std=2008 -r "tb_block_equiv_$name" \
                            --ieee-warnings=off --exit-severity=error
                    done
                done
            done
        done
    done
}
if command -v nvc >/dev/null 2>&1; then
    cd "$test_tmp"
    run_tests "$repo_dir"
else
    docker run --rm --network none -v "$repo_dir:/workspace:ro" \
        -v "$test_tmp:/test" -w /test nds4mister-nvc-arm64:1.22.1 \
        bash -lc "set -euo pipefail; $(declare -f run_tests); run_tests /workspace"
fi
echo 'PASS: block-load refactor matches every bus cycle, register sample and retirement'
