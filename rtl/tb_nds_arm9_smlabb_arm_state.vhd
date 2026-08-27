library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

-- Replays the exact native/hardware tail around the first r187 divergence.
-- The ARM9 must implement the ARMv5 signed-halfword multiply-accumulate and
-- remain in ARM state:
--
--   0205B05C  E28DD004  ADD sp,sp,#4
--   0205B060  E101218C  SMLABB r1,r12,r1,r2
--   0205B064  E1A01141  MOV r1,r1,ASR #2
--   0205B068  E5801000  STR r1,[r0]
--
-- r187 hardware instead retired 0205B066 after 0205B064. This regression
-- checks the complete retired-PC sequence and the architectural SMLABB value
-- written by the following ARM store.
entity tb_nds_arm9_smlabb_arm_state is
   generic (
      bus_response_delay_cycles : natural := 0;
      step_period : positive := 1
   );
end entity;

architecture sim of tb_nds_arm9_smlabb_arm_state is
   constant entry_address : std_logic_vector(31 downto 0) := x"0205B040";
   constant marker_address : std_logic_vector(31 downto 0) := x"04000000";

   signal clk, reset, descriptor_valid, boot_reset, boot_ready :
      std_logic := '0';
   signal save9, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata, debug_execute :
      std_logic_vector(31 downto 0);
   signal rnw, ena, bus_done, instruction_retired : std_logic := '0';
   signal acc : std_logic_vector(1 downto 0);
   signal cycles : unsigned(7 downto 0);
   signal cpu_step : std_logic := '1';
   signal step_counter : natural := 0;

   type response_state_t is
      (response_idle, response_wait, response_release);
   signal response_state : response_state_t := response_idle;
   signal response_delay : natural := 0;
   signal pending_addr, pending_wdata : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal pending_rnw : std_logic := '1';
   signal pending_acc : std_logic_vector(1 downto 0) := ACCESS_32BIT;
   signal marker_seen : std_logic := '0';
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
         arm9_entry => entry_address, arm7_entry => x"00001000",
         arm9_current_sp => x"0205C000", arm9_irq_sp => x"027E3FBC",
         arm9_saved_sp => x"0205C000", arm7_current_sp => x"00003000",
         arm7_irq_sp => x"00003040", arm7_saved_sp => x"00003080",
         initial_cpsr => x"0000001F", cpu_reset => boot_reset,
         boot_ready => boot_ready, save9 => save9, save7 => save7
      );

   process(all)
   begin
      case pending_addr is
         when x"0205B040" => rdata <= x"E59F0038"; -- LDR r0,=marker port
         when x"0205B044" => rdata <= x"E59F2038"; -- LDR r2,=accumulator
         when x"0205B048" => rdata <= x"E59FC038"; -- LDR r12,=multiplicand
         when x"0205B04C" => rdata <= x"E1A00000"; -- NOP
         when x"0205B050" => rdata <= x"E1A00000"; -- NOP
         when x"0205B054" => rdata <= x"E1A00000"; -- NOP
         when x"0205B058" => rdata <= x"E3A01003"; -- MOV r1,#3
         when x"0205B05C" => rdata <= x"E28DD004"; -- ADD sp,sp,#4
         when x"0205B060" => rdata <= x"E101218C"; -- SMLABB r1,r12,r1,r2
         when x"0205B064" => rdata <= x"E1A01141"; -- MOV r1,r1,ASR #2
         when x"0205B068" => rdata <= x"E5801000"; -- STR r1,[r0]
         when x"0205B06C" => rdata <= x"EAFFFFFE"; -- B .
         when x"0205B080" => rdata <= marker_address;
         when x"0205B084" => rdata <= x"000031B6";
         when x"0205B088" => rdata <= x"0000386B";
         when others => rdata <= (others => '0');
      end case;
   end process;

   process(clk)
   begin
      if rising_edge(clk) then
         bus_done <= '0';
         if reset = '1' then
            response_state <= response_idle;
            response_delay <= 0;
            pending_addr <= (others => '0');
            pending_wdata <= (others => '0');
            pending_rnw <= '1';
            pending_acc <= ACCESS_32BIT;
            marker_seen <= '0';
         else
            case response_state is
               when response_idle =>
                  if ena = '1' then
                     pending_addr <= addr;
                     pending_wdata <= wdata;
                     pending_rnw <= rnw;
                     pending_acc <= acc;
                     response_delay <= bus_response_delay_cycles;
                     response_state <= response_wait;
                  end if;
               when response_wait =>
                  if response_delay > 0 then
                     response_delay <= response_delay - 1;
                  else
                     -- The fetch side may change its visible candidate while
                     -- this latched request is outstanding. Completion and
                     -- read data belong to pending_*; the production arbiter
                     -- applies the same response ownership rule.
                     bus_done <= '1';
                     if pending_addr = marker_address and
                           pending_rnw = '0' then
                        assert pending_acc = ACCESS_32BIT
                           report "post-SMLABB ARM store was not 32-bit"
                           severity failure;
                        -- 0x386B * 3 + 0x31B6 = 0xDAF7; ASR #2 = 0x36BD.
                        assert pending_wdata = x"000036BD"
                           report "post-SMLABB MOV/STR value mismatch: " &
                              to_hstring(pending_wdata)
                           severity failure;
                        marker_seen <= '1';
                     end if;
                     response_state <= response_release;
                  end if;
               when response_release =>
                  -- A new fetch may become visible immediately after the CPU
                  -- consumes done. Capture it without requiring an ena-low
                  -- bubble, matching the production same-edge convention.
                  if ena = '1' and
                     (addr /= pending_addr or rnw /= pending_rnw) then
                     pending_addr <= addr;
                     pending_wdata <= wdata;
                     pending_rnw <= rnw;
                     pending_acc <= acc;
                     response_delay <= bus_response_delay_cycles;
                     response_state <= response_wait;
                  elsif ena = '0' then
                     response_state <= response_idle;
                  end if;
            end case;
         end if;
      end if;
   end process;

   dut : entity work.gba_cpu
      generic map (
         is_simu => '1', is_arm9 => '1',
         arm9_fetch_pc_telemetry => '0'
      )
      port map (
         clk100 => clk, gb_on => '1', reset => boot_reset,
         savestate_bus => save9, gb_bus_Adr => addr, gb_bus_rnw => rnw,
         gb_bus_ena => ena, gb_bus_acc => acc, gb_bus_dout => wdata,
         gb_bus_din => rdata, gb_bus_done => bus_done,
         wait_cnt_value => (others => '0'), wait_cnt_update => '0',
         Underclock => "00", bus_lowbits => open, settle => '0',
         dma_on => '0', do_step => cpu_step, done => open,
         CPU_bus_idle => open, PC_in_BIOS => open, lastread => open,
         jump_out => open, new_cycles_out => cycles,
         new_cycles_valid => instruction_retired,
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
      type pc_sequence_type is array (natural range <>) of
         std_logic_vector(31 downto 0);
      constant expected : pc_sequence_type := (
         x"0205B040", x"0205B044", x"0205B048", x"0205B04C",
         x"0205B050", x"0205B054", x"0205B058", x"0205B05C",
         x"0205B060", x"0205B064", x"0205B068"
      );
      variable retired : natural := 0;
   begin
      reset <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';
      descriptor_valid <= '1';
      wait until boot_ready = '1';
      while retired < expected'length loop
         wait until rising_edge(clk) and instruction_retired = '1';
         if debug_execute(31 downto 20) = x"020" then
            report "SMLABB regression retire[" & integer'image(retired) &
               "]=" & to_hstring(debug_execute)
               severity note;
            assert debug_execute(1 downto 0) = "00"
               report "ARM9 entered halfword/Thumb alignment at " &
                  to_hstring(debug_execute)
               severity failure;
            assert debug_execute = expected(retired)
               report "post-SMLABB retire PC mismatch index=" &
                  integer'image(retired) & " got=" &
                  to_hstring(debug_execute) & " expected=" &
                  to_hstring(expected(retired))
               severity failure;
            retired := retired + 1;
         end if;
      end loop;
      wait until marker_seen = '1' for 20 us;
      assert marker_seen = '1'
         report "post-SMLABB ARM marker store did not complete"
         severity failure;
      report "PASS: ARM9 SMLABB computes native result and preserves ARM state"
         severity note;
      stop;
      wait;
   end process;

   process
   begin
      wait for 500 us;
      assert false
         report "timeout waiting for ARM9 SMLABB-to-MOV regression"
         severity failure;
      wait;
   end process;
end architecture;
