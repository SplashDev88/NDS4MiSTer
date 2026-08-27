library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

use work.pProc_bus_gba.all;

entity tb_nds_arm7_independent_pc is
end entity;

architecture sim of tb_nds_arm7_independent_pc is
   signal clk100        : std_logic := '0';
   signal reset         : std_logic := '1';
   signal savestate_bus : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal bus_addr      : std_logic_vector(31 downto 0);
   signal bus_ena       : std_logic;
   signal bus_din       : std_logic_vector(31 downto 0) := (others => '0');
   signal bus_done      : std_logic := '0';
   signal execute_pc    : std_logic_vector(31 downto 0);
   signal independent_pc : std_logic_vector(31 downto 0);
begin
   clk100 <= not clk100 after 5 ns;

   process(all)
   begin
      case bus_addr is
         when x"00000000" => bus_din <= x"E3A00001"; -- MOV r0,#1
         when x"00000004" => bus_din <= x"E2800001"; -- ADD r0,r0,#1
         when x"00000008" => bus_din <= x"EAFFFFFE"; -- B .
         when others      => bus_din <= x"E1A00000";
      end case;
      bus_done <= bus_ena;
   end process;

   dut : entity work.gba_cpu
      generic map (
         is_simu => '1',
         is_arm9 => '0',
         arm9_execute_pc_telemetry => '1'
      )
      port map (
         clk100 => clk100, gb_on => '1', reset => reset,
         savestate_bus => savestate_bus,
         gb_bus_Adr => bus_addr, gb_bus_rnw => open,
         gb_bus_ena => bus_ena, gb_bus_acc => open,
         gb_bus_dout => open, gb_bus_din => bus_din,
         gb_bus_done => bus_done,
         wait_cnt_value => (others => '0'), wait_cnt_update => '0',
         Underclock => "00", bus_lowbits => open,
         settle => '0', dma_on => '0', do_step => '1', done => open,
         CPU_bus_idle => open, PC_in_BIOS => open, lastread => open,
         jump_out => open, new_cycles_out => open, new_cycles_valid => open,
         dma_new_cycles => '0', dma_first_cycles => '0',
         dma_dword_cycles => '0', dma_toROM => '0', dma_init_cycles => '0',
         dma_cycles_adrup => (others => '0'),
         IRP_in => (others => '0'), cpu_IRP => '0', new_halt => '0',
         DISPSTAT_debug => (others => '0'), debug_fifocount => 0,
         timerdebug0 => (others => '0'), timerdebug1 => (others => '0'),
         timerdebug2 => (others => '0'), timerdebug3 => (others => '0'),
         debug_cpu_pc => open, debug_cpu_execute_pc => execute_pc,
         debug_cpu_mixed => independent_pc,
         arm9_dtcm_region => open, arm9_dtcm_enable => open
      );

   process
   begin
      wait for 40 ns;
      reset <= '0';
      wait for 4 us;
      assert independent_pc = execute_pc
         report "ARM7 independent execute-PC seam does not match execute PC"
         severity failure;
      assert unsigned(independent_pc) >= 4 and
             unsigned(independent_pc) <= 16
         report "ARM7 independent execute-PC seam is not a program address"
         severity failure;
      report "PASS: ARM7 independent execute-PC seam tracks the live PC"
         severity note;
      stop;
      wait;
   end process;
end architecture;
