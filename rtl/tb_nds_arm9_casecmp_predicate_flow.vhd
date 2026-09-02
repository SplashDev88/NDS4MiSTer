library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

entity tb_nds_arm9_casecmp_predicate_flow is
   generic (
      bus_response_delay_cycles : natural := 0;
      step_period : positive := 1
   );
end entity;

architecture sim of tb_nds_arm9_casecmp_predicate_flow is
   signal clk, reset, descriptor_valid, boot_reset, boot_ready :
      std_logic := '0';
   signal save9, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata, debug_execute :
      std_logic_vector(31 downto 0);
   signal rnw, ena, done : std_logic;
   signal acc : std_logic_vector(1 downto 0);
   signal stack_access_seen : std_logic := '0';
   signal cpu_step : std_logic := '1';
   signal step_counter : natural := 0;
   type response_state_t is (response_idle, response_wait, response_release);
   signal response_state : response_state_t := response_idle;
   signal response_delay : natural := 0;
   signal pending_addr : std_logic_vector(31 downto 0) := (others => '0');
begin
   clk <= not clk after 5 ns;
   cpu_step <= '1' when step_counter = 0 else '0';

   process(clk)
   begin
      if rising_edge(clk) then
         if reset = '1' or step_counter + 1 >= step_period then
            step_counter <= 0;
         else
            step_counter <= step_counter + 1;
         end if;
      end if;
   end process;

   boot : entity work.nds_cpu_boot_sequencer
      port map (
         clk => clk, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => x"020697D0", arm7_entry => x"00001000",
         arm9_current_sp => x"027E3F80", arm9_irq_sp => x"027E3FBC",
         arm9_saved_sp => x"027E3F80", arm7_current_sp => x"00003000",
         arm7_irq_sp => x"00003040", arm7_saved_sp => x"00003080",
         initial_cpsr => x"0000001F", cpu_reset => boot_reset,
         boot_ready => boot_ready, save9 => save9, save7 => save7
      );

   process(all)
   begin
      case pending_addr is
         when x"020697D0" => rdata <= x"E3A0C021"; -- mov r12,#0x21
         when x"020697D4" => rdata <= x"E3A03021"; -- mov r3,#0x21
         when x"020697D8" => rdata <= x"E1A00000"; -- nop
         when x"020697DC" => rdata <= x"E15C0003"; -- cmp r12,r3
         when x"020697E0" => rdata <= x"128DD004"; -- addne sp,sp,#4
         when x"020697E4" => rdata <= x"104C0003"; -- subne r0,r12,r3
         when x"020697E8" => rdata <= x"149DE004"; -- popne {lr}
         when x"020697EC" => rdata <= x"112FFF1E"; -- bxne lr
         when x"020697F0" => rdata <= x"E28EE001"; -- add lr,lr,#1
         when x"020697F4" => rdata <= x"E3A00053"; -- success marker
         when others => rdata <= x"EAFFFFFE";
      end case;
   end process;

   process(clk)
   begin
      if rising_edge(clk) then
         done <= '0';
         if reset = '1' then
            response_state <= response_idle;
            response_delay <= 0;
            pending_addr <= (others => '0');
         else
            case response_state is
               when response_idle =>
                  if ena = '1' then
                     pending_addr <= addr;
                     response_delay <= bus_response_delay_cycles;
                     response_state <= response_wait;
                  end if;
               when response_wait =>
                  if response_delay > 0 then
                     response_delay <= response_delay - 1;
                  else
                     done <= '1';
                     response_state <= response_release;
                  end if;
               when response_release =>
                  if ena = '1' and addr /= pending_addr then
                     -- The CPU may launch its next fetch on the completion
                     -- edge rather than holding enable while it waits.
                     pending_addr <= addr;
                     response_delay <= bus_response_delay_cycles;
                     response_state <= response_wait;
                  elsif ena = '0' then
                     response_state <= response_idle;
                  end if;
            end case;
         end if;
         if ena = '1' and addr = x"027E3F80" then
            stack_access_seen <= '1';
         end if;
      end if;
   end process;

   dut : entity work.gba_cpu
      generic map (
         is_simu => '1', is_arm9 => '1',
         arm9_casecmp_flow_telemetry => '1'
      )
      port map (
         clk100 => clk, gb_on => '1', reset => boot_reset,
         savestate_bus => save9, gb_bus_Adr => addr, gb_bus_rnw => rnw,
         gb_bus_ena => ena, gb_bus_acc => acc, gb_bus_dout => wdata,
         gb_bus_din => rdata, gb_bus_done => done,
         wait_cnt_value => (others => '0'), wait_cnt_update => '0',
         Underclock => "00", bus_lowbits => open, settle => '0',
         dma_on => '0', do_step => cpu_step, done => open,
         CPU_bus_idle => open,
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
         debug_cpu_execute_pc => debug_execute, debug_cpu_mixed => open,
         arm9_dtcm_region => open, arm9_dtcm_enable => open
      );

   process
   begin
      reset <= '1';
      wait until rising_edge(clk);
      reset <= '0';
      descriptor_valid <= '1';
      wait until boot_ready = '1';
      wait until debug_execute(31 downto 28) = x"F" for 200 us;
      -- The reused core's direct-boot restore keeps its internal IRQ-disable
      -- latch set here; that state is recorded but does not affect NE.
      assert debug_execute = x"F2121605"
         report "case-compare flow snapshot mismatch: " &
            to_hstring(debug_execute)
         severity failure;
      assert stack_access_seen = '0'
         report "POPNE executed despite equal normalized bytes"
         severity failure;
      report "PASS: equal case-folded bytes set Z and skip the NE return chain"
         severity note;
      stop;
      wait;
   end process;
end architecture;
