-- SPDX-License-Identifier: GPL-3.0-or-later
-- Calendar snapshots do not stop the battery clock or disturb serial commands.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_checkpoint_rtc is
 generic(SECOND_CLOCKS : positive := 8192; SEED_PHASE : natural := 0);
end;
architecture sim of tb_nds_checkpoint_rtc is
 signal clk : std_logic := '0';signal reset : std_logic := '1';signal ce : std_logic := '1';
 signal seed_data,datetime,reference_date,snapshot : std_logic_vector(55 downto 0) := (others=>'0');
 signal seed_toggle,changed,reference_changed : std_logic := '0';
 signal request,ready,done,reference_done : std_logic := '0';
 signal fraction : unsigned(31 downto 0);
 signal q,reference_q : std_logic_vector(31 downto 0);
 signal bus7 : proc_bus_gb_type := ((others=>'0'),x"0000138",'1','0',ACCESS_16BIT,"0000",'0');
 signal samples,compared : natural := 0;
 subtype byte_t is std_logic_vector(7 downto 0);
 type bytes_t is array(natural range <>) of byte_t;
begin
 clk<=not clk after 5 ns;
 dut:entity work.nds_nitro_rtc generic map(CYCLES_PER_SECOND=>SECOND_CLOCKS,EXPERIMENTAL_CHECKPOINT=>true)
 port map(clk=>clk,ce=>ce,reset=>reset,fw_boot=>'1',rtc_seed=>seed_data,rtc_seed_toggle=>seed_toggle,
  rtc_datetime=>datetime,date_written=>changed,bus7=>bus7,wired_out7=>q,wired_done7=>done,
  checkpoint_request=>request,checkpoint_ready=>ready,checkpoint_datetime=>snapshot,checkpoint_subsecond=>fraction);
 reference_rtc:entity work.nds_nitro_rtc_reference generic map(CYCLES_PER_SECOND=>SECOND_CLOCKS)
 port map(clk=>clk,ce=>ce,reset=>reset,fw_boot=>'1',rtc_seed=>seed_data,rtc_seed_toggle=>seed_toggle,
  rtc_datetime=>reference_date,date_written=>reference_changed,bus7=>bus7,wired_out7=>reference_q,wired_done7=>reference_done);
 comparison:process
 begin
  wait until clk'event;wait for 1 ns;
  assert datetime=reference_date and changed=reference_changed and q=reference_q and done=reference_done
   report "RTC checkpoint changed live clock/serial behavior" severity failure;
  compared<=compared+1;
  if reset='1' or request='0' or bus7.ena='1' then
   assert ready='0' report "RTC snapshot valid during reset/cancel/bus admission" severity failure;
  end if;
 end process;
 coherence:process
  alias reference_fraction is << signal .tb_nds_checkpoint_rtc.reference_rtc.sec_div : integer range 0 to SECOND_CLOCKS-1 >>;
  alias seed_pipe is << signal .tb_nds_checkpoint_rtc.dut.seed_toggle_sync : std_logic_vector(2 downto 0) >>;
  alias seed_seen is << signal .tb_nds_checkpoint_rtc.dut.seed_seen : std_logic >>;
  variable was_ready : std_logic;
  variable old_date,saved_date : std_logic_vector(55 downto 0);
  variable old_fraction : natural;
  variable saved_fraction : unsigned(31 downto 0);
 begin
  wait until rising_edge(clk);was_ready:=ready;old_date:=reference_date;old_fraction:=reference_fraction;
  saved_date:=snapshot;saved_fraction:=fraction;wait for 1 ns;
  if ready='1' then
   assert seed_pipe=(seed_seen&seed_seen&seed_seen) report "RTC snapshot accepted an undrained seed" severity failure;
   if was_ready='0' then
    assert snapshot=old_date and fraction=old_fraction report "RTC calendar/subsecond snapshot was torn" severity failure;
    samples<=samples+1;
   else
    assert snapshot=saved_date and fraction=saved_fraction report "RTC snapshot changed while valid" severity failure;
   end if;
  end if;
 end process;
 stimulus:process
  variable value : byte_t;
  variable saved_date : std_logic_vector(55 downto 0);
  variable saved_fraction : unsigned(31 downto 0);
  variable old_changed : std_logic;
  procedure step(n:natural:=1) is
  begin for k in 1 to n loop wait until rising_edge(clk);wait for 2 ns;end loop;end;
  procedure await_snapshot is
  begin
   for k in 1 to 20 loop exit when ready='1';step;end loop;
   assert ready='1' report "RTC snapshot did not qualify" severity failure;
  end;
  procedure poke(v:byte_t) is
  begin
   bus7.Din<=x"000000"&v;bus7.ena<='1';bus7.rnw<='0';bus7.bEna<="0001";
   wait for 1 ns;assert ready='0' report "RTC write did not revoke snapshot" severity failure;
   step;bus7.ena<='0';bus7.rnw<='1';step;
  end;
  procedure begin_serial is begin poke(x"10");poke(x"16");end;
  procedure send_byte(v:byte_t) is
   variable bits : byte_t;
  begin
   for b in 0 to 7 loop
    bits:=x"16";bits(0):=v(b);poke(bits);bits(1):='0';poke(bits);
    -- Pause after any partial command/data bit, then continue without reset.
    request<='1';await_snapshot;step(2);request<='0';step;
   end loop;
  end;
  procedure receive_byte(variable v:out byte_t) is
  begin
   for b in 0 to 7 loop
    poke(x"06");poke(x"04");v(b):=q(0);
    request<='1';await_snapshot;request<='0';step;
   end loop;
  end;
  procedure seed(v:std_logic_vector(55 downto 0)) is
  begin seed_data<=v;step(2);seed_toggle<=not seed_toggle;step(8);end;
 begin
  step(4);reset<='0';step(2);
  request<='1';await_snapshot;
  assert snapshot(47 downto 0)=x"000006010100" report "offline fallback date changed" severity failure;
  seed(x"59592304290224");await_snapshot;
  saved_date:=snapshot;saved_fraction:=fraction;
  -- Read snapshot words far apart across real calendar rollover.
  step(SECOND_CLOCKS*3+9);
  assert snapshot=saved_date and fraction=saved_fraction and datetime/=snapshot
   report "RTC hold stopped real time or changed snapshot" severity failure;
  assert datetime=x"02000005010324" report "live RTC elapsed seconds/rollover incorrect" severity failure;
  request<='0';step;request<='1';await_snapshot;
  assert snapshot/=saved_date report "new RTC request reused stale timestamp" severity failure;
  -- Host seeding at every acquisition phase and after an established sample.
  for n in 0 to 5 loop
   request<='0';step;seed_data<=x"00150002050726";step(2);request<='1';
   step((SEED_PHASE+n) mod 7);seed_toggle<=not seed_toggle;
   step(2);assert ready='0' report "RTC seed crossing did not revoke old sample" severity failure;
   step(8);await_snapshot;assert snapshot=x"00150002050726" report "RTC seed context was not resampled" severity failure;
   step(17);
  end loop;
  -- Serial status/time command, held at every bit in each direction.
  request<='0';step;seed(x"45301204290224");old_changed:=changed;
  begin_serial;send_byte(x"66");send_byte(x"63");send_byte(x"58");send_byte(x"57");poke(x"10");
  assert changed/=old_changed and datetime=x"57582304290224" report "RTC partial time write lost" severity failure;
  begin_serial;send_byte(x"67");receive_byte(value);assert value=x"63" severity failure;
  receive_byte(value);assert value=x"58" severity failure;
  receive_byte(value);assert value=x"57" severity failure;poke(x"10");
  -- Guest reset keeps the running calendar, invalidates the sample, and still
  -- permits the existing host seed path while reset is held.
  request<='1';await_snapshot;reset<='1';step(3);seed(x"00000006010100");
  assert ready='0' and datetime=x"00000006010100" report "RTC reset/seed semantics changed" severity failure;
  reset<='0';await_snapshot;
  ce<='0';saved_date:=datetime;step(SECOND_CLOCKS+4);assert datetime=saved_date report "RTC existing CE contract changed" severity failure;
  ce<='1';step(SECOND_CLOCKS+1);assert datetime/=saved_date severity failure;
  assert samples>=74 report "RTC snapshot checks were vacuous: "&integer'image(samples) severity failure;
  report "CHECKPOINT_RTC_PASS second_clocks="&integer'image(SECOND_CLOCKS)&" seed_phase="&integer'image(SEED_PHASE)&
   " snapshots="&integer'image(samples)&" compared_phases="&integer'image(compared);
  stop;wait;
 end process;
 process begin wait for 10 ms;assert false report "RTC checkpoint watchdog" severity failure;end process;
end;
