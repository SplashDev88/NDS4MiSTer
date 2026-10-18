-- SPDX-License-Identifier: GPL-3.0-or-later
-- Actual ARM7 bus and WRAM owner drain, with independent delayed memory replies.
library MEM;
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

use work.pProc_bus_gba.all;

entity tb_nds_checkpoint_arm7 is
end entity;

architecture sim of tb_nds_checkpoint_arm7 is
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';

   signal cpu_adr : std_logic_vector(31 downto 0) := (others => '0');
   signal cpu_rnw : std_logic := '1';
   signal cpu_ena : std_logic := '0';
   signal cpu_acc : std_logic_vector(1 downto 0) := ACCESS_16BIT;
   signal cpu_dout : std_logic_vector(31 downto 0) := (others => '0');
   signal cpu_lowbits : std_logic_vector(1 downto 0) := "00";
   signal cpu_lastread : std_logic_vector(31 downto 0) := (others => '0');
   signal cpu_din : std_logic_vector(31 downto 0);
   signal cpu_done : std_logic;

   signal bios_data : std_logic_vector(31 downto 0) := (others => '0');
   signal w7p_readdata : std_logic_vector(31 downto 0) := (others => '0');
   signal wsh_dout : std_logic_vector(31 downto 0) := (others => '0');
   signal wsh_done : std_logic := '0';
   signal wsh_mapped : std_logic := '1';
   signal vram_dout : std_logic_vector(31 downto 0) := (others => '0');
   signal vram_done : std_logic := '0';
   signal mr_done : std_logic := '0';
   signal mr_readdata : std_logic_vector(31 downto 0) := (others => '0');
   signal io_wired_out : std_logic_vector(31 downto 0) := (others => '0');
   signal io_wired_done : std_logic := '1';
   signal bus_idle,shared_idle,private_we,shared_ena,shared_rnw,vram_ena,main_ena : std_logic;
   signal private_addr : unsigned(15 downto 2);
   signal shared_addr : unsigned(14 downto 2);
   signal private_be,shared_be : std_logic_vector(3 downto 0);
   signal private_din,shared_din : std_logic_vector(31 downto 0);
   signal io_ready : std_logic := '1';
   signal io7 : proc_bus_gb_type;
   signal map_mode : std_logic_vector(1 downto 0) := "00";
   signal arm9_ena,arm9_done : std_logic := '0';
   signal arm9_addr : unsigned(14 downto 2) := (others=>'0');
   signal arm9_din : std_logic_vector(31 downto 0) := (others=>'0');
begin
   clk <= not clk after 5 ns;

   dut : entity work.nds_membus7
   port map (
      clk => clk, reset => reset,
      cpu_adr => cpu_adr, cpu_rnw => cpu_rnw, cpu_ena => cpu_ena,
      cpu_acc => cpu_acc, cpu_dout => cpu_dout, cpu_lowbits => cpu_lowbits,
      cpu_lastread => cpu_lastread, cpu_din => cpu_din, cpu_done => cpu_done,
      bios_addr => open, bios_data => bios_data,
      w7p_addr => private_addr, w7p_we => private_we, w7p_be => private_be,
      w7p_writedata => private_din, w7p_readdata => w7p_readdata,
      wsh_ena => shared_ena, wsh_rnw => shared_rnw, wsh_addr => shared_addr, wsh_be => shared_be,
      wsh_din => shared_din, wsh_dout => wsh_dout, wsh_done => wsh_done,
      wsh_mapped => wsh_mapped,
      vram_ena => vram_ena, vram_rnw => open, vram_addr => open, vram_be => open,
      vram_din => open, vram_dout => vram_dout, vram_done => vram_done,
      mr_ena => main_ena, mr_rnw => open, mr_addr => open, mr_be => open,
      mr_writedata => open, mr_done => mr_done, mr_readdata => mr_readdata,
      io_ce_next => io_ready, io_bus => io7, checkpoint_idle => bus_idle,
      io_wired_out => io_wired_out, io_wired_done => io_wired_done
   );

   private_ram: entity MEM.SyncRamDualByteEnable generic map(is_simu=>'1',ADDR_WIDTH=>14)
    port map(clk=>clk,ce_a=>'1',addr_a=>to_integer(private_addr),
     datain_a0=>private_din(7 downto 0),datain_a1=>private_din(15 downto 8),
     datain_a2=>private_din(23 downto 16),datain_a3=>private_din(31 downto 24),
     dataout_a=>w7p_readdata,we_a=>private_we,be_a=>private_be,
     ce_b=>'0',addr_b=>0,datain_b0=>x"00",datain_b1=>x"00",datain_b2=>x"00",datain_b3=>x"00",
     dataout_b=>open,we_b=>'0',be_b=>"0000");
   shared_ram: entity work.nds_wram generic map(is_simu=>'1')
    port map(clk=>clk,wramcnt=>map_mode,arm9_ena=>arm9_ena,arm9_rnw=>'0',arm9_addr=>arm9_addr,
     arm9_be=>"1111",arm9_din=>arm9_din,arm9_dout=>open,arm9_done=>arm9_done,arm9_mapped=>open,
     arm7_ena=>shared_ena,arm7_rnw=>shared_rnw,arm7_addr=>shared_addr,arm7_be=>shared_be,
     arm7_din=>shared_din,arm7_dout=>wsh_dout,arm7_done=>wsh_done,arm7_mapped=>wsh_mapped,
     checkpoint_idle=>shared_idle);
   monitor: process
   begin
    wait until clk'event;wait for 1 ns;
    if reset='1' or cpu_ena='1' or cpu_done='1' or io7.ena='1' or private_we='1' or
       shared_ena='1' or vram_ena='1' or main_ena='1' then
     assert bus_idle='0' report "ARM7 idle overlapped a request/write/completion" severity failure;
    end if;
    if shared_ena='1' or arm9_ena='1' or wsh_done='1' or arm9_done='1' then
     assert shared_idle='0' report "shared-WRAM idle overlapped admission/completion" severity failure;
    end if;
   end process;
   stimulus: process
    procedure step(n : positive := 1) is
    begin for k in 1 to n loop wait until rising_edge(clk);wait for 2 ns;end loop;end;
    procedure issue(a : std_logic_vector(31 downto 0);rd : std_logic;v : std_logic_vector(31 downto 0)) is
    begin
     cpu_adr<=a;cpu_lowbits<=a(1 downto 0);cpu_rnw<=rd;cpu_dout<=v;cpu_acc<=ACCESS_32BIT;cpu_ena<='1';
     wait for 1 ns;assert bus_idle='0' report "ARM7 fresh request retained idle" severity failure;
     step;cpu_ena<='0';wait for 1 ns;
    end;
    procedure finish(expected : std_logic_vector(31 downto 0);rd : boolean := true) is
    begin
     for k in 1 to 100 loop exit when cpu_done='1';step;end loop;
     assert cpu_done='1' report "ARM7 request did not complete" severity failure;
     if rd then assert cpu_din=expected report "ARM7 route/read data changed: "&to_hstring(cpu_din) severity failure;end if;
     assert bus_idle='0' report "ARM7 completion falsely idle" severity failure;
     step;step;
     assert bus_idle='1' and shared_idle='1' report "ARM7/WRAM idle did not qualify after drain" severity failure;
    end;
    procedure readword(a,v : std_logic_vector(31 downto 0)) is
    begin issue(a,'1',x"00000000");finish(v);end;
    procedure writeword(a,v : std_logic_vector(31 downto 0)) is
    begin issue(a,'0',v);finish(x"00000000",false);end;
    procedure load_shared(a : natural;v : std_logic_vector(31 downto 0)) is
    begin
     arm9_addr<=to_unsigned(a,13);arm9_din<=v;arm9_ena<='1';step;
     arm9_ena<='0';step(2);assert shared_idle='1' severity failure;
    end;
   begin
    step(4);reset<='0';step(2);assert bus_idle='1' and shared_idle='1' severity failure;
    -- Direct private WRAM and its unmapped shared-window mirror.
    writeword(x"03800000",x"CCDDEEFF");readword(x"03800000",x"CCDDEEFF");readword(x"03000000",x"CCDDEEFF");
    load_shared(0,x"11223344");load_shared(4096,x"55667788");
    map_mode<="01";step;readword(x"03000000",x"11223344");
    map_mode<="10";step;readword(x"03000000",x"55667788");
    map_mode<="11";step;readword(x"03000000",x"11223344");readword(x"03004000",x"55667788");
    writeword(x"03004004",x"A55A1234");readword(x"03004004",x"A55A1234");
    -- Both WRAM ports can commit independent mapped blocks together.
    map_mode<="01";step;
    arm9_addr<=to_unsigned(5,13);arm9_din<=x"10203040";arm9_ena<='1';
    issue(x"03000014",'0',x"50607080");arm9_ena<='0';finish(x"00000000",false);
    map_mode<="11";step;readword(x"03000014",x"50607080");readword(x"03004014",x"10203040");
    -- A pulse to an external owner cannot be mistaken for all work finishing.
    for delay in 0 to 17 loop
     issue(x"02000000",'1',x"00000000");step(delay+1);
     assert bus_idle='0' and cpu_done='0' report "ARM7 waiting main RAM falsely idle" severity failure;
     mr_readdata<=x"89ABCDEF";mr_done<='1';wait for 1 ns;finish(x"89ABCDEF");mr_done<='0';
     issue(x"06000000",'1',x"00000000");step(delay+1);
     assert bus_idle='0' and cpu_done='0' report "ARM7 waiting VRAM falsely idle" severity failure;
     vram_dout<=x"01234567";vram_done<='1';wait for 1 ns;finish(x"01234567");vram_done<='0';
    end loop;
    io_ready<='0';io_wired_out<=x"AABBCCDD";
    issue(x"04000100",'1',x"00000000");step(23);
    assert bus_idle='0' and io7.ena='0' and cpu_done='0' report "ARM7 pending IO falsely idle" severity failure;
    io_ready<='1';step;assert io7.ena='1' report "ARM7 IO admission lost" severity failure;finish(x"AABBCCDD");
    bios_data<=x"E1A00000";readword(x"00000000",x"E1A00000");
    cpu_lastread<=x"12345678";readword(x"0F000000",x"12345678");
    reset<='1';step(3);assert bus_idle='0' severity failure;reset<='0';step(3);assert bus_idle='1' severity failure;
    report "CHECKPOINT_ARM7_WRAM_PASS: all WRAM modes, private mirror, delayed memory, IO alignment, BIOS/open bus";
    std.env.stop;wait;
   end process;
   process begin wait for 100 us;assert false report "ARM7 checkpoint watchdog" severity failure;end process;
end architecture;
