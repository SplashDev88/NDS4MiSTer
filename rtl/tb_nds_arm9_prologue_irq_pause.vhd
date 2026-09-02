library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

-- Exercise the exact ARM9 scheduler prologue that precedes the observed
-- 0x01FFD27C/0x01FFD280 epilogue:
--   01FFD22C  E92D4800  push {r11,lr}
--   01FFD230  E24DD010  sub  sp,sp,#16
--   01FFD234  E1A0B00D  mov  r11,sp
--
-- Direct boot restores a native-valid System context with R11=0 and
-- SP=0x027E392C.  Therefore MOV must commit R11=0x027E3914, and the healthy
-- epilogue must subsequently read 0x027E3924 and 0x027E3928.
--
-- irq_boundary selects which instruction-fetch boundary receives a pending
-- IRQ while do_step is paused:
--   0 = PUSH, 1 = SUB, 2 = MOV.
entity tb_nds_arm9_prologue_irq_pause is
   generic (
      irq_boundary : natural range 0 to 2 := 0;
      bus_response_delay_cycles : natural := 3;
      pause_cycles : positive := 8
   );
end entity;

architecture sim of tb_nds_arm9_prologue_irq_pause is
   type responder_state_t is (RESP_IDLE, RESP_WAIT, RESP_DONE, RESP_RELEASE);
   type stack_type is array (0 to 63) of std_logic_vector(31 downto 0);
   type boundary_address_array_t is array (0 to 2) of
      std_logic_vector(31 downto 0);
   constant BOUNDARY_ADDRESS : boundary_address_array_t :=
      (x"01FFD22C", x"01FFD230", x"01FFD234");

   signal clk, reset, descriptor_valid, cpu_reset, boot_ready :
      std_logic := '0';
   signal save9, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata, execute_pc :
      std_logic_vector(31 downto 0);
   signal rnw, ena, bus_done : std_logic;
   signal acc : std_logic_vector(1 downto 0);
   signal irq : std_logic := '0';
   signal step_enable : std_logic := '1';

   signal responder_state : responder_state_t := RESP_IDLE;
   signal pending_wait : natural := 0;
   signal request_addr, request_wdata, request_execute_pc :
      std_logic_vector(31 downto 0) := (others => '0');
   signal request_rnw : std_logic := '1';

   signal system_stack : stack_type := (others => x"A5A5A5A5");
   signal irq_stack : stack_type := (others => x"A5A5A5A5");

   signal boundary_request_seen : std_logic := '0';
   signal vector_count, r11_marker_count, sp_marker_count :
      natural := 0;
   signal push_r11_count, push_lr_count, pop_r11_count, pop_pc_count :
      natural := 0;
   signal bad_push, bad_pop, bad_r11_marker, bad_sp_marker :
      std_logic := '0';
   signal bad_address, bad_value, bad_pc :
      std_logic_vector(31 downto 0) := (others => '0');

   function program_word(a : std_logic_vector(31 downto 0))
      return std_logic_vector is
   begin
      case a is
         -- Direct boot begins in SVC, with the native-valid saved
         -- User/System bank holding R11=0 and SP=0x027E392C. Switch to
         -- IRQ-enabled System mode, then establish a known LR and branch to
         -- the native prologue without touching R11 or SP.
         when x"00000000" => return x"E3A0301F"; -- mov r3,#0x1f
         when x"00000004" => return x"E121F003"; -- msr cpsr_c,r3
         when x"00000008" => return x"E59FE008"; -- ldr lr,[pc,#8]
         when x"0000000C" => return x"E59FF008"; -- ldr pc,[pc,#8]
         when x"00000018" => return x"00000200";
         when x"0000001C" => return x"01FFD22C";

         -- The POP return target publishes the final System SP.
         when x"00000200" => return x"E1A0000D"; -- mov r0,sp
         when x"00000204" => return x"E59F2008"; -- ldr r2,[pc,#8]
         when x"00000208" => return x"E5820000"; -- str r0,[r2]
         when x"0000020C" => return x"EAFFFFFE"; -- b .
         when x"00000214" => return x"00000904";

         -- Exact native prologue PCs. The short body publishes the live R11
         -- before the epilogue restores the caller's original R11=0.
         when x"01FFD22C" => return x"E92D4800"; -- push {r11,lr}
         when x"01FFD230" => return x"E24DD010"; -- sub sp,sp,#16
         when x"01FFD234" => return x"E1A0B00D"; -- mov r11,sp
         when x"01FFD238" => return x"E1A0000B"; -- mov r0,r11
         when x"01FFD23C" => return x"E59F2030"; -- ldr r2,[pc,#0x30]
         when x"01FFD240" => return x"E5820000"; -- str r0,[r2]
         when x"01FFD244" => return x"EA00000C"; -- b 0x01ffd27c
         when x"01FFD248" => return x"E1A00000";
         when x"01FFD24C" => return x"E1A00000";
         when x"01FFD250" => return x"E1A00000";
         when x"01FFD254" => return x"E1A00000";
         when x"01FFD258" => return x"E1A00000";
         when x"01FFD25C" => return x"E1A00000";
         when x"01FFD260" => return x"E1A00000";
         when x"01FFD264" => return x"E1A00000";
         when x"01FFD268" => return x"E1A00000";
         when x"01FFD26C" => return x"E1A00000";
         when x"01FFD270" => return x"E1A00000";
         when x"01FFD274" => return x"00000900";
         when x"01FFD278" => return x"E1A00000";
         when x"01FFD27C" => return x"E28BD010"; -- add sp,r11,#16
         when x"01FFD280" => return x"E8BD8800"; -- pop {r11,pc}

         -- High-vector IRQ wrapper. Its banked IRQ stack preserves the
         -- interrupted System R11/SP and returns with SUBS pc,lr,#4.
         when x"FFFF0018" => return x"EA0001AE";
         when x"FFFF06D8" => return x"E92D500F"; -- push {r0-r3,r12,lr}
         when x"FFFF06DC" => return x"E8BD500F"; -- pop {r0-r3,r12,lr}
         when x"FFFF06E0" => return x"E25EF004"; -- subs pc,lr,#4
         when others => return x"E1A00000";
      end case;
   end function;
begin
   clk <= not clk after 5 ns;

   boot : entity work.nds_cpu_boot_sequencer
      port map (
         clk => clk, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => x"00000000", arm7_entry => x"00001000",
         arm9_current_sp => x"027E3FC0", arm9_irq_sp => x"027E3FBC",
         arm9_saved_sp => x"027E392C", arm7_current_sp => x"00003000",
         arm7_irq_sp => x"00003040", arm7_saved_sp => x"00003080",
         initial_cpsr => x"000000D3", cpu_reset => cpu_reset,
         boot_ready => boot_ready, save9 => save9, save7 => save7
      );

   process(all)
      variable index : integer;
   begin
      if unsigned(request_addr) >= unsigned'(x"027E3880") and
         unsigned(request_addr) < unsigned'(x"027E3980") then
         index := to_integer(unsigned(request_addr(7 downto 2)));
         rdata <= system_stack(index);
      elsif unsigned(request_addr) >= unsigned'(x"027E3F00") and
            unsigned(request_addr) < unsigned'(x"027E4000") then
         index := to_integer(unsigned(request_addr(7 downto 2)));
         rdata <= irq_stack(index);
      else
         rdata <= program_word(request_addr);
      end if;
   end process;

   process(clk)
      variable index : integer;
   begin
      if rising_edge(clk) then
         bus_done <= '0';
         if cpu_reset = '1' then
            responder_state <= RESP_IDLE;
            pending_wait <= 0;
            system_stack <= (others => x"A5A5A5A5");
            irq_stack <= (others => x"A5A5A5A5");
            boundary_request_seen <= '0';
            vector_count <= 0;
            r11_marker_count <= 0;
            sp_marker_count <= 0;
            push_r11_count <= 0;
            push_lr_count <= 0;
            pop_r11_count <= 0;
            pop_pc_count <= 0;
            bad_push <= '0';
            bad_pop <= '0';
            bad_r11_marker <= '0';
            bad_sp_marker <= '0';
         else
            case responder_state is
               when RESP_IDLE =>
                  if ena = '1' then
                     request_addr <= addr;
                     request_wdata <= wdata;
                     request_rnw <= rnw;
                     request_execute_pc <= execute_pc;
                     pending_wait <= bus_response_delay_cycles;
                     if rnw = '1' and
                        addr = BOUNDARY_ADDRESS(irq_boundary) then
                        boundary_request_seen <= '1';
                     end if;
                     responder_state <= RESP_WAIT;
                  end if;

               when RESP_WAIT =>
                  if pending_wait = 0 then
                     responder_state <= RESP_DONE;
                  else
                     pending_wait <= pending_wait - 1;
                  end if;

               when RESP_DONE =>
                  bus_done <= '1';

                  if request_rnw = '0' and
                     unsigned(request_addr) >= unsigned'(x"027E3880") and
                     unsigned(request_addr) < unsigned'(x"027E3980") then
                     index := to_integer(unsigned(request_addr(7 downto 2)));
                     system_stack(index) <= request_wdata;
                  elsif request_rnw = '0' and
                        unsigned(request_addr) >= unsigned'(x"027E3F00") and
                        unsigned(request_addr) < unsigned'(x"027E4000") then
                     index := to_integer(unsigned(request_addr(7 downto 2)));
                     irq_stack(index) <= request_wdata;
                  end if;

                  if request_rnw = '1' and
                     request_addr = x"FFFF0018" then
                     vector_count <= vector_count + 1;
                  end if;

                  if request_execute_pc = x"01FFD22C" and
                     request_rnw = '0' then
                     if request_addr = x"027E3924" then
                        push_r11_count <= push_r11_count + 1;
                        if request_wdata /= x"00000000" then
                           bad_push <= '1';
                           bad_address <= request_addr;
                           bad_value <= request_wdata;
                           bad_pc <= request_execute_pc;
                        end if;
                     elsif request_addr = x"027E3928" then
                        push_lr_count <= push_lr_count + 1;
                        if request_wdata /= x"00000200" then
                           bad_push <= '1';
                           bad_address <= request_addr;
                           bad_value <= request_wdata;
                           bad_pc <= request_execute_pc;
                        end if;
                     else
                        bad_push <= '1';
                        bad_address <= request_addr;
                        bad_value <= request_wdata;
                        bad_pc <= request_execute_pc;
                     end if;
                  end if;

                  if request_execute_pc = x"01FFD280" and
                     request_rnw = '1' and
                     unsigned(request_addr) >= unsigned'(x"027E3880") and
                     unsigned(request_addr) < unsigned'(x"027E3980") then
                     if request_addr = x"027E3924" then
                        pop_r11_count <= pop_r11_count + 1;
                        if rdata /= x"00000000" then
                           bad_pop <= '1';
                           bad_address <= request_addr;
                           bad_value <= rdata;
                           bad_pc <= request_execute_pc;
                        end if;
                     elsif request_addr = x"027E3928" then
                        pop_pc_count <= pop_pc_count + 1;
                        if rdata /= x"00000200" then
                           bad_pop <= '1';
                           bad_address <= request_addr;
                           bad_value <= rdata;
                           bad_pc <= request_execute_pc;
                        end if;
                     else
                        bad_pop <= '1';
                        bad_address <= request_addr;
                        bad_value <= rdata;
                        bad_pc <= request_execute_pc;
                     end if;
                  end if;

                  if request_rnw = '0' and
                     request_addr = x"00000900" then
                     r11_marker_count <= r11_marker_count + 1;
                     if request_wdata /= x"027E3914" then
                        bad_r11_marker <= '1';
                        bad_address <= request_addr;
                        bad_value <= request_wdata;
                        bad_pc <= request_execute_pc;
                     end if;
                  elsif request_rnw = '0' and
                        request_addr = x"00000904" then
                     sp_marker_count <= sp_marker_count + 1;
                     if request_wdata /= x"027E392C" then
                        bad_sp_marker <= '1';
                        bad_address <= request_addr;
                        bad_value <= request_wdata;
                        bad_pc <= request_execute_pc;
                     end if;
                  end if;

                  responder_state <= RESP_RELEASE;

               when RESP_RELEASE =>
                  if ena = '0' then
                     responder_state <= RESP_IDLE;
                  end if;
            end case;
         end if;
      end if;
   end process;

   dut : entity work.gba_cpu
      generic map (
         is_simu => '0', is_arm9 => '1',
         arm9_cp15_reset_control => x"00052078"
      )
      port map (
         clk100 => clk, gb_on => '1', reset => cpu_reset,
         savestate_bus => save9, gb_bus_Adr => addr, gb_bus_rnw => rnw,
         gb_bus_ena => ena, gb_bus_acc => acc, gb_bus_dout => wdata,
         gb_bus_din => rdata, gb_bus_done => bus_done,
         wait_cnt_value => (others => '0'), wait_cnt_update => '0',
         Underclock => "00", bus_lowbits => open, settle => '0',
         dma_on => '0', do_step => step_enable, done => open,
         CPU_bus_idle => open, PC_in_BIOS => open, lastread => open,
         jump_out => open, new_cycles_out => open, new_cycles_valid => open,
         dma_new_cycles => '0', dma_first_cycles => '0',
         dma_dword_cycles => '0', dma_toROM => '0',
         dma_init_cycles => '0', dma_cycles_adrup => (others => '0'),
         IRP_in => (others => '0'), cpu_IRP => irq, new_halt => '0',
         clear_halt => '0', DISPSTAT_debug => (others => '0'),
         debug_fifocount => 0, timerdebug0 => (others => '0'),
         timerdebug1 => (others => '0'), timerdebug2 => (others => '0'),
         timerdebug3 => (others => '0'), debug_cpu_pc => open,
         debug_cpu_execute_pc => open, debug_cpu_mixed => execute_pc,
         arm9_dtcm_region => open, arm9_dtcm_enable => open
      );

   process
   begin
      reset <= '1';
      wait until rising_edge(clk);
      reset <= '0';
      descriptor_valid <= '1';
      wait until boot_ready = '1';

      wait until boundary_request_seen = '1' for 100 us;
      assert boundary_request_seen = '1'
         report "ARM9 did not fetch selected prologue boundary " &
                integer'image(irq_boundary)
         severity failure;

      -- Make the IRQ pending while the selected fetch is outstanding, then
      -- prove shared-oracle pause prevents acceptance until do_step resumes.
      step_enable <= '0';
      irq <= '1';
      for i in 1 to pause_cycles loop
         wait until rising_edge(clk);
      end loop;
      assert vector_count = 0
         report "ARM9 accepted IRQ while prologue boundary was paused"
         severity failure;
      assert r11_marker_count = 0
         report "ARM9 passed the selected prologue boundary while paused"
         severity failure;

      step_enable <= '1';
      wait until vector_count >= 1 for 100 us;
      assert vector_count >= 1
         report "pending IRQ was not accepted after prologue pause released"
         severity failure;
      irq <= '0';

      wait until r11_marker_count >= 1 for 500 us;
      wait until pop_pc_count >= 1 for 500 us;
      wait until sp_marker_count >= 1 for 500 us;

      assert r11_marker_count = 1 and bad_r11_marker = '0'
         report "MOV r11,sp did not commit 0x027E3914; value=" &
                to_hstring(bad_value) & " pc=" & to_hstring(bad_pc)
         severity failure;
      assert push_r11_count = 1 and push_lr_count = 1 and bad_push = '0'
         report "native PUSH did not preserve caller R11=0/LR=0x200; addr=" &
                to_hstring(bad_address) & " value=" &
                to_hstring(bad_value)
         severity failure;
      assert pop_r11_count = 1 and pop_pc_count = 1 and bad_pop = '0'
         report "healthy epilogue did not read 0x027E3924/28; addr=" &
                to_hstring(bad_address) & " value=" &
                to_hstring(bad_value)
         severity failure;
      assert sp_marker_count = 1 and bad_sp_marker = '0'
         report "healthy epilogue did not restore System SP=0x027E392C"
         severity failure;
      assert vector_count = 1
         report "selected prologue boundary produced repeated IRQ entries"
         severity failure;

      report "PASS: ARM9 prologue boundary " &
             integer'image(irq_boundary) &
             " preserves MOV R11=0x027E3914 and POP sources 0x027E3924/28"
         severity note;
      stop;
      wait;
   end process;
end architecture;
