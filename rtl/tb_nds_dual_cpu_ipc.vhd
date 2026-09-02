library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

use work.pProc_bus_gba.all;

entity tb_nds_dual_cpu_ipc is
end entity;

architecture sim of tb_nds_dual_cpu_ipc is
   signal clk100 : std_logic := '0';
   signal reset  : std_logic := '1';
   signal save9, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');

   signal addr9, dout9, din9 : std_logic_vector(31 downto 0);
   signal rnw9, ena9, done_bus9, done_cpu9 : std_logic;
   signal acc9 : std_logic_vector(1 downto 0);
   signal addr7, dout7, din7 : std_logic_vector(31 downto 0);
   signal rnw7, ena7, done_bus7, done_cpu7 : std_logic;
   signal acc7 : std_logic_vector(1 downto 0);

   signal ipc9_we, ipc7_we : std_logic;
   signal ipc9_read, ipc7_read : std_logic_vector(31 downto 0);
   signal finished9, finished7 : std_logic := '0';
begin
   clk100 <= not clk100 after 5 ns;

   ipc9_we <= '1' when ena9 = '1' and rnw9 = '0' and addr9 = x"04000180" else '0';
   ipc7_we <= '1' when ena7 = '1' and rnw7 = '0' and addr7 = x"04000180" else '0';

   ipc : entity work.nds_ipcsync
      port map (
         clk => clk100, reset => reset,
         arm9_we => ipc9_we, arm9_wdata => dout9, arm9_rdata => ipc9_read,
         arm7_we => ipc7_we, arm7_wdata => dout7, arm7_rdata => ipc7_read
      );

   process(all)
   begin
      case addr9 is
         when x"00000000" => din9 <= x"E59F005C";
         when x"00000004" => din9 <= x"E3A01000";
         when x"00000008" => din9 <= x"E5801000";
         when x"0000000C" => din9 <= x"E5902000";
         when x"00000010" => din9 <= x"E202200F";
         when x"00000014" => din9 <= x"E3520009";
         when x"00000018" => din9 <= x"1AFFFFFB";
         when x"0000001C" => din9 <= x"E59F1044";
         when x"00000020" => din9 <= x"E5801000";
         when x"00000024" => din9 <= x"E5902000";
         when x"00000028" => din9 <= x"E202200F";
         when x"0000002C" => din9 <= x"E352000B";
         when x"00000030" => din9 <= x"1AFFFFFB";
         when x"00000034" => din9 <= x"E59F1030";
         when x"00000038" => din9 <= x"E5801000";
         when x"0000003C" => din9 <= x"E5902000";
         when x"00000040" => din9 <= x"E202200F";
         when x"00000044" => din9 <= x"E352000D";
         when x"00000048" => din9 <= x"1AFFFFFB";
         when x"0000004C" => din9 <= x"E3A01000";
         when x"00000050" => din9 <= x"E5801000";
         when x"00000054" => din9 <= x"E59F3014";
         when x"00000058" => din9 <= x"E3A04001";
         when x"0000005C" => din9 <= x"E5834000";
         when x"00000060" => din9 <= x"EAFFFFFE";
         when x"00000064" => din9 <= x"04000180";
         when x"00000068" => din9 <= x"00000A00";
         when x"0000006C" => din9 <= x"00000C00";
         when x"00000070" => din9 <= x"02001000";
         when x"04000180" => din9 <= ipc9_read;
         when others      => din9 <= (others => '0');
      end case;
      done_bus9 <= ena9;
   end process;

   process(all)
   begin
      case addr7 is
         when x"00000000" => din7 <= x"E59F0054";
         when x"00000004" => din7 <= x"E59F1054";
         when x"00000008" => din7 <= x"E5801000";
         when x"0000000C" => din7 <= x"E5902000";
         when x"00000010" => din7 <= x"E202200F";
         when x"00000014" => din7 <= x"E352000A";
         when x"00000018" => din7 <= x"1AFFFFFB";
         when x"0000001C" => din7 <= x"E59F1040";
         when x"00000020" => din7 <= x"E5801000";
         when x"00000024" => din7 <= x"E5902000";
         when x"00000028" => din7 <= x"E202200F";
         when x"0000002C" => din7 <= x"E352000C";
         when x"00000030" => din7 <= x"1AFFFFFB";
         when x"00000034" => din7 <= x"E59F102C";
         when x"00000038" => din7 <= x"E5801000";
         when x"0000003C" => din7 <= x"E5902000";
         when x"00000040" => din7 <= x"E202200F";
         when x"00000044" => din7 <= x"E3520000";
         when x"00000048" => din7 <= x"1AFFFFFB";
         when x"0000004C" => din7 <= x"E59F3018";
         when x"00000050" => din7 <= x"E3A04001";
         when x"00000054" => din7 <= x"E5834000";
         when x"00000058" => din7 <= x"EAFFFFFE";
         when x"0000005C" => din7 <= x"04000180";
         when x"00000060" => din7 <= x"00000900";
         when x"00000064" => din7 <= x"00000B00";
         when x"00000068" => din7 <= x"00000D00";
         when x"0000006C" => din7 <= x"02001004";
         when x"04000180" => din7 <= ipc7_read;
         when others      => din7 <= (others => '0');
      end case;
      done_bus7 <= ena7;
   end process;

   process(clk100)
   begin
      if rising_edge(clk100) then
         if ena9 = '1' and rnw9 = '0' and addr9 = x"02001000" then
            assert acc9 = ACCESS_32BIT and dout9 = x"00000001"
               report "ARM9 completion write mismatch" severity failure;
            finished9 <= '1';
         end if;
         if ena7 = '1' and rnw7 = '0' and addr7 = x"02001004" then
            assert acc7 = ACCESS_32BIT and dout7 = x"00000001"
               report "ARM7 completion write mismatch" severity failure;
            finished7 <= '1';
         end if;
      end if;
   end process;

   cpu9 : entity work.gba_cpu
      generic map (is_simu => '0', is_arm9 => '1')
      port map (
         clk100 => clk100, gb_on => '1', reset => reset, savestate_bus => save9,
         gb_bus_Adr => addr9, gb_bus_rnw => rnw9, gb_bus_ena => ena9,
         gb_bus_acc => acc9, gb_bus_dout => dout9, gb_bus_din => din9,
         gb_bus_done => done_bus9, wait_cnt_value => (others => '0'), wait_cnt_update => '0',
         Underclock => "00", bus_lowbits => open, settle => '0', dma_on => '0',
         do_step => '1', done => done_cpu9, CPU_bus_idle => open, PC_in_BIOS => open,
         lastread => open, jump_out => open, new_cycles_out => open, new_cycles_valid => open,
         dma_new_cycles => '0', dma_first_cycles => '0', dma_dword_cycles => '0',
         dma_toROM => '0', dma_init_cycles => '0', dma_cycles_adrup => (others => '0'),
         IRP_in => (others => '0'), cpu_IRP => '0', new_halt => '0',
         DISPSTAT_debug => (others => '0'), debug_fifocount => 0,
         timerdebug0 => (others => '0'), timerdebug1 => (others => '0'),
         timerdebug2 => (others => '0'), timerdebug3 => (others => '0'),
         debug_cpu_pc => open, debug_cpu_execute_pc => open,
         debug_cpu_mixed => open,
         arm9_dtcm_region => open, arm9_dtcm_enable => open
      );

   cpu7 : entity work.gba_cpu
      generic map (is_simu => '0', is_arm9 => '0')
      port map (
         clk100 => clk100, gb_on => '1', reset => reset, savestate_bus => save7,
         gb_bus_Adr => addr7, gb_bus_rnw => rnw7, gb_bus_ena => ena7,
         gb_bus_acc => acc7, gb_bus_dout => dout7, gb_bus_din => din7,
         gb_bus_done => done_bus7, wait_cnt_value => (others => '0'), wait_cnt_update => '0',
         Underclock => "00", bus_lowbits => open, settle => '0', dma_on => '0',
         do_step => '1', done => done_cpu7, CPU_bus_idle => open, PC_in_BIOS => open,
         lastread => open, jump_out => open, new_cycles_out => open, new_cycles_valid => open,
         dma_new_cycles => '0', dma_first_cycles => '0', dma_dword_cycles => '0',
         dma_toROM => '0', dma_init_cycles => '0', dma_cycles_adrup => (others => '0'),
         IRP_in => (others => '0'), cpu_IRP => '0', new_halt => '0',
         DISPSTAT_debug => (others => '0'), debug_fifocount => 0,
         timerdebug0 => (others => '0'), timerdebug1 => (others => '0'),
         timerdebug2 => (others => '0'), timerdebug3 => (others => '0'),
         debug_cpu_pc => open, debug_cpu_execute_pc => open,
         debug_cpu_mixed => open,
         arm9_dtcm_region => open, arm9_dtcm_enable => open
      );

   process
   begin
      wait for 40 ns;
      reset <= '0';
      wait until finished9 = '1' and finished7 = '1' for 50 us;
      assert finished9 = '1' and finished7 = '1'
         report "dual FPGA CPUs did not complete IPCSYNC handshake" severity failure;
      assert ipc9_read = x"0000000D" and ipc7_read = x"00000D00"
         report "final IPCSYNC state mismatch" severity failure;
      report "PASS: two FPGA CPUs completed the ARM9/ARM7 IPCSYNC handshake" severity note;
      stop;
      wait;
   end process;
end architecture;
