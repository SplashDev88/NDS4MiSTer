-- Synthetic BL -> WFI -> BX caller-return regression for the production CPU.
-- Sweep bus latency and wake phase to expose IRQ selection on the edge that
-- clears halt. The post-WFI BX must execute; falling through stores a failure
-- marker. No game image, BIOS, save file, or external data is needed.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_cpu9_wfi_return is
  generic(READ_DELAY: positive:=1; WAKE_DELAY: natural:=4;
          IRQ_ENABLED: boolean:=true);
end;
architecture sim of tb_nds_cpu9_wfi_return is
  signal clk: std_logic:='0';
  signal reset: std_logic:='1';
  signal ss: proc_bus_gb_type:=((others=>'0'),(others=>'0'),'0','0',"10","1111",'0');
  signal addr,din,dout,pc: std_logic_vector(31 downto 0);
  signal ena,done,code,rnw,halt: std_logic:='0';
  signal irq,wake: std_logic:='0';
  signal finished,vector_seen: boolean:=false;
begin
  clk<=not clk after 5 ns;
  dut: entity work.nds_cpu9
    generic map(is_simu=>'0')
    port map(clk=>clk,ce=>'1',reset=>reset,dbg_pc=>pc,
      savestate_bus=>ss,ss_wired_done=>open,gb_bus_Adr=>addr,gb_bus_rnw=>rnw,
      gb_bus_ena=>ena,gb_bus_seq=>open,gb_bus_code=>code,gb_bus_acc=>open,
      gb_bus_dout=>dout,gb_bus_din=>din,gb_bus_done=>done,dma_on=>'0',
      CPU_bus_idle=>open,PC_in_BIOS=>open,cpu_halt=>halt,lastread=>open,jump_out=>open,
      IRQ_in=>irq,unhalt=>wake,new_halt=>'0',cp15_vector_hi=>open,cp15_pu_enable=>open,
      cp15_icache_ena=>open,cp15_dcache_ena=>open,cp15_itcm_ena=>open,cp15_itcm_load=>open,
      cp15_dtcm_ena=>open,cp15_dtcm_load=>open,cp15_dtcm_base=>open,cp15_dtcm_size=>open,
      cp15_itcm_size=>open,bus_cacheable_i=>open,bus_cacheable_d=>open,cache_op_busy=>'0');
  process(clk)
    variable remaining:natural:=0;
    variable pending:std_logic_vector(31 downto 0);
  begin
    if rising_edge(clk) then
      done<='0';
      if remaining>0 then
        remaining:=remaining-1;
        if remaining=0 then done<='1';din<=pending;end if;
      end if;
      if ena='1' then
        assert remaining=0 report "overlapping memory request" severity failure;
        remaining:=READ_DELAY;
        if rnw='0' then
          pending:=(others=>'0');
          assert dout/=x"000000DE"
            report "FAIL: executed terminal guard after skipping WFI return" severity failure;
          if dout=x"00000055" then finished<=true;end if;
        else
          case addr is
            when x"02000000"=>
              if IRQ_ENABLED then pending:=x"E321F01F";else pending:=x"E321F09F";end if;
            when x"02000004"=>pending:=x"E3A0DA02";
            when x"02000008"=>pending:=x"E1A00000";
            when x"0200000C"=>pending:=x"E92D4000";
            when x"02000010"=>pending:=x"E24DD004";
            when x"02000014"=>pending:=x"E1A00000";
            when x"02000018"=>pending:=x"EB0003F8"; -- BL WFI helper; LR=0x0200001c
            when x"0200001C"=>pending:=x"E3A02055"; -- success marker after return
            when x"02000020"=>pending:=x"E58D2000";
            when x"02000024"=>pending:=x"EAFFFFFE";
            when x"02001000"=>pending:=x"E3A00000";
            when x"02001004"=>pending:=x"EE070F90";
            when x"02001008"=>pending:=x"E12FFF1E"; -- must return, not fall through
            when x"0200100C"=>pending:=x"E3A020DE";
            when x"02001010"=>pending:=x"E58D2000";
            when x"02001014"=>pending:=x"EAFFFFFE";
            when x"FFFF0018"=>pending:=x"E25EF004";vector_seen<=true;
            when others=>pending:=x"E1A00000";
          end case;
        end if;
      end if;
    end if;
  end process;
  process
  begin
    wait for 40 ns;ss.Din<=x"02000000";ss.ena<='1';
    wait for 20 ns;ss.ena<='0';wait for 40 ns;reset<='0';
    wait until halt='1' for 20 us;
    assert halt='1' report "did not reach WFI" severity failure;
    for n in 1 to WAKE_DELAY loop wait until falling_edge(clk);end loop;
    wake<='1';irq<='1';
    if IRQ_ENABLED then
      wait until vector_seen for 20 us;
      assert vector_seen report "did not enter IRQ" severity failure;
    else
      wait for 200 ns;
    end if;
    wait until falling_edge(clk);irq<='0';wake<='0';
    if not finished then wait until finished for 20 us;end if;
    assert finished report "did not return to caller after WFI/IRQ" severity failure;
    assert vector_seen=IRQ_ENABLED report "unexpected IRQ vector state" severity failure;
    report "PASS: ARM9 WFI/BX caller return, delay=" & integer'image(READ_DELAY) &
      " wake=" & integer'image(WAKE_DELAY) & " IRQ-enabled=" & boolean'image(IRQ_ENABLED);
    stop;wait;
  end process;
end;
