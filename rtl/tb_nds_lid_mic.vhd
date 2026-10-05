-- SPDX-License-Identifier: GPL-3.0-only
-- Exercise guest-visible SPI ADC transfers and lid IRQ latch/wake behavior.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_lid_mic is end;
architecture sim of tb_nds_lid_mic is
  signal clk : std_logic := '0';
  signal reset : std_logic := '1';
  signal bus7 : proc_bus_gb_type := (Din => (others=>'0'), Adr=>x"00001C0",
    rnw=>'1', ena=>'0', acc=>ACCESS_32BIT, bEna=>"0000", rst=>'0');
  signal spi_data, irq_data, irq_in, flags : std_logic_vector(31 downto 0);
  signal lid, blow, touch, lid_irq, cpu_irq, unhalt : std_logic := '0';
begin
  clk <= not clk after 5 ns;
  irq_in <= (22=>lid_irq, others=>'0');
  spi : entity work.nds_nitro_spi port map (
    clk=>clk, reset=>reset, bus7=>bus7, wired_out7=>spi_data, wired_done7=>open,
    irq_spi=>open, touch_active=>touch, touch_x=>x"71", touch_y=>x"43",
    fw_wr=>open, fw_wlane=>open, fw_wdata=>open, fw_addr=>open, fw_req=>open,
    fw_done=>'0', fw_data=>(others=>'0'), lid_closed=>lid, mic_blow=>blow, irq_lid=>lid_irq);
  irq : entity work.nds_irq port map (
    clk=>clk, ce=>'1', reset=>reset, gb_bus=>bus7, wired_out=>irq_data,
    wired_done=>open, irq_in=>irq_in, cpu_irq=>cpu_irq, cpu_unhalt=>unhalt,
    dbg_if=>flags);
  process
    variable a,b,last,minval,maxval,total,changes,n : integer;
    procedure tick(count : positive := 1) is begin
      for i in 1 to count loop wait until falling_edge(clk); end loop;
    end procedure;
    procedure wr(adr : std_logic_vector(27 downto 0); data : std_logic_vector(31 downto 0);
                 lanes : std_logic_vector(3 downto 0) := "1111") is begin
      tick; bus7.Adr<=adr; bus7.Din<=data; bus7.bEna<=lanes; bus7.rnw<='0'; bus7.ena<='1';
      tick; bus7.ena<='0'; bus7.rnw<='1'; bus7.bEna<="0000";
      tick;
    end procedure;
    procedure transfer(value : integer; variable result : out integer) is
      variable guard : integer := 0;
    begin
      wr(x"00001C0", std_logic_vector(to_unsigned(value*65536,32)), "0100");
      while spi_data(7)='1' and guard<600 loop tick; guard:=guard+1; end loop;
      assert guard<600 report "SPI busy timeout" severity failure;
      result:=to_integer(unsigned(spi_data(23 downto 16)));
    end procedure;
    procedure conversion(cmd : integer; variable sample : out integer) is
      variable dummy,hi,lo : integer;
    begin
      transfer(cmd,dummy); transfer(0,hi); transfer(0,lo);
      sample:=(hi*256+lo)/8;
    end procedure;
  begin
    tick(4); reset<='0'; tick(3);
    assert flags=x"00000000" and lid_irq='0' report "phantom boot lid IRQ" severity failure;
    wr(x"0000210",x"00400000"); wr(x"0000208",x"00000001");
    lid<='1'; tick(10);
    assert flags=x"00000000" and unhalt='0' report "closing lid raised IRQ" severity failure;
    lid<='0'; tick(8);
    assert flags=x"00400000" and cpu_irq='1' and unhalt='1'
      report "lid reopening did not latch IRQ22 and wake ARM7" severity failure;
    wr(x"0000214",x"00400000"); tick(8);
    assert flags=x"00000000" and unhalt='0' report "open lid repeats IRQ" severity failure;
    wr(x"0000208",x"00000000");
    lid<='1'; tick(4); lid<='0'; tick(8);
    assert flags=x"00400000" and cpu_irq='0' and unhalt='1'
      report "ARM7 halt must wake independently of IME" severity failure;
    wr(x"0000214",x"00400000");
    lid<='1'; tick(3); reset<='1'; tick(3); reset<='0'; tick(3);
    assert flags=x"00000000" report "reset generated lid event" severity failure;
    lid<='0'; tick(8);
    assert flags=x"00400000" report "closed-through-reset lost next lid opening" severity failure;

    wr(x"00001C0",x"00008A00","0011"); -- 12-bit TSC with held CS
    for i in 1 to 16 loop conversion(16#E0#,a);
      assert a=16#800# report "idle microphone isn't midpoint silence" severity failure; end loop;
    minval:=4095; maxval:=0; total:=0; changes:=0; last:=-1; blow<='1';
    for i in 1 to 4096 loop
      conversion(16#E0#,a);
      if a<minval then minval:=a; end if; if a>maxval then maxval:=a; end if;
      total:=total+a; if a/=last then changes:=changes+1; end if; last:=a;
    end loop;
    assert minval<256 and maxval>3840 and changes>4000 and total/4096>1850 and total/4096<2250
      report "blow waveform lacks range, variation or centered average" severity failure;
    report "mic min="&integer'image(minval)&" max="&integer'image(maxval)&" mean="&integer'image(total/4096);
    for i in 1 to 32 loop conversion(16#E8#,a);
      assert a mod 16=0 report "8-bit ADC mask lost" severity failure; end loop;
    touch<='1'; conversion(16#D0#,a); conversion(16#90#,b);
    assert a=16#710# and b=16#430# report "blow affected touch ADC" severity failure;
    -- Release between command and read: conversion bytes remain one latched sample.
    transfer(16#E0#,n); transfer(0,a); blow<='0'; transfer(0,b);
    conversion(16#E0#,a); assert a=16#800# report "mic remained active after release" severity failure;
    conversion(16#E8#,a); assert a=16#800# report "8-bit silence changed" severity failure;
    touch<='0'; conversion(16#D0#,a); conversion(16#90#,b);
    assert a=0 and b=4095 report "touch release changed" severity failure;
    wr(x"00001C0",x"00000000","0011");
    wr(x"00001C0",x"00008A00","0011"); conversion(16#E0#,a);
    assert a=16#800# report "chip select release shifted microphone bytes" severity failure;
    report "PASS lid edge IRQ/ack/reset/IME-independent wake and microphone silence/noise/touch/ADC framing";
    stop; wait;
  end process;
end;
