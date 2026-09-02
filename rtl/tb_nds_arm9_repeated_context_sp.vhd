library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

-- Reproduce the native ARM9 scheduler/IRQ path that precedes Mario's failing
-- SDK epilogue. Every iteration:
--   * builds the real 0x01ffd22c stack frame in System mode;
--   * takes a high-vector IRQ;
--   * restores user/System R0-R14 through privileged LDMIB^;
--   * executes the native E82D500F/E8BD8000 IRQ tail; and
--   * consumes the restored R11/SP in
--       ADD sp,r11,#16; LDMIA sp!,{r11,pc}.
-- Native always launches the final reads at 0x027e3924/0x027e3928.
entity tb_nds_arm9_repeated_context_sp is
   generic (
      bus_response_delay_cycles : natural := 0;
      iterations : positive := 8
   );
end entity;

architecture sim of tb_nds_arm9_repeated_context_sp is
   type responder_state_t is (RESP_IDLE, RESP_WAIT, RESP_DONE, RESP_RELEASE);
   type stack_type is array (0 to 63) of std_logic_vector(31 downto 0);

   signal clk, reset, descriptor_valid, cpu_reset, boot_ready :
      std_logic := '0';
   signal save9, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata, debug_pc, execute_pc, debug_mixed :
      std_logic_vector(31 downto 0);
   signal rnw, ena, done : std_logic;
   signal acc : std_logic_vector(1 downto 0);
   signal irq : std_logic := '0';

   signal responder_state : responder_state_t := RESP_IDLE;
   signal pending_wait : natural := 0;
   signal request_addr, request_wdata, request_execute_pc :
      std_logic_vector(31 downto 0) := (others => '0');
   signal request_rnw : std_logic := '1';

   signal system_stack : stack_type := (others => x"A5A5A5A5");
   signal irq_stack : stack_type := (others => x"A5A5A5A5");

   signal body_count, vector_count, context_sp_count, return_word0_count,
      return_word1_count : natural := 0;
   signal irq_tail_write_count, irq_tail_pc_read_count, sp_marker_count :
      natural := 0;
   signal wrong_return_source, wrong_return_value : std_logic := '0';
   signal wrong_irq_tail, wrong_final_sp : std_logic := '0';
   signal wrong_source_addr, wrong_source_pc : std_logic_vector(31 downto 0) :=
      (others => '0');

   function context_word(a : std_logic_vector(31 downto 0))
      return std_logic_vector is
   begin
      case a is
         when x"00001000" => return x"2000001F"; -- resumed System CPSR
         -- LDMIB r1!,{r0-r14}^ context image. R11 and R13 match the
         -- native pre-epilogue frame; R14 is the loop return address.
         when x"00001004" => return x"11110000";
         when x"00001008" => return x"11110001";
         when x"0000100C" => return x"11110002";
         when x"00001010" => return x"11110003";
         when x"00001014" => return x"11110004";
         when x"00001018" => return x"11110005";
         when x"0000101C" => return x"11110006";
         when x"00001020" => return x"11110007";
         when x"00001024" => return x"11110008";
         when x"00001028" => return x"11110009";
         when x"0000102C" => return x"1111000A";
         when x"00001030" => return x"027E3914"; -- System R11
         when x"00001034" => return x"1111000C";
         when x"00001038" => return x"027E3914"; -- System SP in function
         when x"0000103C" => return x"00000200"; -- System LR
         when x"00001040" => return x"01FF8224"; -- native-shaped IRQ LR
         when x"00001044" => return x"027E0830"; -- temporary SVC SP
         when others => return x"00000000";
      end case;
   end function;

   function program_word(a : std_logic_vector(31 downto 0))
      return std_logic_vector is
   begin
      case a is
         -- Bootstrap and loop driver.
         -- The boot sequencer deliberately starts the reused CPU in SVC.
         -- Switch to System so the saved user/System SP becomes live.
         when x"00000000" => return x"E3A0301F"; -- mov r3,#0x1f
         when x"00000004" => return x"E121F003"; -- msr cpsr_c,r3
         when x"00000008" => return x"E59FE008"; -- ldr lr,[pc,#8]
         when x"0000000C" => return x"E59FF008"; -- ldr pc,[pc,#8]
         when x"00000018" => return x"00000200";
         when x"0000001C" => return x"01FFD22C";
         when x"00000200" => return x"E1A0000D"; -- mov r0,sp
         when x"00000204" => return x"E59F2018"; -- ldr r2,[pc,#0x18]
         when x"00000208" => return x"E5820000"; -- publish final SP
         when x"0000020C" => return x"E59FE008"; -- ldr lr,[pc,#8]
         when x"00000210" => return x"E59FF008"; -- ldr pc,[pc,#8]
         when x"0000021C" => return x"00000200";
         when x"00000220" => return x"01FFD22C";
         when x"00000224" => return x"00000900";

         -- Exact native function frame and failing epilogue addresses.
         when x"01FFD22C" => return x"E92D4800"; -- push {r11,lr}
         when x"01FFD230" => return x"E24DD010"; -- sub sp,sp,#16
         when x"01FFD234" => return x"E1A0B00D"; -- mov r11,sp
         when x"01FFD238" => return x"E1A00000"; -- interruptible body
         when x"01FFD23C" => return x"E1A00000";
         when x"01FFD240" => return x"E1A00000";
         when x"01FFD244" => return x"E1A00000";
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
         when x"01FFD274" => return x"E1A00000";
         when x"01FFD278" => return x"E1A00000";
         when x"01FFD27C" => return x"E28BD010"; -- add sp,r11,#16
         when x"01FFD280" => return x"E8BD8800"; -- pop {r11,pc}

         -- Exact ARM9 high-vector BIOS dispatch.
         when x"FFFF0018" => return x"EA0001AE";
         when x"FFFF06D8" => return x"E92D500F";
         when x"FFFF06DC" => return x"EE190F11";
         when x"FFFF06E0" => return x"E3C000FF";
         when x"FFFF06E4" => return x"E2800901";
         when x"FFFF06E8" => return x"E1A0E00F";
         when x"FFFF06EC" => return x"E510F004";
         when x"03003FFC" => return x"00000500";
         when x"FFFF06F0" => return x"E8BD500F";
         when x"FFFF06F4" => return x"E25EF004";

         -- SDK-shaped IRQ->SVC->IRQ context restore and exact native tail.
         when x"00000500" => return x"E59F1054"; -- ldr r1,[pc,#0x54]
         when x"00000504" => return x"E24DD02C"; -- IRQ sp 3fa4 -> 3f78
         when x"00000508" => return x"E3A030D3"; -- mov r3,#svc
         when x"0000050C" => return x"E121F003"; -- msr cpsr_c,r3
         when x"00000510" => return x"E591D044"; -- ldr sp,[r1,#0x44]
         when x"00000514" => return x"E3A030D2"; -- mov r3,#irq
         when x"00000518" => return x"E121F003"; -- msr cpsr_c,r3
         when x"0000051C" => return x"E5B12000"; -- ldr r2,[r1,#0]!
         when x"00000520" => return x"E169F002"; -- msr spsr_fc,r2
         when x"00000524" => return x"E591E040"; -- ldr lr,[r1,#0x40]
         when x"00000528" => return x"E9F17FFF"; -- ldmib r1!,{r0-r14}^
         when x"0000052C" => return x"E1A00000"; -- required interlock nop
         when x"00000530" => return x"E82D500F"; -- native stmda tail
         when x"00000534" => return x"E8BD8000"; -- pop continuation PC
         when x"0000055C" => return x"00001000";
         when x"00000560" => return x"E28DD040"; -- IRQ sp 3f64 -> 3fa4
         when x"00000564" => return x"E59FE008"; -- reload BIOS wrapper LR
         when x"00000568" => return x"E12FFF1E"; -- bx lr
         when x"00000574" => return x"FFFF06F0";
         when others => return x"E1A00000";
      end case;
   end function;
begin
   clk <= not clk after 5 ns;

   boot : entity work.nds_cpu_boot_sequencer
      port map (
         clk => clk, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => x"00000000", arm7_entry => x"00002000",
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
      elsif unsigned(request_addr) >= unsigned'(x"00001000") and
            unsigned(request_addr) <= unsigned'(x"00001044") then
         rdata <= context_word(request_addr);
      else
         rdata <= program_word(request_addr);
      end if;
   end process;

   process(clk)
      variable index : integer;
   begin
      if rising_edge(clk) then
         done <= '0';
         if cpu_reset = '1' then
            responder_state <= RESP_IDLE;
            pending_wait <= 0;
            system_stack <= (others => x"A5A5A5A5");
            irq_stack <= (others => x"A5A5A5A5");
            -- E8BD8000 reads this untouched word after E82D500F writes the
            -- six words above it and rolls IRQ SP from 0x3f78 to 0x3f60.
            irq_stack(to_integer(unsigned'(x"60") / 4)) <= x"00000560";
         else
            case responder_state is
               when RESP_IDLE =>
                  if ena = '1' then
                     request_addr <= addr;
                     request_wdata <= wdata;
                     request_rnw <= rnw;
                     request_execute_pc <= execute_pc;
                     pending_wait <= bus_response_delay_cycles;
                     responder_state <= RESP_WAIT;
                  end if;
               when RESP_WAIT =>
                  if pending_wait = 0 then
                     responder_state <= RESP_DONE;
                  else
                     pending_wait <= pending_wait - 1;
                  end if;
               when RESP_DONE =>
                  done <= '1';
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

                  if request_execute_pc = x"00000530" then
                     if request_rnw = '0' and
                        unsigned(request_addr) >= unsigned'(x"027E3F64") and
                        unsigned(request_addr) <= unsigned'(x"027E3F78") and
                        request_addr(1 downto 0) = "00" then
                        irq_tail_write_count <= irq_tail_write_count + 1;
                     elsif request_rnw = '0' then
                        wrong_irq_tail <= '1';
                     end if;
                  end if;
                  if request_execute_pc = x"00000534" and
                     request_rnw = '1' and
                     unsigned(request_addr) >= unsigned'(x"027E3F00") and
                     unsigned(request_addr) < unsigned'(x"027E4000") then
                     if request_addr = x"027E3F60" and
                        rdata = x"00000560" then
                        irq_tail_pc_read_count <= irq_tail_pc_read_count + 1;
                     else
                        wrong_irq_tail <= '1';
                     end if;
                  end if;

                  if request_rnw = '1' and request_addr = x"01FFD238" then
                     body_count <= body_count + 1;
                  elsif request_rnw = '1' and request_addr = x"FFFF0018" then
                     vector_count <= vector_count + 1;
                  elsif request_rnw = '1' and request_addr = x"00001038" then
                     context_sp_count <= context_sp_count + 1;
                  elsif request_rnw = '1' and
                        request_addr = x"027E3924" then
                     return_word0_count <= return_word0_count + 1;
                     if request_execute_pc /= x"01FFD280" then
                        wrong_return_source <= '1';
                        wrong_source_addr <= request_addr;
                        wrong_source_pc <= request_execute_pc;
                     end if;
                  elsif request_rnw = '1' and
                        request_addr = x"027E3928" then
                     return_word1_count <= return_word1_count + 1;
                     if request_execute_pc /= x"01FFD280" then
                        wrong_return_source <= '1';
                        wrong_source_addr <= request_addr;
                        wrong_source_pc <= request_execute_pc;
                     end if;
                     if rdata /= x"00000200" then
                        wrong_return_value <= '1';
                     end if;
                  elsif request_rnw = '0' and request_addr = x"00000900" then
                     sp_marker_count <= sp_marker_count + 1;
                     if request_wdata /= x"027E392C" then
                        wrong_final_sp <= '1';
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
         is_simu => '1', is_arm9 => '1',
         arm9_cp15_reset_control => x"00052078"
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

      for iteration in 1 to iterations loop
         wait until body_count >= iteration for 2 ms;
         assert body_count >= iteration
            report "ARM9 did not enter repeated SDK function iteration " &
                   integer'image(iteration)
            severity failure;
         irq <= '1';
         wait until vector_count >= iteration for 2 ms;
         assert vector_count >= iteration
            report "ARM9 did not take repeated IRQ iteration " &
                   integer'image(iteration)
            severity failure;
         irq <= '0';
         wait until return_word1_count >= iteration for 2 ms;
         assert return_word1_count >= iteration
            report "ARM9 did not reach repeated System stack return iteration " &
                   integer'image(iteration)
            severity failure;
         wait until sp_marker_count >= iteration for 2 ms;
         assert sp_marker_count >= iteration
            report "ARM9 did not publish the restored final SP iteration " &
                   integer'image(iteration)
            severity failure;
      end loop;

      assert context_sp_count >= iterations
         report "privileged LDMIB^ omitted a System SP restore"
         severity failure;
      assert return_word0_count = iterations and
             return_word1_count = iterations
         report "System epilogue did not consume exactly two stack words per iteration"
         severity failure;
      assert wrong_return_source = '0'
         report "System LDMIA sp!,{r11,pc} used source " &
                to_hstring(wrong_source_addr) & " at execute PC " &
                to_hstring(wrong_source_pc)
         severity failure;
      assert wrong_return_value = '0'
         report "System LDMIA sp!,{r11,pc} consumed a corrupt return PC"
         severity failure;
      assert irq_tail_write_count = 6 * iterations and
             irq_tail_pc_read_count = iterations and wrong_irq_tail = '0'
         report "native IRQ tail writes=" &
                integer'image(irq_tail_write_count) & " pc_reads=" &
                integer'image(irq_tail_pc_read_count) & " bad=" &
                std_logic'image(wrong_irq_tail)
         severity failure;
      assert sp_marker_count = iterations and wrong_final_sp = '0'
         report "repeated System epilogue did not restore SP to 0x027e392c"
         severity failure;
      report "PASS: repeated ARM9 SDK context restore preserves R11/SP through native IRQ tail and System epilogue"
         severity note;
      stop;
      wait;
   end process;
end architecture;
