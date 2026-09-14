#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise the actual OSD direction expression and legacy saved values."""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
emu = (root / 'fpga/mister_nitro_console_island/NDS4MiSTer.sv').read_text()
top = (root / 'fpga/mister_nitro_console_island/sys/sys_top.v').read_text()
assert '"O[12:11],Video Rotation,Off,90 CCW,90 CW;"' in emu
assert 'assign VIDEO_ROTATION = rotation_select;' in emu
assert '.TILE_ROWS(TATE_TILE_ROWS),.CCW_ONLY(0)' in top
assert 'nds_tate_input ' not in emu, 'Physical monitor rotation retains native controls'
expression = re.search(r'wire\s+\[1:0\]\s+rotation_select\s*=\s*(.*?);', emu, re.S)[1]
bench = '''
`timescale 1ns/1ps
module tb;
reg [127:0] status=0;
wire [1:0] rotation_select = EXPRESSION;
integer option_value, other_bit, cases=0;
reg [1:0] expected;
initial begin
  for(option_value=0; option_value<4; option_value=option_value+1) begin
    // OSD values 0/1 preserve the released Off/CCW config. Value 2 adds CW;
    // the unused fourth option must fail closed to Off.
    case(option_value) 1:expected=2; 2:expected=1; default:expected=0; endcase
    for(other_bit=0; other_bit<128; other_bit=other_bit+1) begin
      status=0; status[12:11]=option_value;
      if(other_bit!=11 && other_bit!=12) status[other_bit]=1;
      #1;
      if(rotation_select!==expected)
        $fatal(1,"OSD direction mismatch option=%0d other_bit=%0d",option_value,other_bit);
      cases=cases+1;
    end
  end
  $display("PASS OSD direction map, legacy config, unrelated settings: %0d cases",cases);
  $finish;
end
endmodule
'''
with tempfile.TemporaryDirectory(prefix='nds-tate-menu-') as temp:
    temp = Path(temp)
    for name, actual_expression, bad in (
        ('production', expression, False),
        ('old-ccw-only', "status[11] ? 2'd2 : 2'd0", True),
        ('swapped-directions', '{status[12],status[11]}', True),
    ):
        source = temp / (name + '.sv')
        binary = temp / name
        source.write_text(bench.replace('EXPRESSION', actual_expression))
        subprocess.run(['iverilog', '-g2012', '-s', 'tb', '-o', str(binary), str(source)], check=True)
        result = subprocess.run(['vvp', str(binary)], text=True, capture_output=True)
        if bad:
            assert result.returncode != 0 and 'OSD direction mismatch' in result.stdout, result
            print('PASS negative control: ' + name)
        else:
            result.check_returncode()
            assert 'PASS OSD direction map' in result.stdout
            print(result.stdout.strip())
