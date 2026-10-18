-- SPDX-License-Identifier: GPL-3.0-or-later
-- Qualify the final timestamp with the actual running RTC. Device and host
-- owners are controlled fixtures, not a claim of full console qualification.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_checkpoint_console_guard is end;
architecture sim of tb_nds_checkpoint_console_guard is
 signal clk : std_logic := '0';signal reset : std_logic := '1';
 signal hold,cpus,ext_seen,ext_paused,island : std_logic := '0';
 signal local_ready : std_logic_vector(13 downto 0) := (others=>'0');
 signal seen,paused,idle,sample,rtc_ready,done,changed : std_logic;
 signal date,snapshot : std_logic_vector(55 downto 0);
 signal fraction : unsigned(31 downto 0);
 signal q : std_logic_vector(31 downto 0);
 signal bus7 : proc_bus_gb_type := ((others=>'0'),x"0000138",'1','0',ACCESS_16BIT,"0000",'0');
begin
 clk<=not clk after 5 ns;
 guard:entity work.nds_checkpoint_console_guard
 port map(clk=>clk,reset=>reset,hold=>hold,cpus_observed=>cpus,local_ready=>local_ready,
  island_idle_async=>island,external_seen=>ext_seen,external_paused=>ext_paused,
  rtc_ready=>rtc_ready,local_seen=>seen,local_paused=>paused,local_idle=>idle,rtc_request=>sample);
 rtc:entity work.nds_nitro_rtc generic map(CYCLES_PER_SECOND=>512,EXPERIMENTAL_CHECKPOINT=>true)
 port map(clk=>clk,ce=>'1',reset=>reset,fw_boot=>'1',rtc_seed=>(others=>'0'),rtc_seed_toggle=>'0',
  rtc_datetime=>date,date_written=>changed,bus7=>bus7,wired_out7=>q,wired_done7=>done,
  checkpoint_request=>sample,checkpoint_ready=>rtc_ready,checkpoint_datetime=>snapshot,checkpoint_subsecond=>fraction);
 process
  variable earlier_date : std_logic_vector(55 downto 0);
  variable earlier_fraction : unsigned(31 downto 0);
  variable samples : natural := 0;
  procedure step(n:natural:=1) is begin
   for k in 1 to n loop wait until rising_edge(clk);wait for 2 ns;end loop;
  end;
  procedure assert_blocked is begin
   step(5);assert paused='0' and sample='0' report "RTC sampled before all owners settled" severity failure;
  end;
  procedure acquire is begin
   for k in 1 to 20 loop step;exit when paused='1';end loop;
   assert paused='1' and sample='1' and rtc_ready='1' report "final timestamp failed to qualify" severity failure;
   samples:=samples+1;
  end;
 begin
  step(4);reset<='0';hold<='1';assert_blocked;
  assert seen='1' report "local receipt waited for device completion" severity failure;
  local_ready<=(others=>'1');island<='1';ext_seen<='1';ext_paused<='1';assert_blocked;
  cpus<='1';ext_paused<='0';assert_blocked;
  ext_paused<='1';ext_seen<='0';assert_blocked;
  ext_seen<='1';local_ready(0)<='0';assert_blocked;
  for owner in local_ready'range loop
   local_ready<=(others=>'1');local_ready(owner)<='0';assert_blocked;
  end loop;
  local_ready<=(others=>'1');island<='0';assert_blocked;
  island<='1';step(2);
  assert sample='0' report "RTC skipped crossing quiet interval" severity failure;
  acquire;earlier_date:=snapshot;earlier_fraction:=fraction;
  -- Live clock continues for several seconds while the sampled word is held.
  step(1539);
  assert snapshot=earlier_date and fraction=earlier_fraction and date/=snapshot
   report "timestamp moved or live RTC stopped at common hold" severity failure;
  ext_paused<='0';wait for 1 ns;
  assert paused='0' and sample='0' report "external owner loss retained timestamp permit" severity failure;
  step;ext_paused<='1';step;
  assert sample='0' report "new acquisition reused an old RTC request" severity failure;
  acquire;assert snapshot/=earlier_date report "final sample did not advance after new boundary" severity failure;
  -- Accepted guest IO revokes the RTC's own sample before any shared read
  -- can be valid, even if the other owner observations lag that admission.
  bus7.ena<='1';wait for 1 ns;
  assert paused='0' report "RTC bus admission retained owner acknowledgement" severity failure;
  step;bus7.ena<='0';acquire;
  hold<='0';wait for 1 ns;
  assert paused='0' and sample='0' report "cancel retained final timestamp" severity failure;
  step;assert seen='0' report "local receipt failed to release" severity failure;
  hold<='1';reset<='1';step(4);
  assert paused='0' and seen='0' and sample='0' severity failure;
  reset<='0';acquire;
  report "CHECKPOINT_CONSOLE_GUARD_PASS: every local owner, CPU/host receipt, late timestamp, RTC admission, cancel/reset; samples="&integer'image(samples);
  stop;wait;
 end process;
 process begin wait for 1 ms;assert false report "console guard watchdog" severity failure;end process;
end;
