-- SPDX-License-Identifier: GPL-3.0-or-later
-- Authored program; no game/BIOS data. Checks architectural load values,
-- immediate dependencies, exclusions, interworking, CE pauses and DMA overlap.
-- The responder models the CPU bus contract, including rotated word data.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_cpu9_load_base is
  generic(READ_DELAY: positive:=1; STEP_PERIOD: positive:=1;
          DMA_OVERLAP: boolean:=false; IRQ_OVERLAP: boolean:=false; IRQ_DATA_INDEX: positive:=1; RESET_INFLIGHT: boolean:=false);
end;
architecture sim of tb_nds_cpu9_load_base is
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
    x"8838D3BF", x"02001024", x"8838D3C0", x"8838D3BF",
    x"02001024", x"8838D3C0", x"8636DDB1", x"0200101C",
    x"8636DDB2", x"8636DDB1", x"0200101C", x"8636DDB2",
    x"893BD6B8", x"02001024", x"893BD6B9", x"893BD6B8",
    x"02001024", x"893BD6B9", x"893BD6B8", x"0200101C",
    x"893BD6B9", x"893BD6B8", x"0200101C", x"893BD6B9",
    x"000000D6", x"02001021", x"000000D7", x"000000D6",
    x"02001021", x"000000D7", x"00000086", x"0200101F",
    x"00000087", x"00000086", x"0200101F", x"00000087",
    x"000000B8", x"02001021", x"000000B9", x"000000B8",
    x"02001021", x"000000B9", x"000000B8", x"0200101F",
    x"000000B9", x"000000B8", x"0200101F", x"000000B9",
    x"0000D3BF", x"02001024", x"0000D3C0", x"0000D3BF",
    x"02001024", x"0000D3C0", x"0000DDB1", x"0200101C",
    x"0000DDB2", x"0000DDB1", x"0200101C", x"0000DDB2",
    x"0000D6B8", x"02001024", x"0000D6B9", x"0000D6B8",
    x"02001024", x"0000D6B9", x"0000D6B8", x"0200101C",
    x"0000D6B9", x"0000D6B8", x"0200101C", x"0000D6B9",
    x"FFFFFFD6", x"02001021", x"FFFFFFD7", x"FFFFFFD6",
    x"02001021", x"FFFFFFD7", x"FFFFFF86", x"0200101F",
    x"FFFFFF87", x"FFFFFF86", x"0200101F", x"FFFFFF87",
    x"FFFFFFB8", x"02001021", x"FFFFFFB9", x"FFFFFFB8",
    x"02001021", x"FFFFFFB9", x"FFFFFFB8", x"0200101F",
    x"FFFFFFB9", x"FFFFFFB8", x"0200101F", x"FFFFFFB9",
    x"FFFFD3BF", x"02001024", x"FFFFD3C0", x"FFFFD3BF",
    x"02001024", x"FFFFD3C0", x"FFFFDDB1", x"0200101C",
    x"FFFFDDB2", x"FFFFDDB1", x"0200101C", x"FFFFDDB2",
    x"FFFFD6B8", x"02001024", x"FFFFD6B9", x"FFFFD6B8",
    x"02001024", x"FFFFD6B9", x"FFFFD6B8", x"0200101C",
    x"FFFFD6B9", x"FFFFD6B8", x"0200101C", x"FFFFD6B9",
    x"8838D3BF", x"02001024", x"8838D3BF", x"02001024",
    x"8838D3BF", x"02001024", x"8838D3BF", x"02001024",
    x"B8893BD6", x"02001021", x"0000003B", x"02001022",
    x"00003BD6", x"02001021", x"FFFFFFD6", x"02001021",
    x"8838D3BF", x"02001024", x"893BD6B8", x"02001024",
    x"893BD6B8", x"02001024", x"00000055", x"02001020",
    x"8838D3BF", x"02001028", x"8020FB87", x"8325F48E",
    x"02001004", x"8123FE80");
  function init return words is
    variable m: words(0 to 2047):=(others=>x"E7F000F0");
  begin
    -- Assembled from tb_nds_cpu9_load_base.S
    m(0):=x"E321F01F";
    m(1):=x"E3A07301";
    m(2):=x"E59F052C";
    m(3):=x"E5B01004";
    m(4):=x"E5871000";
    m(5):=x"E5870000";
    m(6):=x"E2813001";
    m(7):=x"E5873000";
    m(8):=x"E59F0514";
    m(9):=x"E3A02004";
    m(10):=x"E7B01002";
    m(11):=x"E5871000";
    m(12):=x"E5870000";
    m(13):=x"E2813001";
    m(14):=x"E5873000";
    m(15):=x"E59F04F8";
    m(16):=x"E5301004";
    m(17):=x"E5871000";
    m(18):=x"E5870000";
    m(19):=x"E2813001";
    m(20):=x"E5873000";
    m(21):=x"E59F04E0";
    m(22):=x"E3A02004";
    m(23):=x"E7301002";
    m(24):=x"E5871000";
    m(25):=x"E5870000";
    m(26):=x"E2813001";
    m(27):=x"E5873000";
    m(28):=x"E59F04C4";
    m(29):=x"E4901004";
    m(30):=x"E5871000";
    m(31):=x"E5870000";
    m(32):=x"E2813001";
    m(33):=x"E5873000";
    m(34):=x"E59F04AC";
    m(35):=x"E3A02004";
    m(36):=x"E6901002";
    m(37):=x"E5871000";
    m(38):=x"E5870000";
    m(39):=x"E2813001";
    m(40):=x"E5873000";
    m(41):=x"E59F0490";
    m(42):=x"E4101004";
    m(43):=x"E5871000";
    m(44):=x"E5870000";
    m(45):=x"E2813001";
    m(46):=x"E5873000";
    m(47):=x"E59F0478";
    m(48):=x"E3A02004";
    m(49):=x"E6101002";
    m(50):=x"E5871000";
    m(51):=x"E5870000";
    m(52):=x"E2813001";
    m(53):=x"E5873000";
    m(54):=x"E59F045C";
    m(55):=x"E5F01001";
    m(56):=x"E5871000";
    m(57):=x"E5870000";
    m(58):=x"E2813001";
    m(59):=x"E5873000";
    m(60):=x"E59F0444";
    m(61):=x"E3A02001";
    m(62):=x"E7F01002";
    m(63):=x"E5871000";
    m(64):=x"E5870000";
    m(65):=x"E2813001";
    m(66):=x"E5873000";
    m(67):=x"E59F0428";
    m(68):=x"E5701001";
    m(69):=x"E5871000";
    m(70):=x"E5870000";
    m(71):=x"E2813001";
    m(72):=x"E5873000";
    m(73):=x"E59F0410";
    m(74):=x"E3A02001";
    m(75):=x"E7701002";
    m(76):=x"E5871000";
    m(77):=x"E5870000";
    m(78):=x"E2813001";
    m(79):=x"E5873000";
    m(80):=x"E59F03F4";
    m(81):=x"E4D01001";
    m(82):=x"E5871000";
    m(83):=x"E5870000";
    m(84):=x"E2813001";
    m(85):=x"E5873000";
    m(86):=x"E59F03DC";
    m(87):=x"E3A02001";
    m(88):=x"E6D01002";
    m(89):=x"E5871000";
    m(90):=x"E5870000";
    m(91):=x"E2813001";
    m(92):=x"E5873000";
    m(93):=x"E59F03C0";
    m(94):=x"E4501001";
    m(95):=x"E5871000";
    m(96):=x"E5870000";
    m(97):=x"E2813001";
    m(98):=x"E5873000";
    m(99):=x"E59F03A8";
    m(100):=x"E3A02001";
    m(101):=x"E6501002";
    m(102):=x"E5871000";
    m(103):=x"E5870000";
    m(104):=x"E2813001";
    m(105):=x"E5873000";
    m(106):=x"E59F038C";
    m(107):=x"E1F010B4";
    m(108):=x"E5871000";
    m(109):=x"E5870000";
    m(110):=x"E2813001";
    m(111):=x"E5873000";
    m(112):=x"E59F0374";
    m(113):=x"E3A02004";
    m(114):=x"E1B010B2";
    m(115):=x"E5871000";
    m(116):=x"E5870000";
    m(117):=x"E2813001";
    m(118):=x"E5873000";
    m(119):=x"E59F0358";
    m(120):=x"E17010B4";
    m(121):=x"E5871000";
    m(122):=x"E5870000";
    m(123):=x"E2813001";
    m(124):=x"E5873000";
    m(125):=x"E59F0340";
    m(126):=x"E3A02004";
    m(127):=x"E13010B2";
    m(128):=x"E5871000";
    m(129):=x"E5870000";
    m(130):=x"E2813001";
    m(131):=x"E5873000";
    m(132):=x"E59F0324";
    m(133):=x"E0D010B4";
    m(134):=x"E5871000";
    m(135):=x"E5870000";
    m(136):=x"E2813001";
    m(137):=x"E5873000";
    m(138):=x"E59F030C";
    m(139):=x"E3A02004";
    m(140):=x"E09010B2";
    m(141):=x"E5871000";
    m(142):=x"E5870000";
    m(143):=x"E2813001";
    m(144):=x"E5873000";
    m(145):=x"E59F02F0";
    m(146):=x"E05010B4";
    m(147):=x"E5871000";
    m(148):=x"E5870000";
    m(149):=x"E2813001";
    m(150):=x"E5873000";
    m(151):=x"E59F02D8";
    m(152):=x"E3A02004";
    m(153):=x"E01010B2";
    m(154):=x"E5871000";
    m(155):=x"E5870000";
    m(156):=x"E2813001";
    m(157):=x"E5873000";
    m(158):=x"E59F02BC";
    m(159):=x"E1F010D1";
    m(160):=x"E5871000";
    m(161):=x"E5870000";
    m(162):=x"E2813001";
    m(163):=x"E5873000";
    m(164):=x"E59F02A4";
    m(165):=x"E3A02001";
    m(166):=x"E1B010D2";
    m(167):=x"E5871000";
    m(168):=x"E5870000";
    m(169):=x"E2813001";
    m(170):=x"E5873000";
    m(171):=x"E59F0288";
    m(172):=x"E17010D1";
    m(173):=x"E5871000";
    m(174):=x"E5870000";
    m(175):=x"E2813001";
    m(176):=x"E5873000";
    m(177):=x"E59F0270";
    m(178):=x"E3A02001";
    m(179):=x"E13010D2";
    m(180):=x"E5871000";
    m(181):=x"E5870000";
    m(182):=x"E2813001";
    m(183):=x"E5873000";
    m(184):=x"E59F0254";
    m(185):=x"E0D010D1";
    m(186):=x"E5871000";
    m(187):=x"E5870000";
    m(188):=x"E2813001";
    m(189):=x"E5873000";
    m(190):=x"E59F023C";
    m(191):=x"E3A02001";
    m(192):=x"E09010D2";
    m(193):=x"E5871000";
    m(194):=x"E5870000";
    m(195):=x"E2813001";
    m(196):=x"E5873000";
    m(197):=x"E59F0220";
    m(198):=x"E05010D1";
    m(199):=x"E5871000";
    m(200):=x"E5870000";
    m(201):=x"E2813001";
    m(202):=x"E5873000";
    m(203):=x"E59F0208";
    m(204):=x"E3A02001";
    m(205):=x"E01010D2";
    m(206):=x"E5871000";
    m(207):=x"E5870000";
    m(208):=x"E2813001";
    m(209):=x"E5873000";
    m(210):=x"E59F01EC";
    m(211):=x"E1F010F4";
    m(212):=x"E5871000";
    m(213):=x"E5870000";
    m(214):=x"E2813001";
    m(215):=x"E5873000";
    m(216):=x"E59F01D4";
    m(217):=x"E3A02004";
    m(218):=x"E1B010F2";
    m(219):=x"E5871000";
    m(220):=x"E5870000";
    m(221):=x"E2813001";
    m(222):=x"E5873000";
    m(223):=x"E59F01B8";
    m(224):=x"E17010F4";
    m(225):=x"E5871000";
    m(226):=x"E5870000";
    m(227):=x"E2813001";
    m(228):=x"E5873000";
    m(229):=x"E59F01A0";
    m(230):=x"E3A02004";
    m(231):=x"E13010F2";
    m(232):=x"E5871000";
    m(233):=x"E5870000";
    m(234):=x"E2813001";
    m(235):=x"E5873000";
    m(236):=x"E59F0184";
    m(237):=x"E0D010F4";
    m(238):=x"E5871000";
    m(239):=x"E5870000";
    m(240):=x"E2813001";
    m(241):=x"E5873000";
    m(242):=x"E59F016C";
    m(243):=x"E3A02004";
    m(244):=x"E09010F2";
    m(245):=x"E5871000";
    m(246):=x"E5870000";
    m(247):=x"E2813001";
    m(248):=x"E5873000";
    m(249):=x"E59F0150";
    m(250):=x"E05010F4";
    m(251):=x"E5871000";
    m(252):=x"E5870000";
    m(253):=x"E2813001";
    m(254):=x"E5873000";
    m(255):=x"E59F0138";
    m(256):=x"E3A02004";
    m(257):=x"E01010F2";
    m(258):=x"E5871000";
    m(259):=x"E5870000";
    m(260):=x"E2813001";
    m(261):=x"E5873000";
    m(262):=x"E59F011C";
    m(263):=x"E3A02001";
    m(264):=x"E7B01102";
    m(265):=x"E5871000";
    m(266):=x"E5870000";
    m(267):=x"E59F0108";
    m(268):=x"E3A02010";
    m(269):=x"E7B01122";
    m(270):=x"E5871000";
    m(271):=x"E5870000";
    m(272):=x"E59F00F4";
    m(273):=x"E3A02010";
    m(274):=x"E7B01142";
    m(275):=x"E5871000";
    m(276):=x"E5870000";
    m(277):=x"E59F00E0";
    m(278):=x"E3A02008";
    m(279):=x"E7B010E2";
    m(280):=x"E5871000";
    m(281):=x"E5870000";
    m(282):=x"E59F00CC";
    m(283):=x"E3A02001";
    m(284):=x"E7B01002";
    m(285):=x"E5871000";
    m(286):=x"E5870000";
    m(287):=x"E59F00B8";
    m(288):=x"E3A02001";
    m(289):=x"E7F01082";
    m(290):=x"E5871000";
    m(291):=x"E5870000";
    m(292):=x"E59F00A4";
    m(293):=x"E1F010B1";
    m(294):=x"E5871000";
    m(295):=x"E5870000";
    m(296):=x"E59F0094";
    m(297):=x"E1F010F1";
    m(298):=x"E5871000";
    m(299):=x"E5870000";
    m(300):=x"E59F0084";
    m(301):=x"E3A01004";
    m(302):=x"E7B01001";
    m(303):=x"E5871000";
    m(304):=x"E5870000";
    m(305):=x"E59FD070";
    m(306):=x"E49D1004";
    m(307):=x"E5871000";
    m(308):=x"E587D000";
    m(309):=x"E59FE060";
    m(310):=x"E49E1004";
    m(311):=x"E5871000";
    m(312):=x"E587E000";
    m(313):=x"E59F0050";
    m(314):=x"E3A01055";
    m(315):=x"E3510055";
    m(316):=x"15B01004";
    m(317):=x"E5871000";
    m(318):=x"E5870000";
    m(319):=x"E59F0038";
    m(320):=x"E5B00004";
    m(321):=x"E5870000";
    m(322):=x"E59F002C";
    m(323):=x"E4901004";
    m(324):=x"E4801004";
    m(325):=x"E5870000";
    m(326):=x"E59F0020";
    m(327):=x"E1E020D4";
    m(328):=x"E5872000";
    m(329):=x"E5873000";
    m(330):=x"E5870000";
    m(331):=x"E28F0004";
    m(332):=x"E490F004";
    m(333):=x"E7F000F0";
    m(334):=x"02000545";
    m(335):=x"02001020";
    m(336):=x"02001000";
    m(337):=x"68014801";
    m(338):=x"E7FE6039";
    m(339):=x"02001000";
    m(1024):=x"8123FE80";
    m(1025):=x"8020FB87";
    m(1026):=x"8325F48E";
    m(1027):=x"822AF195";
    m(1028):=x"852FEA9C";
    m(1029):=x"842CE7A3";
    m(1030):=x"8731E0AA";
    m(1031):=x"8636DDB1";
    m(1032):=x"893BD6B8";
    m(1033):=x"8838D3BF";
    m(1034):=x"8B3DCCC6";
    m(1035):=x"8A02C9CD";
    m(1036):=x"8D07C2D4";
    m(1037):=x"8C04BFDB";
    m(1038):=x"8F09B8E2";
    m(1039):=x"8E0EB5E9";
    m(1040):=x"9113AEF0";
    m(1041):=x"9010ABF7";
    m(1042):=x"9315A4FE";
    m(1043):=x"921AA105";
    m(1044):=x"951F9A0C";
    m(1045):=x"941C9713";
    m(1046):=x"9761901A";
    m(1047):=x"96668D21";
    m(1048):=x"996B8628";
    m(1049):=x"9868832F";
    m(1050):=x"9B6D7C36";
    m(1051):=x"9A72793D";
    m(1052):=x"9D777244";
    m(1053):=x"9C746F4B";
    m(1054):=x"9F796852";
    m(1055):=x"9E7E6559";
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
    variable data_reads: natural:=0;
  begin
    if rising_edge(clk) then
      if reset='1' then
        pending:=false; remaining:=0; requests:=0; data_reads:=0; irq_fired:=false;
        done<='0'; din<=(others=>'0'); irq<='0'; vector_seen<=false;
        memory<=init; results<=0; finished<=false; overlaps<=0; paused_done<=0;
      else
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
            if code='0' and index>=1024 then data_reads:=data_reads+1;end if;
            if IRQ_OVERLAP and not irq_fired and code='0' and index>=1024 and data_reads=IRQ_DATA_INDEX then
              irq<='1';irq_fired:=true;
            end if;
          else
            assert acc=ACCESS_32BIT report "unexpected data store size" severity failure;
            memory(index)<=dout;
          end if;
        end if;
      end if;
      end if;
    end if;
  end process;
  process
  begin
    wait for 40 ns;ss.Din<=x"02000000";ss.ena<='1';
    wait for 20 ns;ss.ena<='0';wait for 40 ns;reset<='0';
    if RESET_INFLIGHT then
      wait until ena='1' and code='0' and rnw='1' and unsigned(addr)>=x"02001000";
      wait until rising_edge(clk); wait for 2 ns; reset<='1';
      wait for 40 ns; reset<='0';
    end if;
    wait until finished for 2 ms;
    assert finished report "load program did not finish, PC=" & to_hstring(pc) severity failure;
    assert vector_seen=IRQ_OVERLAP report "IRQ coverage missing" severity failure;
    if DMA_OVERLAP then assert overlaps>0 report "DMA overlap not exercised" severity failure;end if;
    if STEP_PERIOD>1 then assert paused_done>0 report "CE pause not exercised" severity failure;end if;
    report "PASS: base-update addressing, values, dependencies and excluded fallbacks; ticks=" & integer'image(ticks) &
      " DMA-overlaps=" & integer'image(overlaps) & " CE-paused-done=" & integer'image(paused_done);
    stop;wait;
  end process;
end;
