library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

-- Match the ordering immediately before the failing Mario IRQ: a supervisor
-- LDM^ restores a System context with a stale SVC LR, then ARM9 takes an IRQ.
-- The IRQ return must use the new exception LR, not the prior context LR.
entity tb_nds_arm9_context_restore_irq is
   generic (
      irq_assert_delay_cycles : natural := 0;
      bus_response_delay_cycles : natural := 0
   );
end entity;

architecture sim of tb_nds_arm9_context_restore_irq is
   signal clk, reset, descriptor_valid, cpu_reset, boot_ready : std_logic := '0';
   signal save9, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata, debug_pc, execute_pc, debug_mixed :
      std_logic_vector(31 downto 0);
   signal rnw, ena, done : std_logic;
   signal acc : std_logic_vector(1 downto 0);
   signal irq : std_logic := '0';
   signal pending : std_logic := '0';
   signal pending_wait : natural := 0;
   signal request_addr : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal request_wdata : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal request_rnw : std_logic := '1';
   type stack_type is array (0 to 31) of std_logic_vector(31 downto 0);
   signal irq_stack : stack_type := (others => x"A5A5A5A5");
   signal saw_system_entry, saw_marker, saw_irq_vector, saw_epilogue :
      std_logic := '0';
   signal resumed_system_sp : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal saw_resume : std_logic := '0';
   signal resume_address : std_logic_vector(31 downto 0) := (others => '0');
   signal saw_bios_sp_marker : std_logic := '0';
   signal bios_sp_marker : std_logic_vector(31 downto 0) := (others => '0');
   signal saw_post_ldm_sp_marker : std_logic := '0';
   signal post_ldm_sp_marker : std_logic_vector(31 downto 0) := (others => '0');
   signal saw_handler_lr_save : std_logic := '0';
   signal handler_lr_save : std_logic_vector(31 downto 0) := (others => '0');

   function program_word(a : std_logic_vector(31 downto 0))
      return std_logic_vector is
   begin
      case a is
         when x"00000000" => return x"E59F0058"; -- ldr r0,[pc,#0x58]
         when x"00000004" => return x"E4901004"; -- ldr r1,[r0],#4
         when x"00000008" => return x"E16FF001"; -- msr spsr_fsxc,r1
         when x"0000000C" => return x"E590D040"; -- ldr sp,[r0,#64]
         when x"00000010" => return x"E590E03C"; -- ldr lr,[r0,#60]
         when x"00000014" => return x"E8D07FFF"; -- ldm r0,{r0-r14}^
         when x"00000018" => return x"E1A00000";
         when x"0000001C" => return x"E25EF004"; -- subs pc,lr,#4
         when x"00000060" => return x"00000100";

         -- Saved System context. The SVC return word sends execution to 0x300.
         when x"00000100" => return x"0000001F";
         when x"00000104" => return x"11110000";
         when x"00000108" => return x"11110001";
         when x"0000010C" => return x"11110002";
         when x"00000110" => return x"11110003";
         when x"00000114" => return x"11110004";
         when x"00000118" => return x"11110005";
         when x"0000011C" => return x"11110006";
         when x"00000120" => return x"11110007";
         when x"00000124" => return x"11110008";
         when x"00000128" => return x"11110009";
         when x"0000012C" => return x"1111000A";
         when x"00000130" => return x"1111000B";
         when x"00000134" => return x"1111000C";
         when x"00000138" => return x"00000700";
         when x"0000013C" => return x"DEAD000E";
         when x"00000140" => return x"00000304";
         -- User/System context consumed by the real SDK-shaped LDMIB^.
         when x"00001004" => return x"22220000";
         when x"00001008" => return x"22220001";
         when x"0000100C" => return x"22220002";
         when x"00001010" => return x"22220003";
         when x"00001014" => return x"22220004";
         when x"00001018" => return x"22220005";
         when x"0000101C" => return x"22220006";
         when x"00001020" => return x"22220007";
         when x"00001024" => return x"22220008";
         when x"00001028" => return x"22220009";
         when x"0000102C" => return x"2222000A";
         when x"00001030" => return x"2222000B";
         when x"00001034" => return x"2222000C";
         when x"00001038" => return x"2222000D";
         when x"0000103C" => return x"01FFA7DC"; -- stale user LR

         -- The pending IRQ can be accepted after the first restored
         -- instruction has already decoded. Branch after the return so the
         -- SP marker is read from a freshly decoded System-mode instruction.
         when x"00000300" => return x"E1A00000"; -- nop
         when x"00000304" => return x"E1A00000"; -- nop
         when x"00000308" => return x"EA000004"; -- b 0x320
         when x"00000320" => return x"E1A0000D"; -- mov r0,sp
         when x"00000324" => return x"E59F2008"; -- ldr r2,[pc,#8]
         when x"00000328" => return x"E5820000"; -- str r0,[r2]
         when x"0000032C" => return x"EAFFFFFE"; -- b .
         when x"00000334" => return x"00000900";

         -- Exact ARM9 high-vector BIOS dispatch shape.
         when x"FFFF0018" => return x"EA0001AE";
         when x"FFFF06D8" => return x"E92D500F";
         when x"FFFF06DC" => return x"EE190F11";
         when x"FFFF06E0" => return x"E3C000FF";
         when x"FFFF06E4" => return x"E2800901";
         when x"FFFF06E8" => return x"E1A0E00F";
         when x"FFFF06EC" => return x"E510F004";
         when x"03003FFC" => return x"00000500";
         when x"00000500" => return x"E1A0000D"; -- mov r0,sp
         when x"00000504" => return x"E59F2034"; -- ldr r2,[pc,#0x34]
         when x"00000508" => return x"E5820000"; -- str r0,[r2]
         when x"0000050C" => return x"E59F1030"; -- ldr r1,[pc,#0x30]
         when x"00000510" => return x"E9F17FFF"; -- ldmib r1!,{r0-r14}^
         when x"00000514" => return x"E1A0000D"; -- mov r0,sp
         when x"00000518" => return x"E59F2028"; -- ldr r2,[pc,#0x28]
         when x"0000051C" => return x"E5820000"; -- str r0,[r2]
         when x"00000520" => return x"E92D500F"; -- push {r0-r3,r12,lr}
         when x"00000524" => return x"E8BD500F"; -- pop {r0-r3,r12,lr}
         when x"00000528" => return x"E12FFF1E"; -- bx lr
         when x"00000540" => return x"00000904";
         when x"00000544" => return x"00001000";
         when x"00000548" => return x"00000908";
         when x"FFFF06F0" => return x"E8BD500F";
         when x"FFFF06F4" => return x"E25EF004";
         when others => return x"E1A00000";
      end case;
   end function;
begin
   clk <= not clk after 5 ns;

   boot : entity work.nds_cpu_boot_sequencer
      port map (
         clk => clk, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => x"00000000", arm7_entry => x"00001000",
         arm9_current_sp => x"00000800", arm9_irq_sp => x"027E3FBC",
         arm9_saved_sp => x"00000880", arm7_current_sp => x"00000800",
         arm7_irq_sp => x"00000840", arm7_saved_sp => x"00000880",
         initial_cpsr => x"000000D3", cpu_reset => cpu_reset,
         boot_ready => boot_ready, save9 => save9, save7 => save7
      );

   process(all)
   begin
      if unsigned(request_addr) >= unsigned'(x"027E3F40") and
         unsigned(request_addr) < unsigned'(x"027E3FC0") then
         rdata <= irq_stack(
            to_integer(unsigned(request_addr(6 downto 2))));
      else
         rdata <= program_word(request_addr);
      end if;
   end process;

   process(clk)
   begin
      if rising_edge(clk) then
         done <= '0';
         if cpu_reset = '1' then
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
               irq_stack(
                  to_integer(unsigned(request_addr(6 downto 2)))) <=
                     request_wdata;
               if request_addr = x"027E3FA0" then
                  handler_lr_save <= request_wdata;
                  saw_handler_lr_save <= '1';
               end if;
            end if;
            if request_rnw = '1' and request_addr = x"00000300" then
               saw_system_entry <= '1';
            elsif request_rnw = '0' and request_addr = x"00000900" then
               resumed_system_sp <= request_wdata;
               saw_marker <= '1';
            elsif request_rnw = '0' and request_addr = x"00000904" then
               bios_sp_marker <= request_wdata;
               saw_bios_sp_marker <= '1';
            elsif request_rnw = '0' and request_addr = x"00000908" then
               post_ldm_sp_marker <= request_wdata;
               saw_post_ldm_sp_marker <= '1';
            elsif request_rnw = '1' and request_addr = x"FFFF0018" then
               saw_irq_vector <= '1';
            elsif request_rnw = '1' and request_addr = x"FFFF06F4" then
               saw_epilogue <= '1';
            elsif request_rnw = '1' and saw_epilogue = '1' and
                  unsigned(request_addr) >= unsigned'(x"00000300") and
                  unsigned(request_addr) < unsigned'(x"00000400") and
                  saw_resume = '0' then
               resume_address <= request_addr;
               saw_resume <= '1';
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
         clk100 => clk, gb_on => '1', reset => cpu_reset,
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
         debug_cpu_pc => debug_pc, debug_cpu_execute_pc => execute_pc,
         debug_cpu_mixed => debug_mixed,
         arm9_dtcm_region => open, arm9_dtcm_enable => open
      );

   process
   begin
      reset <= '1';
      wait until rising_edge(clk);
      reset <= '0';
      descriptor_valid <= '1';
      wait until boot_ready = '1';
      -- Match the hardware edge case: the IRQ is already pending while the
      -- supervisor restore changes CPSR back to IRQ-enabled System mode.
      for i in 1 to irq_assert_delay_cycles loop
         wait until rising_edge(clk);
      end loop;
      irq <= '1';
      wait until saw_irq_vector = '1' for 30 us;
      irq <= '0';
      wait until saw_resume = '1' for 30 us;
      wait until saw_marker = '1' for 30 us;
      assert saw_system_entry = '1' and saw_marker = '1'
         report "supervisor LDM^ did not resume the restored System code"
         severity failure;
      assert saw_irq_vector = '1' and saw_epilogue = '1'
         report "ARM9 did not complete the high-vector IRQ wrapper"
         severity failure;
      assert saw_bios_sp_marker = '1' and bios_sp_marker = x"027E3FA4"
         report "ARM9 BIOS STMDB writeback was not base-24; SP=" &
                to_hstring(bios_sp_marker)
         severity failure;
      assert saw_post_ldm_sp_marker = '1' and
             post_ldm_sp_marker = bios_sp_marker
         report "privileged LDMIB^ changed the live IRQ SP from " &
                to_hstring(bios_sp_marker) & " to " &
                to_hstring(post_ldm_sp_marker)
         severity failure;
      assert saw_handler_lr_save = '1' and handler_lr_save = x"FFFF06F0"
         report "ARM9 handler did not save the live IRQ link at SP-4; saved " &
                to_hstring(handler_lr_save)
         severity failure;
      assert saw_resume = '1'
         report "ARM9 did not return to the interrupted System context"
         severity failure;
      assert resumed_system_sp = x"2222000D"
         report "privileged LDMIB^ did not restore the live System SP; got " &
                to_hstring(resumed_system_sp)
         severity failure;
      assert unsigned(resume_address) >= unsigned'(x"00000300") and
             unsigned(resume_address) <= unsigned'(x"0000032C")
         report "IRQ returned outside the restored System code: " &
                to_hstring(resume_address)
         severity failure;
      report "PASS: supervisor LDM^ cannot contaminate the following ARM9 IRQ return"
         severity note;
      stop;
      wait;
   end process;
end architecture;
