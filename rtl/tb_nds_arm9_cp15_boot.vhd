library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

entity tb_nds_arm9_cp15_boot is end entity;

architecture sim of tb_nds_arm9_cp15_boot is
   signal clk, reset : std_logic := '0';
   signal save : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata, debug_pc, debug_mixed :
      std_logic_vector(31 downto 0);
   signal dtcm_region : std_logic_vector(31 downto 0);
   signal dtcm_enable : std_logic;
   signal rnw, ena, done, cpu_done : std_logic;
   signal acc : std_logic_vector(1 downto 0);
begin
   clk <= not clk after 5 ns;
   process(all)
   begin
      case addr is
         when x"00000000" => rdata <= x"EE110F10"; -- MRC p15,0,r0,c1,c0,0
         when x"00000004" => rdata <= x"E59F1004"; -- LDR r1,[pc,#4]
         when x"00000008" => rdata <= x"EE091F11"; -- MCR p15,0,r1,c9,c1,0
         when x"0000000C" => rdata <= x"EAFFFFFE"; -- B .
         when x"00000010" => rdata <= x"027E000A"; -- 16 KiB DTCM region
         when others => rdata <= x"E1A00000";
      end case;
      done <= ena;
   end process;

   dut : entity work.gba_cpu
      generic map (
         is_simu => '1', is_arm9 => '1',
         arm9_cp15_reset_control => x"00052078"
      )
      port map (
         clk100 => clk, gb_on => '1', reset => reset, savestate_bus => save,
         gb_bus_Adr => addr, gb_bus_rnw => rnw, gb_bus_ena => ena,
         gb_bus_acc => acc, gb_bus_dout => wdata, gb_bus_din => rdata,
         gb_bus_done => done, wait_cnt_value => (others => '0'),
         wait_cnt_update => '0', Underclock => "00", bus_lowbits => open,
         settle => '0', dma_on => '0', do_step => '1', done => cpu_done,
         CPU_bus_idle => open, PC_in_BIOS => open, lastread => open,
         jump_out => open, new_cycles_out => open, new_cycles_valid => open,
         dma_new_cycles => '0', dma_first_cycles => '0',
         dma_dword_cycles => '0', dma_toROM => '0', dma_init_cycles => '0',
         dma_cycles_adrup => (others => '0'), IRP_in => (others => '0'),
         cpu_IRP => '0', new_halt => '0', DISPSTAT_debug => (others => '0'),
         debug_fifocount => 0, timerdebug0 => (others => '0'),
         timerdebug1 => (others => '0'), timerdebug2 => (others => '0'),
         timerdebug3 => (others => '0'), debug_cpu_pc => debug_pc,
         debug_cpu_execute_pc => open,
         debug_cpu_mixed => debug_mixed,
         arm9_dtcm_region => dtcm_region, arm9_dtcm_enable => dtcm_enable
      );

   process
   begin
      reset <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';
      wait for 1 us;
      assert unsigned(debug_pc) >= 4
         report "ARM9 did not execute CP15 boot probe" severity failure;
      assert dtcm_enable = '1'
         report "ARM9 direct-boot DTCM enable was not exported" severity failure;
      assert dtcm_region = x"027E000A"
         report "ARM9 CP15 DTCM relocation was not exported" severity failure;
      report "PASS: ARM9 CP15 control and relocated DTCM region exported"
         severity note;
      stop;
      wait;
   end process;
end architecture;
