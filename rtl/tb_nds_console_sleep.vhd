-- SPDX-License-Identifier: GPL-3.0-or-later
-- Authored ARM9 counter program and actual HALTCNT owner. A closed lid alone
-- does not pause execution; software's Sleep write must do so. Outstanding
-- responses are allowed to finish, with no skipped or duplicated stores.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_console_sleep is
  generic(READ_DELAY:positive:=1; SLEEP_PHASE:natural:=0);
end;
architecture sim of tb_nds_console_sleep is
  signal clk:std_logic:='0'; signal reset:std_logic:='1';
  signal ss,bus7:proc_bus_gb_type:=((others=>'0'),(others=>'0'),'0','0',"10","1111",'0');
  signal addr,din,dout,pc:std_logic_vector(31 downto 0);
  signal ena,done,code,rnw:std_logic:='0';
  signal acc:std_logic_vector(1 downto 0);
  signal sleeping,sleep_meta,sleep9,wake,halt:std_logic:='0';
  signal stores:natural:=0;
  function ins(a:std_logic_vector(31 downto 0)) return std_logic_vector is
  begin
    case a is
      when x"02000000"=>return x"E321F09F"; -- masked System mode
      when x"02000004"=>return x"E3A00301"; -- r0=04000000
      when x"02000008"=>return x"E3A01000"; -- r1=0
      when x"0200000C"=>return x"E2811001"; -- ++r1
      when x"02000010"=>return x"E5801000"; -- publish r1
      when x"02000014"=>return x"EAFFFFFC"; -- repeat
      when others=>return x"E1A00000";
    end case;
  end;
begin
  clk<=not clk after 5 ns;
  process(clk) begin
    if rising_edge(clk) then
      if reset='1' then sleep_meta<='0';sleep9<='0';
      else sleep_meta<=sleeping;sleep9<=sleep_meta;end if;
    end if;
  end process;
  sys:entity work.nds_syscnt port map(
    clk=>clk,reset=>reset,bus9=>ss,wired_out9=>open,wired_done9=>open,
    bus7=>bus7,wired_out7=>open,wired_done7=>open,
    wramcnt=>open,vramcnt=>open,pow_2da=>open,pow_2db=>open,pow_swap=>open,
    exmem_gba7=>open,exmem_card7=>open,exmem_prio7=>open,
    halt7=>halt,wake7=>wake,console_sleep=>sleeping);
  dut: entity work.nds_cpu9
    generic map(is_simu=>'0')
    port map(clk=>clk,ce=>'1',reset=>reset,dbg_pc=>pc,
      savestate_bus=>ss,ss_wired_done=>open,gb_bus_Adr=>addr,gb_bus_rnw=>rnw,
      gb_bus_ena=>ena,gb_bus_seq=>open,gb_bus_code=>code,gb_bus_acc=>acc,
      gb_bus_dout=>dout,gb_bus_din=>din,gb_bus_done=>done,dma_on=>sleep9,
      CPU_bus_idle=>open,PC_in_BIOS=>open,cpu_halt=>open,lastread=>open,jump_out=>open,
      IRQ_in=>'0',unhalt=>'0',new_halt=>'0',cp15_vector_hi=>open,cp15_pu_enable=>open,
      cp15_icache_ena=>open,cp15_dcache_ena=>open,cp15_itcm_ena=>open,cp15_itcm_load=>open,
      cp15_dtcm_ena=>open,cp15_dtcm_load=>open,cp15_dtcm_base=>open,cp15_dtcm_size=>open,
      cp15_itcm_size=>open,bus_cacheable_i=>open,bus_cacheable_d=>open,cache_op_busy=>'0');
  process(clk)
    variable pending:boolean:=false;
    variable remaining:natural:=0;
    variable payload:std_logic_vector(31 downto 0);
  begin
    if rising_edge(clk) then
      done<='0';
      if pending then
        if remaining=0 then done<='1';din<=payload;pending:=false;
        else remaining:=remaining-1;end if;
      end if;
      if ena='1' then
        assert not pending report "overlapping request" severity failure;
        pending:=true;remaining:=READ_DELAY-1;payload:=ins(addr);
        if rnw='0' then
          assert addr=x"04000000" report "unexpected write" severity failure;
          assert unsigned(dout)=stores+1 report "sleep lost/duplicated an operation" severity failure;
          stores<=stores+1;
        end if;
      end if;
    end if;
  end process;
  process
    procedure clocks(n:natural) is
    begin for i in 1 to n loop wait until falling_edge(clk);end loop;end;
    procedure halt_write(v:std_logic_vector(7 downto 0);lane:std_logic_vector(3 downto 0):="0010") is
    begin
      bus7.Adr<=x"0000300";bus7.Din<=x"0000"&v&x"00";
      bus7.bEna<=lane;bus7.rnw<='0';bus7.ena<='1';clocks(1);bus7.ena<='0';clocks(1);
    end;
    variable before:natural;
  begin
    clocks(4);ss.Din<=x"02000000";ss.ena<='1';clocks(2);
    ss.ena<='0';clocks(4);reset<='0';clocks(1000);
    assert stores>4 report "counter did not start" severity failure;
    before:=stores;halt_write(x"80");clocks(300);
    assert sleeping='0' and stores>before report "ordinary HALT stopped ARM9" severity failure;
    halt_write(x"C0","0001");clocks(20);
    assert sleeping='0' report "wrong byte lane triggered sleep" severity failure;
    for cycle in 1 to 3 loop
      clocks(SLEEP_PHASE);halt_write(x"C0");
      assert sleeping='1' report "Sleep did not latch" severity failure;
      clocks(100);before:=stores;clocks(1000);
      assert stores=before report "ARM9 continued while ARM7 slept" severity failure;
      wake<='1';clocks(3);wake<='0';
      assert sleeping='0' report "enabled wake did not clear sleep" severity failure;
      clocks(300);assert stores>before report "ARM9 did not resume" severity failure;
    end loop;
    wake<='1';halt_write(x"C0");assert sleeping='0' report "pending wake lost" severity failure;
    wake<='0';halt_write(x"C0");assert sleeping='1' severity failure;
    reset<='1';clocks(3);assert sleeping='0' report "reset retained sleep" severity failure;
    report "PASS: Sleep pauses/resumes ARM9; HALT, byte lanes, pending wake, reset and in-flight responses";
    stop;wait;
  end process;
end;
