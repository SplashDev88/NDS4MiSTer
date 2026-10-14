#!/usr/bin/env python3
"""Compare extracted VRAM arbiter RTL across every binary mask and start index."""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('--reference-revision', required=True)
ap.add_argument('--output', type=Path, required=True)
ap.add_argument('--mutant', action='store_true')
args = ap.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
relative = 'rtl/nds_nitro_vram.vhd'
sources = [subprocess.check_output(['git', '-C', str(ROOT), 'show',
                                  args.reference_revision + ':' + relative], text=True),
           (ROOT / relative).read_text()]
units = []
for side, source in enumerate(sources):
    processes = '\n'.join(re.search(r'   ' + name + r' : process \(all\).*?end process;',
                                    source, re.S)[0] for name in ['prpick', 'pad_pick'])
    if side == 1 and args.mutant:
        assert processes.count('i >= rr_pri') == 1
        processes = processes.replace('i >= rr_pri', 'i > rr_pri')
    units.append('''library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
entity arbiter_SIDE is
  port(requests, valids: in std_logic_vector(7 downto 0);
       todos: in std_logic_vector(31 downto 0);
       start: in integer range 0 to 7;
       result: out std_logic_vector(11 downto 0));
end entity;
architecture test of arbiter_SIDE is
  constant RQ_DEPTH: integer := 8;
  constant BANK_A: integer := 0;
  constant BANK_D: integer := 3;
  type entry_t is record
    valid: std_logic;
    ad_todo: std_logic_vector(0 to 3);
  end record;
  type queue_t is array(0 to 7) of entry_t;
  signal rq: queue_t;
  signal rreq_vec: std_logic_vector(7 downto 0);
  signal rr_pri, rq_head, rpick, ad_scan: integer range 0 to 7;
  signal rpick_valid, ad_armed: std_logic;
  signal ad_hit: std_logic_vector(0 to 3);
begin
  rreq_vec <= requests;
  rr_pri <= start;
  rq_head <= start;
  g: for i in 0 to 7 generate
    rq(i).valid <= valids(i);
    rq(i).ad_todo <= todos(4*i+3 downto 4*i);
  end generate;
  result <= std_logic_vector(to_unsigned(rpick,3)) & rpick_valid &
            std_logic_vector(to_unsigned(ad_scan,3)) & ad_hit & ad_armed;
PROCESSES
end architecture;
'''.replace('SIDE', str(side)).replace('PROCESSES', processes))
bench = '''library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
entity tb_arbiters is end entity;
architecture test of tb_arbiters is
  signal requests, valids: std_logic_vector(7 downto 0) := (others=>'0');
  signal todos: std_logic_vector(31 downto 0) := (others=>'0');
  signal start: integer range 0 to 7 := 0;
  signal actual, expected: std_logic_vector(11 downto 0);
begin
  ref: entity work.arbiter_0 port map(requests,valids,todos,start,expected);
  dut: entity work.arbiter_1 port map(requests,valids,todos,start,actual);
  process
    variable bits: std_logic_vector(7 downto 0);
    variable checks: natural := 0;
  begin
    for head in 0 to 7 loop
      for mask in 0 to 255 loop
        for pattern in 0 to 15 loop
          for validity in 0 to 3 loop
            start <= head;
            bits := std_logic_vector(to_unsigned(mask,8));
            requests <= bits;
            case validity is
              when 0 => valids <= (others=>'1');
              when 1 => valids <= bits;
              when 2 => valids <= not bits;
              when others => valids <= (others=>'0');
            end case;
            for i in 0 to 7 loop
              todos(4*i+3 downto 4*i) <= (others=>'0');
              if bits(i)='1' and pattern > 0 then
                todos(4*i+3 downto 4*i) <=
                  std_logic_vector(to_unsigned(1+((pattern-1+i) mod 15),4));
              end if;
            end loop;
            wait for 1 ns;
            assert actual=expected report "arbiter mismatch: head=" & integer'image(head) &
              " mask=" & integer'image(mask) & " pattern=" & integer'image(pattern) &
              " validity=" & integer'image(validity) severity failure;
            checks := checks+1;
          end loop;
        end loop;
      end loop;
    end loop;
    report "PASS: extracted arbiter cases=" & integer'image(checks);
    stop;
    wait;
  end process;
end architecture;
'''
(out / 'arbiters.vhd').write_text('\n'.join(units) + bench)
command = ['docker', 'run', '--rm', '--network', 'none', '-v', str(out)+':/test',
           '-w', '/test', 'nds4mister-nvc-arm64:1.22.1', 'bash', '-lc',
           'set -e; nvc --std=2008 -a arbiters.vhd; nvc --std=2008 -e tb_arbiters; '
           'nvc --std=2008 -r tb_arbiters --ieee-warnings=off --exit-severity=error']
run = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(out / 'test.log').write_text(run.stdout)
passed = run.returncode == 0 and 'PASS: extracted arbiter cases=131072' in run.stdout
if args.mutant:
    passed = run.returncode != 0 and 'arbiter mismatch:' in run.stdout
result = dict(reference_revision=args.reference_revision, mutant=args.mutant,
              reference_sha256=hashlib.sha256(sources[0].encode()).hexdigest(),
              candidate_sha256=hashlib.sha256(sources[1].encode()).hexdigest(),
              returncode=run.returncode, passed=passed, log=run.stdout,
              scope='Both extracted processes; all 256 binary masks and 8 starting positions; '
                    '16 word patterns and 4 valid-bit arrangements. No added product probes.')
(out / 'results.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps(result, indent=2))
raise SystemExit(0 if passed else 1)
