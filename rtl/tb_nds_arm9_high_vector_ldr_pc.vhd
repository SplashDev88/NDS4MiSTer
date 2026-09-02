library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

entity tb_nds_arm9_high_vector_ldr_pc is
   generic (
      irq_assert_delay_cycles : natural := 0;
      bus_response_delay_cycles : natural := 0
   );
end entity;

architecture sim of tb_nds_arm9_high_vector_ldr_pc is
   signal clk, reset, descriptor_valid, boot_reset, boot_ready : std_logic := '0';
   signal save9, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata, debug_pc, debug_mixed :
      std_logic_vector(31 downto 0);
   signal rnw, ena, done : std_logic;
   signal acc : std_logic_vector(1 downto 0);
   signal pending : std_logic := '0';
   signal pending_wait : natural := 0;
   signal request_addr : std_logic_vector(31 downto 0) := (others => '0');
   signal request_wdata : std_logic_vector(31 downto 0) := (others => '0');
   signal request_rnw : std_logic := '1';
   type irq_stack_type is array (0 to 31) of std_logic_vector(31 downto 0);
   signal irq_stack : irq_stack_type := (others => x"A5A5A5A5");
   signal irq : std_logic := '0';
   signal saw_vector_read, saw_target, saw_high_irq_vector : std_logic := '0';
   signal saw_low_irq_vector : std_logic := '0';
   signal saw_irq_return : std_logic := '0';
begin
   clk <= not clk after 5 ns;

   boot : entity work.nds_cpu_boot_sequencer
      port map (
         clk => clk, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => x"FFFF012C", arm7_entry => x"00001000",
         arm9_current_sp => x"027E3F80", arm9_irq_sp => x"027E3FBC",
         arm9_saved_sp => x"027E3F80", arm7_current_sp => x"00003000",
         arm7_irq_sp => x"00003040", arm7_saved_sp => x"00003080",
         initial_cpsr => x"0000001F", cpu_reset => boot_reset,
         boot_ready => boot_ready, save9 => save9, save7 => save7
      );

   process(all)
   begin
      if unsigned(request_addr) >= unsigned'(x"027E3F40") and
         unsigned(request_addr) < unsigned'(x"027E3FC0") then
         rdata <= irq_stack(
            to_integer(unsigned(request_addr(6 downto 2))));
      else case request_addr is
         when x"FFFF012C" => rdata <= x"E3A0C00B"; -- mov r12,#11
         when x"FFFF0130" => rdata <= x"E79FF10C"; -- ldr pc,[pc,r12,lsl#2]
         when x"FFFF0164" => rdata <= x"FFFF0200";
         when x"FFFF0200" => rdata <= x"E3A0001F"; -- mov r0,#0x1f
         when x"FFFF0204" => rdata <= x"E129F000"; -- msr cpsr_fc,r0
         when x"FFFF0208" => rdata <= x"E59FF000"; -- ldr pc,[pc]
         when x"FFFF0210" => rdata <= x"0207CCA0";
         -- Exact local polling shape immediately preceding the hardware IRQ.
         -- R5 resets to zero and the default address-zero read has a zero low
         -- halfword, so BNE continuously returns to the LDRH.
         when x"0207CCA0" => rdata <= x"E1D500B0"; -- ldrh r0,[r5]
         when x"0207CCA4" => rdata <= x"E3500001"; -- cmp r0,#1
         when x"0207CCA8" => rdata <= x"1AFFFFFC"; -- bne 0207cca0
         when x"FFFF0018" => rdata <= x"EA0001AE"; -- branch to BIOS IRQ handler
         -- Exact ARM9 BIOS IRQ save/dispatch/restore sequence.
         when x"FFFF06D8" => rdata <= x"E92D500F"; -- stmdb sp!,{r0-r3,r12,lr}
         when x"FFFF06DC" => rdata <= x"EE190F11"; -- mrc p15,0,r0,c9,c1,0
         when x"FFFF06E0" => rdata <= x"E3C000FF"; -- bic r0,r0,#0xff
         when x"FFFF06E4" => rdata <= x"E2800901"; -- add r0,r0,#0x4000
         when x"FFFF06E8" => rdata <= x"E1A0E00F"; -- mov lr,pc
         when x"FFFF06EC" => rdata <= x"E510F004"; -- ldr pc,[r0,#-4]
         when x"03003FFC" => rdata <= x"01FFD5E4"; -- reset DTCM IRQ vector
         -- Model the real handler's second stack frame and a nested BL.  This
         -- overwrites live R14_irq, then must restore the BIOS-wrapper link
         -- before returning to FFFF06F0.
         when x"01FFD5E4" => rdata <= x"E92D47F0"; -- stmdb sp!,{r4-r10,lr}
         when x"01FFD5E8" => rdata <= x"E24DD008"; -- sub sp,sp,#8
         when x"01FFD5EC" => rdata <= x"EB000007"; -- bl 01ffd610
         when x"01FFD5F0" => rdata <= x"E1500000"; -- cmp r0,r0 (Z=1)
         when x"01FFD5F4" => rdata <= x"028DD008"; -- addeq sp,sp,#8
         when x"01FFD5F8" => rdata <= x"08BD47F0"; -- ldmiaeq sp!,{r4-r10,lr}
         when x"01FFD5FC" => rdata <= x"012FFF1E"; -- bxeq lr
         when x"01FFD610" => rdata <= x"E12FFF1E"; -- bx lr
         when x"FFFF06F0" => rdata <= x"E8BD500F"; -- ldmia sp!,{r0-r3,r12,lr}
         when x"FFFF06F4" => rdata <= x"E25EF004"; -- subs pc,lr,#4
         when others => rdata <= x"E1A00000";
      end case; end if;
   end process;

   process(clk)
   begin
      if rising_edge(clk) then
         done <= '0';
         if boot_reset = '1' then
            pending <= '0';
            pending_wait <= 0;
         elsif pending = '0' and ena = '1' then
            request_addr <= addr;
            request_wdata <= wdata;
            request_rnw <= rnw;
            pending <= '1';
            pending_wait <= bus_response_delay_cycles;
         elsif pending = '1' and pending_wait /= 0 then
            pending_wait <= pending_wait - 1;
         elsif pending = '1' then
            done <= '1';
            pending <= '0';
            if request_rnw = '0' and
               unsigned(request_addr) >= unsigned'(x"027E3F40") and
               unsigned(request_addr) < unsigned'(x"027E3FC0") then
               irq_stack(to_integer(unsigned(request_addr(6 downto 2)))) <=
                  request_wdata;
            end if;
            if request_rnw = '1' and request_addr = x"FFFF0164" then
               saw_vector_read <= '1';
            elsif request_rnw = '1' and request_addr = x"0207CCA0" then
               saw_target <= '1';
            elsif request_rnw = '1' and request_addr = x"FFFF0018" then
               saw_high_irq_vector <= '1';
            elsif request_rnw = '1' and request_addr = x"00000018" then
               saw_low_irq_vector <= '1';
            end if;
            if request_rnw = '1' and saw_high_irq_vector = '1' and
               request_addr(31 downto 4) = x"0207CCA" then
               saw_irq_return <= '1';
            end if;
         end if;
      end if;
   end process;

   dut : entity work.gba_cpu
      generic map (
         is_simu => '1', is_arm9 => '1',
         arm9_cp15_reset_control => x"00052078",
         arm9_bios_lr_telemetry => '1'
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
         dma_dword_cycles => '0', dma_toROM => '0', dma_init_cycles => '0',
         dma_cycles_adrup => (others => '0'), IRP_in => (others => '0'),
         cpu_IRP => irq, new_halt => '0', clear_halt => '0',
         DISPSTAT_debug => (others => '0'), debug_fifocount => 0,
         timerdebug0 => (others => '0'), timerdebug1 => (others => '0'),
         timerdebug2 => (others => '0'), timerdebug3 => (others => '0'),
         debug_cpu_pc => debug_pc, debug_cpu_execute_pc => open,
         debug_cpu_mixed => debug_mixed,
         arm9_dtcm_region => open, arm9_dtcm_enable => open
      );

   process
      variable saw_entry_snapshot, saw_lr_snapshot : boolean := false;
      variable saw_operand_snapshot, saw_result_snapshot : boolean := false;
      variable saw_target_snapshot : boolean := false;
      variable saw_decode_snapshot, saw_active_lr, saw_active_spsr :
         boolean := false;
      variable decode_snapshot : std_logic_vector(27 downto 0) :=
         (others => '0');
      variable operand_snapshot, target_snapshot : unsigned(27 downto 0) :=
         (others => '0');
   begin
      reset <= '1';
      wait until rising_edge(clk);
      reset <= '0';
      descriptor_valid <= '1';
      wait until boot_ready = '1';
      wait until saw_target = '1' for 200 us;
      assert saw_vector_read = '1'
         report "ARM9 high-vector register-offset LDR omitted FFFF0164 read"
         severity failure;
      assert saw_target = '1'
         report "ARM9 high-vector register-offset LDR did not branch to loaded PC"
         severity failure;
      for cycle in 1 to irq_assert_delay_cycles loop
         wait until rising_edge(clk);
      end loop;
      irq <= '1';
      wait until saw_high_irq_vector = '1' or saw_low_irq_vector = '1'
         for 200 us;
      irq <= '0';
      report "high-vector IRQ diagnostic pc=" & to_hstring(debug_pc) &
             " mixed=" & to_hstring(debug_mixed) severity note;
      assert saw_high_irq_vector = '1'
         report "ARM9 IRQ ignored CP15 high-vector selection" severity failure;
      assert saw_low_irq_vector = '0'
         report "ARM9 IRQ incorrectly fetched the low vector" severity failure;
      wait until saw_irq_return = '1' for 200 us;
      assert saw_irq_return = '1'
         report "ARM9 IRQ return used stale instruction data instead of R14_irq PC"
         severity failure;
      for cycle in 1 to 7000 loop
         wait until rising_edge(clk);
         case debug_pc(31 downto 28) is
            when x"F" => saw_entry_snapshot := true;
            when x"C" => saw_lr_snapshot := true;
            when x"A" =>
               saw_decode_snapshot := true;
               decode_snapshot := debug_pc(27 downto 0);
            when x"9" => saw_active_lr := true;
            when x"8" => saw_active_spsr := true;
            when x"E" =>
               saw_operand_snapshot := true;
               operand_snapshot := unsigned(debug_pc(27 downto 0));
            when x"D" => saw_result_snapshot := true;
            when x"B" =>
               saw_target_snapshot := true;
               target_snapshot := unsigned(debug_pc(27 downto 0));
            when others => null;
         end case;
      end loop;
      assert saw_entry_snapshot and saw_lr_snapshot and
             saw_operand_snapshot and saw_result_snapshot and
             saw_target_snapshot and saw_decode_snapshot and
             saw_active_lr and saw_active_spsr
         report "persistent ARM9 IRQ telemetry omitted a pipeline snapshot"
         severity failure;
      assert decode_snapshot(27) = '1' and decode_snapshot(26) = '1' and
             decode_snapshot(25) = '1' and
             decode_snapshot(19 downto 16) = x"F" and
             decode_snapshot(15) = '1' and decode_snapshot(14) = '1' and
             decode_snapshot(13 downto 10) = x"E" and
             decode_snapshot(8) = '1' and decode_snapshot(7) = '1'
         report "SUBS PC,LR,#4 did not traverse the decoded IRQ-return ALU path"
         severity failure;
      assert target_snapshot = operand_snapshot - 4
         report "persistent ARM9 IRQ target does not match SUBS LR minus four"
         severity failure;
      report "PASS: ARM9 high-vector entry and architectural IRQ return"
         severity note;
      stop;
      wait;
   end process;
end architecture;
