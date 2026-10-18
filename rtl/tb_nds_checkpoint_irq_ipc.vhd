-- SPDX-License-Identifier: GPL-3.0-or-later
-- Live IRQ/IPC retirement, including held level IRQs and nonempty FIFOs.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

entity tb_nds_checkpoint_irq_ipc is
   generic(SEED : positive := 1; RANDOM_CYCLES : positive := 20000);
end;
architecture sim of tb_nds_checkpoint_irq_ipc is
   constant EMPTY_BUS : proc_bus_gb_type := ((others=>'0'),(others=>'0'),'1','0',ACCESS_32BIT,"1111",'0');
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal ce : std_logic_vector(1 downto 0) := "11";
   type buses is array(0 to 1) of proc_bus_gb_type;
   subtype word is std_logic_vector(31 downto 0);
   type words is array(natural range <>) of std_logic_vector(31 downto 0);
   signal io : buses := (others=>EMPTY_BUS);
   signal ext : words(0 to 1) := (others=>(others=>'0'));
   signal irq_in : words(0 to 1);
   signal ime,ie,flags,refime,refie,refflags : words(0 to 1);
   signal irq_data,refirq_data,ipc_data,refipc_data : words(0 to 1);
   signal irq,unhalt,irq_idle,refirq,refunhalt,irq_done,refirq_done,ipc_done,refipc_done : std_logic_vector(1 downto 0);
   signal pulse,refpulse : std_logic_vector(5 downto 0);
   signal ipc_dbg,refipc_dbg : std_logic_vector(31 downto 0);
   signal ipc_idle : std_logic;
   signal compared : natural := 0;
begin
   clk <= not clk after 5 ns;
   irq_in(0) <= ext(0) or word'(16=>pulse(0),17=>pulse(1),18=>pulse(2),others=>'0');
   irq_in(1) <= ext(1) or word'(16=>pulse(3),17=>pulse(4),18=>pulse(5),others=>'0');
   gi : for i in 0 to 1 generate
      dut : entity work.nds_irq port map(clk=>clk,ce=>ce(i),reset=>reset,gb_bus=>io(i),
         wired_out=>irq_data(i),wired_done=>irq_done(i),irq_in=>irq_in(i),cpu_irq=>irq(i),cpu_unhalt=>unhalt(i),
         dbg_ime=>ime(i),dbg_ie=>ie(i),dbg_if=>flags(i),checkpoint_idle=>irq_idle(i));
      reference_irq : entity work.nds_irq_reference port map(clk=>clk,ce=>ce(i),reset=>reset,gb_bus=>io(i),
         wired_out=>refirq_data(i),wired_done=>refirq_done(i),irq_in=>irq_in(i),cpu_irq=>refirq(i),cpu_unhalt=>refunhalt(i),
         dbg_ime=>refime(i),dbg_ie=>refie(i),dbg_if=>refflags(i));
   end generate;
   ipc : entity work.nds_ipc port map(clk=>clk,reset=>reset,
      bus7=>io(0),wired_out7=>ipc_data(0),wired_done7=>ipc_done(0),
      irq7_sync=>pulse(0),irq7_sendempty=>pulse(1),irq7_recv=>pulse(2),
      bus9=>io(1),wired_out9=>ipc_data(1),wired_done9=>ipc_done(1),
      irq9_sync=>pulse(3),irq9_sendempty=>pulse(4),irq9_recv=>pulse(5),dbg_ipc=>ipc_dbg,checkpoint_idle=>ipc_idle);
   reference_ipc : entity work.nds_ipc_reference port map(clk=>clk,reset=>reset,
      bus7=>io(0),wired_out7=>refipc_data(0),wired_done7=>refipc_done(0),
      irq7_sync=>refpulse(0),irq7_sendempty=>refpulse(1),irq7_recv=>refpulse(2),
      bus9=>io(1),wired_out9=>refipc_data(1),wired_done9=>refipc_done(1),
      irq9_sync=>refpulse(3),irq9_sendempty=>refpulse(4),irq9_recv=>refpulse(5),dbg_ipc=>refipc_dbg);

   -- Both clock phases compare every original output to the pre-change RTL.
   comparison : process
   begin
      wait until clk'event;wait for 1 ns;
      assert irq_data=refirq_data and irq_done=refirq_done and ime=refime and ie=refie and
         flags=refflags and irq=refirq and unhalt=refunhalt and ipc_data=refipc_data and
         ipc_done=refipc_done and pulse=refpulse and ipc_dbg=refipc_dbg
         report "IRQ/IPC behavior differs from baseline" severity failure;
      compared<=compared+1;
      if reset='1' then
         assert irq_idle="00" and ipc_idle='0' report "IRQ/IPC reset falsely idle" severity failure;
      end if;
      if io(0).ena='1' or io(1).ena='1' then
         assert ipc_idle='0' report "IPC admission falsely idle" severity failure;
      end if;
      if pulse/="000000" then
         assert ipc_idle='0' report "IPC emitted pulse falsely idle" severity failure;
      end if;
   end process;

   -- Independent temporal contract: with no new admission, an idle owner
   -- must not change its state/output at the next edge. This detects pending
   -- IF capture, IE/IME output latency and IPC IRQ-enable history, rather
   -- than duplicating the observer's boolean expression in a scoreboard.
   fixed_point : process
      variable q : std_logic_vector(1 downto 0);
      variable qipc : std_logic;
      variable saved_flags,saved_ie,saved_ime : words(0 to 1);
      variable saved_irq,saved_unhalt : std_logic_vector(1 downto 0);
      variable saved_ipc : std_logic_vector(31 downto 0);
   begin
      wait until rising_edge(clk);
      q:=irq_idle;qipc:=ipc_idle;saved_flags:=flags;saved_ie:=ie;saved_ime:=ime;
      saved_irq:=irq;saved_unhalt:=unhalt;saved_ipc:=ipc_dbg;
      wait for 1 ns;
      for i in 0 to 1 loop
         if q(i)='1' then
            assert flags(i)=saved_flags(i) and ie(i)=saved_ie(i) and ime(i)=saved_ime(i) and
               irq(i)=saved_irq(i) and unhalt(i)=saved_unhalt(i)
               report "IRQ idle preceded state/output retirement" severity failure;
         end if;
      end loop;
      if qipc='1' then
         assert ipc_dbg=saved_ipc and pulse="000000"
            report "IPC idle preceded edge-history retirement" severity failure;
      end if;
   end process;

   stimulus : process
      variable rng : unsigned(31 downto 0) := to_unsigned(SEED,32);
      variable v : proc_bus_gb_type;
      variable mask : std_logic_vector(31 downto 0);
      procedure randomize is
      begin rng:=rng(30 downto 0)&(rng(31) xor rng(21) xor rng(1) xor rng(0));end;
      procedure step(n : positive := 1) is
      begin for k in 1 to n loop wait until rising_edge(clk);wait for 2 ns;end loop;end;
      procedure write_reg(side : natural;a,d : std_logic_vector(31 downto 0);be : std_logic_vector(3 downto 0) := "1111") is
      begin
         io(side).Adr<=a(27 downto 0);io(side).Din<=d;io(side).rnw<='0';io(side).bEna<=be;io(side).ena<='1';
         wait for 1 ns;assert irq_idle(side)='0' and ipc_idle='0' report "fresh bus admission falsely idle" severity failure;
         step;io(side).ena<='0';wait for 1 ns;
      end;
      procedure settle is
      begin
         ce<="11";io(0).ena<='0';io(1).ena<='0';step(5);
         assert irq_idle="11" and ipc_idle='1' report "IRQ/IPC never became idle" severity failure;
      end;
      procedure clear is
      begin
         reset<='1';io<=(others=>EMPTY_BUS);io(0).rst<='1';io(1).rst<='1';ext<=(others=>(others=>'0'));ce<="11";
         step(3);reset<='0';io(0).rst<='0';io(1).rst<='0';settle;
      end;
      procedure pop(side : natural;expected : std_logic_vector(31 downto 0)) is
      begin
         io(side).Adr<=x"0100000";io(side).rnw<='1';io(side).ena<='1';wait for 1 ns;
         if side=0 then assert ipc_data(side)=expected report "ARM7 queued message changed" severity failure;end if;
         step;io(side).ena<='0';wait for 1 ns;
         if side=1 then assert ipc_data(side)=expected report "ARM9 queued message changed" severity failure;end if;
      end;
   begin
      clear;
      for side in 0 to 1 loop
         write_reg(side,x"00000210",x"FFFFFFFF");write_reg(side,x"00000208",x"FFFFFFFF");settle;
         assert ime(side)=x"00000001" report "IME writable mask changed" severity failure;
         -- Every source bit must reach IF, even with IME disabled or CPU CE stopped.
         for bitno in 0 to 31 loop
            mask:=(others=>'0');mask(bitno):='1';
            ext(side)<=mask;wait for 1 ns;
            assert irq_idle(side)='0' report "new IRQ bit falsely settled" severity failure;
            step;assert (flags(side) and mask)=mask report "IRQ pulse lost" severity failure;
            -- An asserted source already latched in IF is a valid fixed point.
            settle;assert irq(side)='1' and unhalt(side)='1' report "pending IRQ delivery changed" severity failure;
            -- Acknowledge simultaneous with an assertion: source wins.
            write_reg(side,x"00000214",mask);assert (flags(side) and mask)=mask report "simultaneous IF acknowledge lost source" severity failure;
            ext(side)<=(others=>'0');write_reg(side,x"00000214",mask);settle;
            assert (flags(side) and mask)=x"00000000" report "IF acknowledge failed" severity failure;
         end loop;
         ext(side)<=x"00000008";step;ext(side)<=(others=>'0');settle;
         write_reg(side,x"00000208",x"00000000","0001");wait until falling_edge(clk);wait for 1 ns;
         assert irq_idle(side)='0' report "IME output latency falsely idle" severity failure;
         step;assert irq(side)='0' and unhalt(side)='1' report "IME changed HALT wake semantics" severity failure;
         write_reg(side,x"00000210",x"00000000");wait until falling_edge(clk);wait for 1 ns;
         assert irq_idle(side)='0' report "IE output latency falsely idle" severity failure;
         settle;assert unhalt(side)='0' severity failure;
         ce(side)<='0';ext(side)<=x"80000000";step(8);
         assert irq_idle(side)='0' and flags(side)(31)='0' report "CE-stalled IRQ falsely captured" severity failure;
         ce(side)<='1';step;ext(side)<=(others=>'0');settle;
         assert flags(side)(31)='1' report "CE-resumed IRQ lost" severity failure;
      end loop;
      clear;
      -- Queue words in both directions before enabling receive IRQs.
      write_reg(0,x"00000184",x"00008000");write_reg(1,x"00000184",x"00008000");
      for k in 0 to 15 loop
         write_reg(0,x"00000188",std_logic_vector(to_unsigned(16#1000#+k,32)));
         write_reg(1,x"00000188",std_logic_vector(to_unsigned(16#2000#+k,32)));
      end loop;
      settle;
      assert ipc_dbg(4 downto 0)="10000" and ipc_dbg(12 downto 8)="10000" report "full queued messages lost" severity failure;
      -- Stable full queues must remain eligible; no flushing or fake pops.
      step(64);assert ipc_idle='1' severity failure;
      write_reg(0,x"00000184",x"00008404");wait until falling_edge(clk);wait for 1 ns;
      assert ipc_idle='0' report "IPC enabled edge falsely idle" severity failure;
      step;assert pulse(2)='1' report "ARM7 delayed receive IRQ lost" severity failure;settle;
      write_reg(1,x"00000184",x"00008404");step;assert pulse(5)='1' report "ARM9 delayed receive IRQ lost" severity failure;settle;
      -- Pop eight, wrap both write pointers, and preserve FIFO order.
      for k in 0 to 7 loop
         pop(0,std_logic_vector(to_unsigned(16#2000#+k,32)));pop(1,std_logic_vector(to_unsigned(16#1000#+k,32)));
      end loop;
      for k in 16 to 23 loop
         write_reg(0,x"00000188",std_logic_vector(to_unsigned(16#1000#+k,32)));
         write_reg(1,x"00000188",std_logic_vector(to_unsigned(16#2000#+k,32)));
      end loop;
      settle;
      for k in 8 to 23 loop
         pop(0,std_logic_vector(to_unsigned(16#2000#+k,32)));pop(1,std_logic_vector(to_unsigned(16#1000#+k,32)));
      end loop;
      settle;
      assert flags(0)(18 downto 17)="11" and flags(1)(18 downto 17)="11" report "IPC events not latched in IF" severity failure;
      pop(0,x"00002017");pop(1,x"00001017");settle;
      assert ipc_dbg(19 downto 18)="11" report "empty receive error/last value lost" severity failure;
      write_reg(0,x"00000184",x"0000C404");write_reg(1,x"00000184",x"0000C404");settle;
      assert ipc_dbg(19 downto 18)="00" report "FIFO error acknowledgement changed" severity failure;
      write_reg(0,x"00000180",x"00004A00");write_reg(1,x"00000180",x"00006B00");settle;
      assert flags(0)(16)='1' report "IPCSYNC event lost" severity failure;
      write_reg(0,x"00000180",x"00006C00");settle;
      assert flags(1)(16)='1' report "reverse IPCSYNC event lost" severity failure;

      -- Random bus traffic, level/pulse sources, byte enables, CE and resets.
      -- Comparison is to an immutable pre-observer source revision.
      for cycle in 1 to RANDOM_CYCLES loop
         randomize;
         if cycle mod 521=0 then clear;end if;
         for side in 0 to 1 loop
            randomize;v:=EMPTY_BUS;v.ena:=rng(0);v.rnw:=rng(1);v.bEna:=std_logic_vector(rng(5 downto 2));
            case to_integer(rng(8 downto 6)) is
               when 0=>v.Adr:=x"0000208";
               when 1=>v.Adr:=x"0000210";
               when 2=>v.Adr:=x"0000214";
               when 3=>v.Adr:=x"0000180";
               when 4=>v.Adr:=x"0000184";
               when 5=>v.Adr:=x"0000188";
               when 6=>v.Adr:=x"0100000";
               when others=>v.Adr:=x"0000990";
            end case;
            randomize;v.Din:=std_logic_vector(rng);io(side)<=v;
            ce(side)<=rng(3) or rng(4);ext(side)<=std_logic_vector(rotate_left(rng,side*7));
         end loop;
         step;
         if cycle mod 113=0 then settle;end if;
      end loop;
      settle;
      report "CHECKPOINT_IRQ_IPC_PASS seed="&integer'image(SEED)&" compared_phases="&integer'image(compared)&
         " both CPUs/all IRQ bits, level IF, W1C, IE/IME latency, full/wrapped FIFOs, late IRQs, random traffic";
      stop;wait;
   end process;
   process begin wait for 20 ms;assert false report "IRQ/IPC watchdog" severity failure;end process;
end;
