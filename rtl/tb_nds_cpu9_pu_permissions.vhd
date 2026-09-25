-- SPDX-License-Identifier: GPL-3.0-or-later
-- Authored ARM program; no game/BIOS data. Exercises both legacy and extended
-- c5 data/code AP formats, all AP codes, overlapping/disabled PU regions,
-- 4 KiB boundaries, a 4 GiB region, PU off, CE pauses and DMA overlap.
-- A simple bus responder checks the real CPU's permission output at each
-- synthetic store; tb_nds_membus9_pu_store checks downstream side effects.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_cpu9_pu_permissions is
  generic(READ_DELAY: positive:=1; STEP_PERIOD: positive:=1;
          DMA_OVERLAP: boolean:=false; IRQ_OVERLAP: boolean:=false);
end;
architecture sim of tb_nds_cpu9_pu_permissions is
  signal clk: std_logic:='0';
  signal reset: std_logic:='1';
  signal ss: proc_bus_gb_type:=((others=>'0'),(others=>'0'),'0','0',"10","1111",'0');
  signal addr,din,dout,pc: std_logic_vector(31 downto 0);
  signal ena,done,code,rnw,ce,dma,irq: std_logic:='0';
  signal acc: std_logic_vector(1 downto 0);
  signal finished,vector_seen: boolean:=false;
  signal ticks,results,overlaps,paused_done: natural:=0;
  type words is array(natural range <>) of std_logic_vector(31 downto 0);
  constant expected: words := (x"000000E4", x"00003210", x"00000039", x"00000321", x"0000E4E4", x"76543210", x"00004E4E", x"10325476", x"CAFEBABE");
  type flags is array(natural range <>) of std_logic;
  constant expected_denied: flags := ('0', '1', '1', '0', '0', '0', '1', '1', '1', '1', '1', '1', '1', '1', '1', '1', '1', '1', '1', '0', '0', '1', '0', '0', '0');
  signal deny: std_logic;
  signal probes: natural:=0;
  function init return words is
    variable m: words(0 to 2047):=(others=>x"E7F000F0");
  begin
    m(0):=x"E321F01F";
    m(1):=x"E59F7000";
    m(2):=x"EA000000";
    m(3):=x"04000000";
    m(4):=x"E59F6000";
    m(5):=x"EA000000";
    m(6):=x"02001000";
    m(7):=x"E59F2000";
    m(8):=x"EA000000";
    m(9):=x"5A5AA5A5";
    m(10):=x"E59F0000";
    m(11):=x"EA000000";
    m(12):=x"000000E4";
    m(13):=x"EE050F10";
    m(14):=x"EE151F10";
    m(15):=x"E5871000";
    m(16):=x"EE151F50";
    m(17):=x"E5871000";
    m(18):=x"E59F0000";
    m(19):=x"EA000000";
    m(20):=x"00000039";
    m(21):=x"EE050F30";
    m(22):=x"EE151F30";
    m(23):=x"E5871000";
    m(24):=x"EE151F70";
    m(25):=x"E5871000";
    m(26):=x"E59F0000";
    m(27):=x"EA000000";
    m(28):=x"76543210";
    m(29):=x"EE050F50";
    m(30):=x"EE151F10";
    m(31):=x"E5871000";
    m(32):=x"EE151F50";
    m(33):=x"E5871000";
    m(34):=x"E59F0000";
    m(35):=x"EA000000";
    m(36):=x"10325476";
    m(37):=x"EE050F70";
    m(38):=x"EE151F30";
    m(39):=x"E5871000";
    m(40):=x"EE151F70";
    m(41):=x"E5871000";
    m(42):=x"E59F0000";
    m(43):=x"EA000000";
    m(44):=x"00000000";
    m(45):=x"EE060F10";
    m(46):=x"E59F0000";
    m(47):=x"EA000000";
    m(48):=x"00000000";
    m(49):=x"EE060F11";
    m(50):=x"E59F0000";
    m(51):=x"EA000000";
    m(52):=x"00000000";
    m(53):=x"EE060F12";
    m(54):=x"E59F0000";
    m(55):=x"EA000000";
    m(56):=x"00000000";
    m(57):=x"EE060F13";
    m(58):=x"E59F0000";
    m(59):=x"EA000000";
    m(60):=x"00000000";
    m(61):=x"EE060F14";
    m(62):=x"E59F0000";
    m(63):=x"EA000000";
    m(64):=x"00000000";
    m(65):=x"EE060F15";
    m(66):=x"E59F0000";
    m(67):=x"EA000000";
    m(68):=x"00000000";
    m(69):=x"EE060F16";
    m(70):=x"E59F0000";
    m(71):=x"EA000000";
    m(72):=x"00000000";
    m(73):=x"EE060F17";
    m(74):=x"E59F0000";
    m(75):=x"EA000000";
    m(76):=x"00000000";
    m(77):=x"EE010F10";
    m(78):=x"E5862000";
    m(79):=x"E59F0000";
    m(80):=x"EA000000";
    m(81):=x"00000001";
    m(82):=x"EE010F10";
    m(83):=x"E5862000";
    m(84):=x"E59F0000";
    m(85):=x"EA000000";
    m(86):=x"02000019";
    m(87):=x"EE060F10";
    m(88):=x"E59F0000";
    m(89):=x"EA000000";
    m(90):=x"00000000";
    m(91):=x"EE050F50";
    m(92):=x"E5862000";
    m(93):=x"E59F0000";
    m(94):=x"EA000000";
    m(95):=x"00000001";
    m(96):=x"EE050F50";
    m(97):=x"E5862000";
    m(98):=x"E59F0000";
    m(99):=x"EA000000";
    m(100):=x"00000002";
    m(101):=x"EE050F50";
    m(102):=x"E5862000";
    m(103):=x"E59F0000";
    m(104):=x"EA000000";
    m(105):=x"00000003";
    m(106):=x"EE050F50";
    m(107):=x"E5862000";
    m(108):=x"E59F0000";
    m(109):=x"EA000000";
    m(110):=x"00000004";
    m(111):=x"EE050F50";
    m(112):=x"E5862000";
    m(113):=x"E59F0000";
    m(114):=x"EA000000";
    m(115):=x"00000005";
    m(116):=x"EE050F50";
    m(117):=x"E5862000";
    m(118):=x"E59F0000";
    m(119):=x"EA000000";
    m(120):=x"00000006";
    m(121):=x"EE050F50";
    m(122):=x"E5862000";
    m(123):=x"E59F0000";
    m(124):=x"EA000000";
    m(125):=x"00000007";
    m(126):=x"EE050F50";
    m(127):=x"E5862000";
    m(128):=x"E59F0000";
    m(129):=x"EA000000";
    m(130):=x"00000008";
    m(131):=x"EE050F50";
    m(132):=x"E5862000";
    m(133):=x"E59F0000";
    m(134):=x"EA000000";
    m(135):=x"00000009";
    m(136):=x"EE050F50";
    m(137):=x"E5862000";
    m(138):=x"E59F0000";
    m(139):=x"EA000000";
    m(140):=x"0000000A";
    m(141):=x"EE050F50";
    m(142):=x"E5862000";
    m(143):=x"E59F0000";
    m(144):=x"EA000000";
    m(145):=x"0000000B";
    m(146):=x"EE050F50";
    m(147):=x"E5862000";
    m(148):=x"E59F0000";
    m(149):=x"EA000000";
    m(150):=x"0000000C";
    m(151):=x"EE050F50";
    m(152):=x"E5862000";
    m(153):=x"E59F0000";
    m(154):=x"EA000000";
    m(155):=x"0000000D";
    m(156):=x"EE050F50";
    m(157):=x"E5862000";
    m(158):=x"E59F0000";
    m(159):=x"EA000000";
    m(160):=x"0000000E";
    m(161):=x"EE050F50";
    m(162):=x"E5862000";
    m(163):=x"E59F0000";
    m(164):=x"EA000000";
    m(165):=x"0000000F";
    m(166):=x"EE050F50";
    m(167):=x"E5862000";
    m(168):=x"E59F0000";
    m(169):=x"EA000000";
    m(170):=x"00000001";
    m(171):=x"EE050F50";
    m(172):=x"E59F0000";
    m(173):=x"EA000000";
    m(174):=x"02001017";
    m(175):=x"EE060F17";
    m(176):=x"E5862000";
    m(177):=x"E59F0000";
    m(178):=x"EA000000";
    m(179):=x"30000001";
    m(180):=x"EE050F50";
    m(181):=x"E5862000";
    m(182):=x"E59F0000";
    m(183):=x"EA000000";
    m(184):=x"00000000";
    m(185):=x"EE060F17";
    m(186):=x"E5862000";
    m(187):=x"E59F0000";
    m(188):=x"EA000000";
    m(189):=x"02000017";
    m(190):=x"EE060F10";
    m(191):=x"E5862000";
    m(192):=x"E59F6000";
    m(193):=x"EA000000";
    m(194):=x"02000FFC";
    m(195):=x"E5862000";
    m(196):=x"E59F6000";
    m(197):=x"EA000000";
    m(198):=x"02001000";
    m(199):=x"E59F0000";
    m(200):=x"EA000000";
    m(201):=x"0000003F";
    m(202):=x"EE060F10";
    m(203):=x"E5862000";
    m(204):=x"E59F0000";
    m(205):=x"EA000000";
    m(206):=x"00000000";
    m(207):=x"EE010F10";
    m(208):=x"E59F0000";
    m(209):=x"EA000000";
    m(210):=x"00000000";
    m(211):=x"EE050F50";
    m(212):=x"E5862000";
    m(213):=x"E59F1000";
    m(214):=x"EA000000";
    m(215):=x"CAFEBABE";
    m(216):=x"E5871000";
    m(217):=x"EAFFFFFE";
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
      cp15_itcm_size=>open,bus_wdenied_d=>deny,bus_cacheable_i=>open,bus_cacheable_d=>open,cache_op_busy=>'0');
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
            report "CP15 readback " & integer'image(results) & " got " & to_hstring(dout) &
              " expected " & to_hstring(expected(results)) severity failure;
          results<=results+1;
          if results+1=expected'length then finished<=true;end if;
        elsif rnw='0' and (addr=x"02001000" or addr=x"02000FFC") then
          assert probes<expected_denied'length report "extra protection probe" severity failure;
          assert deny=expected_denied(probes)
            report "protection probe " & integer'image(probes) & " wrong deny" severity failure;
          probes<=probes+1;
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
    assert probes=expected_denied'length report "missing protection probes" severity failure;
    assert vector_seen=IRQ_OVERLAP report "IRQ coverage missing" severity failure;
    if DMA_OVERLAP then assert overlaps>0 report "DMA overlap not exercised" severity failure;end if;
    if STEP_PERIOD>1 then assert paused_done>0 report "CE pause not exercised" severity failure;end if;
    report "PASS: CP15 legacy/extended permissions and PU region priority; ticks=" & integer'image(ticks) &
      " DMA-overlaps=" & integer'image(overlaps) & " CE-paused-done=" & integer'image(paused_done);
    stop;wait;
  end process;
end;
