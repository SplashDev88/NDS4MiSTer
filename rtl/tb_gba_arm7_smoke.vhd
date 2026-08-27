library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

use work.pProc_bus_gba.all;

entity tb_gba_arm7_smoke is
end entity;

architecture sim of tb_gba_arm7_smoke is
   signal clk100            : std_logic := '0';
   signal reset             : std_logic := '1';
   signal savestate_bus     : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal bus_addr          : std_logic_vector(31 downto 0);
   signal bus_rnw           : std_logic;
   signal bus_ena           : std_logic;
   signal bus_acc           : std_logic_vector(1 downto 0);
   signal bus_dout          : std_logic_vector(31 downto 0);
   signal bus_din           : std_logic_vector(31 downto 0) := (others => '0');
   signal bus_done          : std_logic := '0';
   signal cpu_done          : std_logic;
   signal debug_pc          : std_logic_vector(31 downto 0);
   signal debug_mixed       : std_logic_vector(31 downto 0);
begin
   clk100 <= not clk100 after 5 ns;

   -- ARM9-directed program: MOV r0,#16; CLZ r1,r0; B .
   process(all)
   begin
      case bus_addr is
         when x"00000000" => bus_din <= x"E3A00010";
         when x"00000004" => bus_din <= x"E16F1F10";
         when x"00000008" => bus_din <= x"EAFFFFFE";
         when others      => bus_din <= x"E1A00000";
      end case;
      bus_done <= bus_ena;
   end process;

   dut : entity work.gba_cpu
      generic map (is_simu => '1', is_arm9 => '1')
      port map (
         clk100 => clk100, gb_on => '1', reset => reset,
         savestate_bus => savestate_bus,
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
      wait for 40 ns;
      reset <= '0';
      wait for 4 us;
      assert unsigned(debug_pc) >= 8
         report "ARM7 did not execute the smoke program" severity failure;
      report "PASS: reused ARM7 executed ARM9 CLZ smoke program" severity note;
      stop;
      wait;
   end process;
end architecture;
