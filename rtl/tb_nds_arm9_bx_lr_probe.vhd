library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

-- Exact r128 terminal helper:
--   01FFA6A8  E10F0000  MRS r0,CPSR
--   01FFA6AC  E200001F  AND r0,r0,#0x1f
--   01FFA6B0  E12FFF1E  BX  lr
-- A literal load seeds LR with a normal SDK return address. The diagnostic
-- output must expose data-load provenance plus that LR while BX is active,
-- and the CPU must then fetch the return target.
entity tb_nds_arm9_bx_lr_probe is
end entity;

architecture sim of tb_nds_arm9_bx_lr_probe is
   signal clk, reset, descriptor_valid, boot_reset, boot_ready :
      std_logic := '0';
   signal save9, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata, debug_mixed :
      std_logic_vector(31 downto 0);
   signal rnw, ena, done : std_logic;
   signal acc : std_logic_vector(1 downto 0);
   signal saw_probe, saw_return : std_logic := '0';
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
      case addr is
         when x"02000000" => rdata <= x"E59FE004"; -- ldr lr,[pc,#4]
         when x"02000004" => rdata <= x"E59FF004"; -- ldr pc,[pc,#4]
         when x"0200000C" => rdata <= x"02001234"; -- desired LR
         when x"02000010" => rdata <= x"01FFA6A8"; -- helper target
         when x"01FFA6A8" => rdata <= x"E10F0000";
         when x"01FFA6AC" => rdata <= x"E200001F";
         when x"01FFA6B0" => rdata <= x"E12FFF1E";
         when x"02001234" => rdata <= x"EAFFFFFE";
         when others => rdata <= x"E1A00000";
      end case;
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
   begin
      if rising_edge(clk) and boot_reset = '0' then
         if debug_mixed(27 downto 0) = x"2001234" then
            saw_probe <= '1';
            assert debug_mixed(31 downto 28) = x"9"
               report "BX LR probe did not report data-load LR provenance"
               severity failure;
         end if;
         if ena = '1' and addr = x"02001234" then
            saw_return <= '1';
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
      wait until saw_return = '1' for 20 us;
      assert saw_probe = '1'
         report "BX LR probe never exposed the live LR" severity failure;
      assert saw_return = '1'
         report "exact 0x01FFA6B0 BX LR did not fetch its return target"
         severity failure;
      report "PASS: ARM9 0x01FFA6B0 BX LR exposes live LR and returns"
         severity note;
      stop;
      wait;
   end process;
end architecture;
