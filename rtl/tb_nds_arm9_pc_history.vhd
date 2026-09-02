library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

-- Exercise the production-cadence ARM9 flight recorder through the same
-- arm9_bx_lr_telemetry generic used by the MiSTer top. The CPU executes
-- sixteen consecutive instructions ending at 0x02005B10; every saved phase
-- must then become observable with phase zero holding the trigger PC.
entity tb_nds_arm9_pc_history is
end entity;

architecture sim of tb_nds_arm9_pc_history is
   signal clk, reset, descriptor_valid, boot_reset, boot_ready :
      std_logic := '0';
   signal save9, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata, debug_mixed :
      std_logic_vector(31 downto 0);
   signal rnw, ena, done : std_logic;
   signal acc : std_logic_vector(1 downto 0);
   signal history_seen : std_logic := '0';
   signal phases_seen : std_logic_vector(15 downto 0) :=
      (others => '0');
begin
   clk <= not clk after 5 ns;

   boot : entity work.nds_cpu_boot_sequencer
      port map (
         clk => clk, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => x"02000000", arm7_entry => x"00001000",
         arm9_current_sp => x"027E3F80", arm9_irq_sp => x"027E3FBC",
         arm9_saved_sp => x"027E3F80", arm7_current_sp => x"00003000",
         arm7_irq_sp => x"00003040", arm7_saved_sp => x"00003080",
         initial_cpsr => x"0000001F", cpu_reset => boot_reset,
         boot_ready => boot_ready, save9 => save9, save7 => save7
      );

   process(all)
   begin
      if addr = x"02000000" then
         rdata <= x"EA0016B3"; -- b 0x02005AD4
      elsif addr = x"02005B14" then
         rdata <= x"EAFFFFFE"; -- stable post-trigger loop
      else
         rdata <= x"E1A00000"; -- nop
      end if;
      done <= ena;
   end process;

   dut : entity work.gba_cpu
      generic map (
         is_simu => '1', is_arm9 => '1',
         arm9_bx_lr_telemetry => '1'
      )
      port map (
         clk100 => clk, gb_on => '1', reset => boot_reset,
         savestate_bus => save9, gb_bus_Adr => addr, gb_bus_rnw => rnw,
         gb_bus_ena => ena, gb_bus_acc => acc, gb_bus_dout => wdata,
         gb_bus_din => rdata, gb_bus_done => done,
         wait_cnt_value => (others => '0'), wait_cnt_update => '0',
         Underclock => "00", bus_lowbits => open, settle => '0',
         dma_on => '0', do_step => '1', done => open, CPU_bus_idle => open,
         PC_in_BIOS => open, lastread => open, jump_out => open,
         new_cycles_out => open, new_cycles_valid => open,
         dma_new_cycles => '0', dma_first_cycles => '0',
         dma_dword_cycles => '0', dma_toROM => '0',
         dma_init_cycles => '0', dma_cycles_adrup => (others => '0'),
         IRP_in => (others => '0'), cpu_IRP => '0', new_halt => '0',
         clear_halt => '0', DISPSTAT_debug => (others => '0'),
         debug_fifocount => 0, timerdebug0 => (others => '0'),
         timerdebug1 => (others => '0'), timerdebug2 => (others => '0'),
         timerdebug3 => (others => '0'), debug_cpu_pc => open,
         debug_cpu_execute_pc => open, debug_cpu_mixed => debug_mixed,
         arm9_dtcm_region => open, arm9_dtcm_enable => open
      );

   process(clk)
      variable phase : integer range 0 to 15;
      variable expected_pc : unsigned(31 downto 0);
   begin
      if rising_edge(clk) and boot_reset = '0' then
         phase := to_integer(unsigned(debug_mixed(31 downto 28)));
         if phase /= 0 then
            history_seen <= '1';
         end if;
         if phase /= 0 or history_seen = '1' then
            expected_pc := unsigned'(x"02005B10") -
               to_unsigned(phase * 4, 32);
            assert unsigned(debug_mixed(27 downto 0)) =
                   expected_pc(27 downto 0)
               report "ARM9 PC history phase contains the wrong PC"
               severity failure;
            phases_seen(phase) <= '1';
         end if;
      end if;
   end process;

   process
   begin
      reset <= '1';
      wait until rising_edge(clk);
      reset <= '0';
      descriptor_valid <= '1';
      wait until boot_ready = '1';
      wait until phases_seen = x"FFFF" for 50 us;
      assert phases_seen = x"FFFF"
         report "ARM9 PC history did not publish all sixteen phases"
         severity failure;
      report "PASS: ARM9 pre-loop PC history freezes and publishes all phases"
         severity note;
      stop;
      wait;
   end process;
end architecture;
