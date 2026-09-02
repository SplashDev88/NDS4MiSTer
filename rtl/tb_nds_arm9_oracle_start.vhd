library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

use work.pProc_bus_gba.all;

entity tb_nds_arm9_oracle_start is
end entity;

architecture sim of tb_nds_arm9_oracle_start is
   signal clk100        : std_logic := '0';
   signal gb_on         : std_logic := '0';
   signal reset         : std_logic := '0';
   signal descriptor_valid, boot_reset, boot_ready : std_logic := '0';
   signal save_bus      : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal save7         : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal bus_addr      : std_logic_vector(31 downto 0);
   signal bus_rnw       : std_logic;
   signal bus_ena       : std_logic;
   signal bus_acc       : std_logic_vector(1 downto 0);
   signal bus_dout      : std_logic_vector(31 downto 0);
   signal bus_din       : std_logic_vector(31 downto 0) := (others => '0');
   signal bus_done      : std_logic := '0';
   signal cpu_done      : std_logic;
   signal debug_pc      : std_logic_vector(31 downto 0);
   signal debug_mixed   : std_logic_vector(31 downto 0);
   signal retired_count : natural := 0;

   procedure save_write(
      signal clock : in std_logic;
      signal pb    : inout proc_bus_gb_type;
      constant address : in natural;
      constant value   : in std_logic_vector(31 downto 0)) is
   begin
      pb.Adr  <= std_logic_vector(to_unsigned(address, pb.Adr'length));
      pb.Din  <= value;
      pb.rnw  <= '0';
      pb.ena  <= '1';
      pb.bEna <= "1111";
      pb.rst  <= '0';
      wait until rising_edge(clock);
      wait for 1 ns;
      pb.ena  <= '0';
      pb.Adr  <= (others => 'Z');
      pb.Din  <= (others => 'Z');
      pb.rnw  <= 'Z';
      pb.bEna <= (others => 'Z');
      wait until rising_edge(clock);
   end procedure;
begin
   clk100 <= not clk100 after 5 ns;

   boot : entity work.nds_cpu_boot_sequencer
      port map (
         clk => clk100, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => x"02004800", arm7_entry => x"02380000",
         arm9_current_sp => x"03002F7C", arm9_irq_sp => x"03003F80",
         arm9_saved_sp => x"03003FC0", arm7_current_sp => x"0380FD80",
         arm7_irq_sp => x"0380FF80", arm7_saved_sp => x"0380FFC0",
         initial_cpsr => x"000000D3", cpu_reset => boot_reset,
         boot_ready => boot_ready, save9 => save_bus, save7 => save7
      );

   -- First ARM9 path from the deterministic nds-bootstrap boot oracle.
   process(all)
   begin
      case bus_addr is
         when x"02004800" => bus_din <= x"E3A00301";
         when x"02004804" => bus_din <= x"E5800208";
         when x"02004808" => bus_din <= x"E3A00013";
         when x"0200480C" => bus_din <= x"E129F000";
         when x"02004810" => bus_din <= x"E3A01403";
         when x"02004814" => bus_din <= x"E2411A01";
         when x"02004818" => bus_din <= x"E1A0D001";
         when x"0200481C" => bus_din <= x"E3A0001F";
         when x"02004820" => bus_din <= x"E129F000";
         when x"02004824" => bus_din <= x"E2411C01";
         when x"02004828" => bus_din <= x"E1A0D001";
         when x"0200482C" => bus_din <= x"E59F3240";
         when x"02004830" => bus_din <= x"E12FFF33";
         when x"02004838" => bus_din <= x"E129F000";
         when x"0200483C" => bus_din <= x"E59FD234";
         when x"02004840" => bus_din <= x"E3A00013";
         when x"02004844" => bus_din <= x"E129F000";
         when x"02004848" => bus_din <= x"E59FD22C";
         when x"0200484C" => bus_din <= x"E3A0001F";
         when x"02004850" => bus_din <= x"E129F000";
         when x"02004854" => bus_din <= x"E59FD224";
         when x"02004858" => bus_din <= x"E3A0C301";
         when x"0200485C" => bus_din <= x"E7DCB62C";
         when x"02004860" => bus_din <= x"E20BB003";
         when x"02004864" => bus_din <= x"E3A09000";
         when x"02004868" => bus_din <= x"E58C9180";
         when x"0200486C" => bus_din <= x"E3A09009";
         when x"02004870" => bus_din <= x"EB00007A";
         when x"02004A60" => bus_din <= x"E59CA180";
         when x"02004A64" => bus_din <= x"E20AA00F";
         when x"02004A68" => bus_din <= x"E15A0009";
         when x"02004A6C" => bus_din <= x"1AFFFFFB";
         when x"02004A70" => bus_din <= x"E12FFF1E";
         when x"02004A74" => bus_din <= x"0200EE50";
         when x"02004A78" => bus_din <= x"0B003E00";
         when x"02004A7C" => bus_din <= x"0B003F00";
         when x"02004A80" => bus_din <= x"0B003D00";
         when x"0200EE50" => bus_din <= x"E59F1118";
         when x"0200EE54" => bus_din <= x"E3A00301";
         when x"0200EE58" => bus_din <= x"E2800FC1";
         when x"0200EE5C" => bus_din <= x"E1C010B0";
         when x"0200EE60" => bus_din <= x"E59F110C";
         when x"0200EE64" => bus_din <= x"EE011F10";
         when x"0200EE68" => bus_din <= x"E3A00000";
         when x"0200EE6C" => bus_din <= x"EE070F15";
         when x"0200EE70" => bus_din <= x"EE070F16";
         when x"0200EE74" => bus_din <= x"EE070F9A";
         when x"0200EE78" => bus_din <= x"E59F00F8";
         when x"0200EE7C" => bus_din <= x"E380000A";
         when x"0200EE80" => bus_din <= x"EE090F11";
         when x"0200EE84" => bus_din <= x"E3A00020";
         when x"0200EE88" => bus_din <= x"EE090F31";
         when x"0200EE8C" => bus_din <= x"E59F00E8";
         when x"0200EE90" => bus_din <= x"EE060F10";
         when x"0200EE94" => bus_din <= x"E59F00E4";
         when x"0200EE98" => bus_din <= x"EE060F11";
         when x"0200EE9C" => bus_din <= x"E3A00017";
         when x"0200EEA0" => bus_din <= x"EE060F12";
         when x"0200EEA4" => bus_din <= x"E59F00CC";
         when x"0200EEA8" => bus_din <= x"E380001B";
         when x"0200EEAC" => bus_din <= x"EE060F15";
         when x"0200EEB0" => bus_din <= x"E59F00CC";
         when x"0200EEB4" => bus_din <= x"E1A007A0";
         when x"0200EEB8" => bus_din <= x"E1A00780";
         when x"0200EEBC" => bus_din <= x"E380001D";
         when x"0200EEC0" => bus_din <= x"EE060F14";
         when x"0200EEC4" => bus_din <= x"E59F00BC";
         when x"0200EEC8" => bus_din <= x"E5900000";
         when x"0200EECC" => bus_din <= x"E3100902";
         when x"0200EED0" => bus_din <= x"1A00000D";
         when x"0200EED4" => bus_din <= x"EF0F0000";
         when x"0200EF70" => bus_din <= x"00008203";
         when x"0200EF74" => bus_din <= x"00002078";
         when x"0200EF78" => bus_din <= x"0B000000";
         when x"0200EF7C" => bus_din <= x"04000033";
         when x"0200EF80" => bus_din <= x"FFFF001F";
         when x"0200EF84" => bus_din <= x"01000100";
         when x"0200EF88" => bus_din <= x"04004008";
         when x"FFFF0008" => bus_din <= x"EA00003E";
         when x"FFFF0108" => bus_din <= x"E92D5010";
         when x"FFFF010C" => bus_din <= x"E14F4000";
         when x"FFFF0110" => bus_din <= x"E92D0010";
         when x"FFFF0114" => bus_din <= x"E2044080";
         when x"FFFF0118" => bus_din <= x"E384401F";
         when x"FFFF011C" => bus_din <= x"E55EC002";
         when x"FFFF0120" => bus_din <= x"E129F004";
         when x"FFFF0124" => bus_din <= x"E92D4000";
         when x"FFFF0128" => bus_din <= x"E35C0020";
         when x"FFFF012C" => bus_din <= x"A3A0C001";
         when x"FFFF0130" => bus_din <= x"E79FF10C";
         when x"FFFF0174" => bus_din <= x"FFFF0450";
         when x"FFFF0450" => bus_din <= x"E3A00000";
         when x"FFFF0454" => bus_din <= x"EAFFFF56";
         when x"FFFF01B4" => bus_din <= x"E8BD4000";
         when x"FFFF01B8" => bus_din <= x"E3A040D3";
         when x"FFFF01BC" => bus_din <= x"E129F004";
         when x"FFFF01C0" => bus_din <= x"E8BD0010";
         when x"FFFF01C4" => bus_din <= x"E169F004";
         when x"FFFF01C8" => bus_din <= x"E8BD5010";
         when x"FFFF01CC" => bus_din <= x"E1B0F00E";
         when x"0200EED8" => bus_din <= x"E59F10AC";
         when x"0200EEDC" => bus_din <= x"E3500000";
         when x"0200EEE0" => bus_din <= x"1A000004";
         when x"0200EEE4" => bus_din <= x"E59F30A4";
         when x"0200EEE8" => bus_din <= x"E59F20A4";
         when x"0200EEEC" => bus_din <= x"E3A08509";
         when x"0200EEF0" => bus_din <= x"E59F90A0";
         when x"0200EEF4" => bus_din <= x"EA00000B";
         when x"0200EF28" => bus_din <= x"EE061F13";
         when x"0200EF2C" => bus_din <= x"EE062F16";
         when x"0200EF30" => bus_din <= x"EE063F17";
         when x"0200EF34" => bus_din <= x"E3A00080";
         when x"0200EF38" => bus_din <= x"EE030F10";
         when x"0200EF3C" => bus_din <= x"E3A00082";
         when x"0200EF40" => bus_din <= x"EE020F10";
         when x"0200EF44" => bus_din <= x"EE020F30";
         when x"0200EF48" => bus_din <= x"E59F0068";
         when x"0200EF4C" => bus_din <= x"EE050F70";
         when x"0200EF50" => bus_din <= x"EE050F50";
         when x"0200EF54" => bus_din <= x"EE110F10";
         when x"0200EF58" => bus_din <= x"E59F105C";
         when x"0200EF5C" => bus_din <= x"E1800001";
         when x"0200EF60" => bus_din <= x"EE010F10";
         when x"0200EF64" => bus_din <= x"E59F0054";
         when x"0200EF68" => bus_din <= x"E5809000";
         when x"0200EF6C" => bus_din <= x"E12FFF1E";
         when x"02004834" => bus_din <= x"E3A00012";
         when x"0200EED6" => bus_din <= x"0000000F";
         when x"02FFEEFC" => bus_din <= x"02004834";
         when x"02FFEFF0" => bus_din <= x"4000001F";
         when x"02FFEFF4" => bus_din <= x"00000000";
         when x"02FFEFF8" => bus_din <= x"02004800";
         when x"02FFEFFC" => bus_din <= x"0200EED8";
         when x"0200EF8C" => bus_din <= x"08000035";
         when x"0200EF90" => bus_din <= x"0200002B";
         when x"0200EF94" => bus_din <= x"0200002F";
         when x"0200EF98" => bus_din <= x"0202A90C";
         when x"0200EFB8" => bus_din <= x"33333363";
         when x"0200EFBC" => bus_din <= x"00051005";
         when x"0200EFC0" => bus_din <= x"0202A930";
         when others      => bus_din <= (others => '0');
      end case;
      bus_done <= bus_ena;
   end process;

   process(clk100)
   begin
      if rising_edge(clk100) then
         if bus_ena = '1' and bus_rnw = '0' then
            assert (bus_addr = x"04000208" and bus_acc = ACCESS_32BIT and
                    bus_dout = x"04000000") or
                   (bus_addr = x"04000304" and bus_acc = ACCESS_16BIT and
                    bus_dout(15 downto 0) = x"8203") or
                   (bus_addr = x"02FFEFF4" and bus_acc = ACCESS_32BIT and
                    bus_dout = x"00000000") or
                   (bus_addr = x"02FFEFF8" and bus_acc = ACCESS_32BIT and
                    bus_dout = x"02004800") or
                   (bus_addr = x"02FFEFFC" and bus_acc = ACCESS_32BIT and
                    bus_dout = x"0200EED8") or
                   (bus_addr = x"02FFEFF0" and bus_acc = ACCESS_32BIT and
                    bus_dout = x"4000001F") or
                   (bus_addr = x"02FFEEFC" and bus_acc = ACCESS_32BIT and
                    bus_dout = x"02004834") or
                   (bus_addr = x"0202A930" and bus_acc = ACCESS_32BIT and
                    bus_dout = x"0202A90C") or
                   (bus_addr = x"04000180" and bus_acc = ACCESS_32BIT and
                    bus_dout = x"00000000")
               report "ARM9 oracle write diverged: addr=" & to_hstring(bus_addr) &
                      " acc=" & to_hstring(bus_acc) & " data=" & to_hstring(bus_dout)
               severity failure;
         end if;
         if cpu_done = '1' then
            retired_count <= retired_count + 1;
         end if;
      end if;
   end process;

   dut : entity work.gba_cpu
      generic map (
         is_simu => '1', is_arm9 => '1',
         arm9_cp15_reset_control => x"00052078"
      )
      port map (
         clk100 => clk100, gb_on => gb_on, reset => boot_reset,
         savestate_bus => save_bus,
         gb_bus_Adr => bus_addr, gb_bus_rnw => bus_rnw,
         gb_bus_ena => bus_ena, gb_bus_acc => bus_acc,
         gb_bus_dout => bus_dout, gb_bus_din => bus_din,
         gb_bus_done => bus_done,
         wait_cnt_value => (others => '0'), wait_cnt_update => '0',
         Underclock => "00", bus_lowbits => open,
         settle => '0', dma_on => '0', do_step => '1', done => cpu_done,
         CPU_bus_idle => open, PC_in_BIOS => open, lastread => open,
         jump_out => open, new_cycles_out => open, new_cycles_valid => open,
         dma_new_cycles => '0', dma_first_cycles => '0',
         dma_dword_cycles => '0', dma_toROM => '0', dma_init_cycles => '0',
         dma_cycles_adrup => (others => '0'),
         IRP_in => (others => '0'), cpu_IRP => '0', new_halt => '0',
         DISPSTAT_debug => (others => '0'), debug_fifocount => 0,
         timerdebug0 => (others => '0'), timerdebug1 => (others => '0'),
         timerdebug2 => (others => '0'), timerdebug3 => (others => '0'),
         debug_cpu_pc => debug_pc, debug_cpu_execute_pc => open,
         debug_cpu_mixed => debug_mixed,
         arm9_dtcm_region => open, arm9_dtcm_enable => open
      );

   process
   begin
      reset <= '1';
      wait until rising_edge(clk100);
      wait until rising_edge(clk100);
      reset <= '0';
      descriptor_valid <= '1';
      wait until boot_ready = '1';
      gb_on <= '1';

      wait until retired_count = 130 for 30 us;
      assert retired_count >= 130
         report "ARM9 did not reach one hundred thirty oracle instructions" severity failure;
      report "PASS: ARM9 followed the initial melonDS boot path" severity note;
      stop;
      wait;
   end process;
end architecture;
