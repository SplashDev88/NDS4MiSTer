-- SPDX-License-Identifier: GPL-3.0-or-later
-- Authored program; no game/BIOS data. Checks architectural load values,
-- immediate dependencies, exclusions, interworking, CE pauses and DMA overlap.
-- The responder models the CPU bus contract, including rotated word data.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_cpu9_load_retire is
  generic(READ_DELAY: positive:=1; STEP_PERIOD: positive:=1;
          DMA_OVERLAP: boolean:=false; IRQ_OVERLAP: boolean:=false);
end;
architecture sim of tb_nds_cpu9_load_retire is
  signal clk: std_logic:='0';
  signal reset: std_logic:='1';
  signal ss: proc_bus_gb_type:=((others=>'0'),(others=>'0'),'0','0',"10","1111",'0');
  signal addr,din,dout,pc: std_logic_vector(31 downto 0);
  signal ena,done,code,rnw,ce,dma,irq: std_logic:='0';
  signal acc: std_logic_vector(1 downto 0);
  signal finished,vector_seen: boolean:=false;
  signal ticks,results,overlaps,paused_done: natural:=0;
  type words is array(natural range <>) of std_logic_vector(31 downto 0);
  constant expected: words := (
    x"8123FE80", x"808123FE", x"000000FE", x"FFFFFF80",
    x"0000FE80", x"00008123", x"FFFFFE80", x"FFFFFFFE",
    x"01234567", x"02001004", x"01234567", x"02001008",
    x"8123FE80", x"01234567", x"8123FE80", x"01234567",
    x"A5A55A5A", x"8123FE81", x"CAFE1234", x"00000055",
    x"00000055", x"8123FE80", x"000000FE", x"00008123",
    x"FFFFFF80", x"FFFFFE80");
  function init return words is
    variable m: words(0 to 2047):=(others=>x"E7F000F0");
  begin
    -- Assembled from tb_nds_cpu9_load_retire.S
    m(0):=x"E321F01F";
    m(1):=x"E3A07301";
    m(2):=x"E59F00B4";
    m(3):=x"E5901000";
    m(4):=x"E5871000";
    m(5):=x"E5901001";
    m(6):=x"E5871000";
    m(7):=x"E5D01001";
    m(8):=x"E5871000";
    m(9):=x"E1D010D0";
    m(10):=x"E5871000";
    m(11):=x"E1D010B0";
    m(12):=x"E5871000";
    m(13):=x"E1D010B2";
    m(14):=x"E5871000";
    m(15):=x"E1D010F0";
    m(16):=x"E5871000";
    m(17):=x"E1D010F1";
    m(18):=x"E5871000";
    m(19):=x"E5B01004";
    m(20):=x"E5871000";
    m(21):=x"E5870000";
    m(22):=x"E4901004";
    m(23):=x"E5871000";
    m(24):=x"E5870000";
    m(25):=x"E2400008";
    m(26):=x"E1C020D0";
    m(27):=x"E5872000";
    m(28):=x"E5873000";
    m(29):=x"E890001C";
    m(30):=x"E5872000";
    m(31):=x"E5873000";
    m(32):=x"E5874000";
    m(33):=x"E590400C";
    m(34):=x"E5944000";
    m(35):=x"E2844001";
    m(36):=x"E5874000";
    m(37):=x"E2800010";
    m(38):=x"E3A02055";
    m(39):=x"E1001092";
    m(40):=x"E5871000";
    m(41):=x"E5901000";
    m(42):=x"E5871000";
    m(43):=x"E3520055";
    m(44):=x"15901004";
    m(45):=x"E5871000";
    m(46):=x"E59FF000";
    m(47):=x"E7F000F0";
    m(48):=x"020000C9";
    m(49):=x"02001000";
    m(50):=x"68014806";
    m(51):=x"78416039";
    m(52):=x"88416039";
    m(53):=x"22006039";
    m(54):=x"60395681";
    m(55):=x"60395E81";
    m(56):=x"46C0E7FE";
    m(57):=x"02001000";
    m(1024):=x"8123FE80"; m(1025):=x"01234567";
    m(1026):=x"A5A55A5A"; m(1027):=x"02001000";
    m(1028):=x"CAFE1234";
    return m;
  end;
  signal memory: words(0 to 2047):=init;
begin
  clk<=not clk after 5 ns;
  ce<='1' when ticks mod STEP_PERIOD=0 else '0';
  dma<='1' when DMA_OVERLAP and ticks mod 19<6 else '0';
  process(clk) begin
    if rising_edge(clk) then ticks<=ticks+1;end if;
  end process;
  dut: entity work.nds_cpu9
    generic map(is_simu=>'0')
    port map(clk=>clk,ce=>ce,reset=>reset,dbg_pc=>pc,
      savestate_bus=>ss,ss_wired_done=>open,gb_bus_Adr=>addr,gb_bus_rnw=>rnw,
      gb_bus_ena=>ena,gb_bus_seq=>open,gb_bus_code=>code,gb_bus_acc=>acc,
      gb_bus_dout=>dout,gb_bus_din=>din,gb_bus_done=>done,dma_on=>dma,
      CPU_bus_idle=>open,PC_in_BIOS=>open,cpu_halt=>open,lastread=>open,jump_out=>open,
      IRQ_in=>irq,unhalt=>'0',new_halt=>'0',cp15_vector_hi=>open,cp15_pu_enable=>open,
      cp15_icache_ena=>open,cp15_dcache_ena=>open,cp15_itcm_ena=>open,cp15_itcm_load=>open,
      cp15_dtcm_ena=>open,cp15_dtcm_load=>open,cp15_dtcm_base=>open,cp15_dtcm_size=>open,
      cp15_itcm_size=>open,bus_cacheable_i=>open,bus_cacheable_d=>open,cache_op_busy=>'0');
  process(clk)
    variable pending: boolean:=false;
    variable remaining: natural:=0;
    variable payload: std_logic_vector(31 downto 0);
    variable index,shift: natural;
    variable irq_fired: boolean:=false;
    variable requests: natural:=0;
  begin
    if rising_edge(clk) then
      if done='1' and ce='1' then done<='0';end if;
      if done='1' and ce='0' then paused_done<=paused_done+1;end if;
      if done='1' and dma='1' then overlaps<=overlaps+1;end if;
      if pending then
        if remaining=0 then
          done<='1';din<=payload;pending:=false;
        else remaining:=remaining-1;end if;
      end if;
      if ena='1' then
        assert not pending and (done='0' or ce='1')
          report "overlapping or unconsumed memory request" severity failure;
        pending:=true;remaining:=READ_DELAY-1 + requests mod STEP_PERIOD;
        requests:=requests+1;
        payload:=(others=>'0');
        if addr=x"FFFF0018" and code='1' then
          payload:=x"E25EF004"; -- SUBS pc,lr,#4
          vector_seen<=true;irq<='0';
        elsif addr(31 downto 8)=x"FFFF00" and code='1' then
          payload:=x"E1A00000"; -- Speculative sequential vector fetch.
        elsif addr=x"04000000" and rnw='0' then
          assert results<expected'length report "duplicate result store" severity failure;
          assert dout=expected(results)
            report "load result " & integer'image(results) & " got " & to_hstring(dout) &
              " expected " & to_hstring(expected(results)) severity failure;
          results<=results+1;
          if results+1=expected'length then finished<=true;end if;
        else
          assert addr(31 downto 13)=std_logic_vector(to_unsigned(16#02000000#/8192,19))
            report "unexpected address " & to_hstring(addr) severity failure;
          index:=to_integer(unsigned(addr(12 downto 2)));
          if rnw='1' then
            shift:=to_integer(unsigned(addr(1 downto 0)))*8;
            payload:=std_logic_vector(rotate_right(unsigned(memory(index)),shift));
            if acc=ACCESS_8BIT then payload:=x"000000" & payload(7 downto 0);
            elsif acc=ACCESS_16BIT then payload:=x"0000" & payload(15 downto 0);end if;
            if IRQ_OVERLAP and not irq_fired and code='0' and index=1024 then
              irq<='1';irq_fired:=true;
            end if;
          else
            assert acc=ACCESS_32BIT report "unexpected data store size" severity failure;
            memory(index)<=dout;
          end if;
        end if;
      end if;
    end if;
  end process;
  process
  begin
    wait for 40 ns;ss.Din<=x"02000000";ss.ena<='1';
    wait for 20 ns;ss.ena<='0';wait for 40 ns;reset<='0';
    wait until finished for 2 ms;
    assert finished report "load program did not finish, PC=" & to_hstring(pc) severity failure;
    assert vector_seen=IRQ_OVERLAP report "IRQ coverage missing" severity failure;
    if DMA_OVERLAP then assert overlaps>0 report "DMA overlap not exercised" severity failure;end if;
    if STEP_PERIOD>1 then assert paused_done>0 report "CE pause not exercised" severity failure;end if;
    report "PASS: scalar-load values/dependencies and fallback paths; ticks=" & integer'image(ticks) &
      " DMA-overlaps=" & integer'image(overlaps) & " CE-paused-done=" & integer'image(paused_done);
    stop;wait;
  end process;
end;
