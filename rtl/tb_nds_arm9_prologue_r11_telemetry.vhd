library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

-- Directed r183 regression. Each invocation briefly writes R11=0 and then
-- restores it, proving that a recovered bad interval does not freeze. The
-- first IRQ context restore is healthy at a deliberately non-native frame
-- pointer, 0x027E38D4. Its valid R15 source 0x027E38E8 proves the observer
-- derives the final address per invocation rather than accepting a fixed
-- 0x027E3928. The second restore returns zero for System R11, remains
-- unrecovered, and drives the known final POP from 0x10/0x14. The test
-- reconstructs and verifies all eight self-describing D8 pages.
entity tb_nds_arm9_prologue_r11_telemetry is
end entity;

architecture sim of tb_nds_arm9_prologue_r11_telemetry is
   type responder_state_t is
      (RESP_IDLE, RESP_WAIT, RESP_DONE, RESP_RELEASE);
   type stack_type is array (0 to 63) of std_logic_vector(31 downto 0);
   type page_array_t is array (0 to 7) of std_logic_vector(31 downto 0);

   signal clk, reset, descriptor_valid, cpu_reset, boot_ready :
      std_logic := '0';
   signal save9, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata, debug_pc, execute_pc, debug_mixed :
      std_logic_vector(31 downto 0);
   signal rnw, ena, done : std_logic;
   signal acc : std_logic_vector(1 downto 0);
   signal irq, poison_context_r11 : std_logic := '0';

   signal responder_state : responder_state_t := RESP_IDLE;
   signal pending_wait : natural := 0;
   signal request_addr, request_wdata, request_execute_pc :
      std_logic_vector(31 downto 0) := (others => '0');
   signal request_rnw : std_logic := '1';
   signal system_stack : stack_type := (others => x"A5A5A5A5");
   signal irq_stack : stack_type := (others => x"A5A5A5A5");

   signal body_count, vector_count, final_return_count, marker_count :
      natural := 0;
   signal final_word_phase : std_logic := '0';
   signal first_r11_source, first_r15_source, second_r11_source,
      second_r15_source : std_logic_vector(31 downto 0) :=
      (others => '0');

   function context_word(
      a : std_logic_vector(31 downto 0);
      poison_r11 : std_logic)
      return std_logic_vector is
   begin
      case a is
         when x"00001000" => return x"2000001F";
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
         when x"00001030" =>
            if poison_r11 = '1' then return x"00000000";
            else return x"027E38D4";
            end if;
         when x"00001034" => return x"1111000C";
         when x"00001038" => return x"027E38D4";
         when x"0000103C" => return x"00000200";
         when x"00001040" => return x"01FF8224";
         when x"00001044" => return x"027E0830";
         when others => return x"00000000";
      end case;
   end function;

   function program_word(a : std_logic_vector(31 downto 0))
      return std_logic_vector is
   begin
      case a is
         when x"00000000" => return x"E3A0301F";
         when x"00000004" => return x"E121F003";
         when x"00000008" => return x"E59FE008";
         when x"0000000C" => return x"E59FF008";
         when x"00000018" => return x"00000200";
         when x"0000001C" => return x"01FFD22C";

         -- Return marker and next invocation.
         when x"00000200" => return x"E1A0000D";
         when x"00000204" => return x"E59F2018";
         when x"00000208" => return x"E5820000";
         when x"0000020C" => return x"E59FE008";
         when x"00000210" => return x"E59FF008";
         when x"0000021C" => return x"00000200";
         when x"00000220" => return x"01FFD22C";
         when x"00000224" => return x"00000900";

         -- Actual instruction addresses. Native JSON reports architectural
         -- R15 eight bytes ahead (MOV therefore appears as 01FFD23C).
         when x"01FFD22C" => return x"E92D4800"; -- push {r11,lr}
         when x"01FFD230" => return x"E24DD010"; -- sub sp,sp,#16
         when x"01FFD234" => return x"E1A0B00D"; -- mov r11,sp
         when x"01FFD238" => return x"E3A0B000"; -- temporary loss
         when x"01FFD23C" => return x"E1A0B00D"; -- recovery
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

         -- BIOS IRQ wrapper and synthetic SDK context restore.
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

         when x"00000500" => return x"E59F1054";
         when x"00000504" => return x"E24DD02C";
         when x"00000508" => return x"E3A030D3";
         when x"0000050C" => return x"E121F003";
         when x"00000510" => return x"E591D044";
         when x"00000514" => return x"E3A030D2";
         when x"00000518" => return x"E121F003";
         when x"0000051C" => return x"E5B12000";
         when x"00000520" => return x"E169F002";
         when x"00000524" => return x"E591E040";
         when x"00000528" => return x"E9F17FFF";
         when x"0000052C" => return x"E1A00000";
         when x"00000530" => return x"E82D500F";
         when x"00000534" => return x"E8BD8000";
         when x"0000055C" => return x"00001000";
         when x"00000560" => return x"E28DD040";
         when x"00000564" => return x"E59FE008";
         when x"00000568" => return x"E12FFF1E";
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
         -- Deliberately differ from the former fixed 0x027E3914 case: PUSH
         -- and the 16-byte allocation place the prologue SP at 0x027E38D4.
         arm9_current_sp => x"027E38EC", arm9_irq_sp => x"027E3FBC",
         arm9_saved_sp => x"027E38EC", arm7_current_sp => x"00003000",
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
         rdata <= context_word(request_addr, poison_context_r11);
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
            irq_stack(to_integer(unsigned'(x"60") / 4)) <= x"00000560";
         else
            case responder_state is
               when RESP_IDLE =>
                  if ena = '1' then
                     request_addr <= addr;
                     request_wdata <= wdata;
                     request_rnw <= rnw;
                     request_execute_pc <= execute_pc;
                     pending_wait <= 3;
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

                  if request_rnw = '1' and request_addr = x"01FFD240" then
                     body_count <= body_count + 1;
                  elsif request_rnw = '1' and request_addr = x"FFFF0018" then
                     vector_count <= vector_count + 1;
                  end if;

                  if request_rnw = '1' and
                     request_execute_pc = x"01FFD280" and
                     (request_addr = x"027E38E4" or
                      request_addr = x"027E38E8" or
                      request_addr = x"00000010" or
                      request_addr = x"00000014") then
                     if final_word_phase = '0' then
                        if final_return_count = 0 then
                           first_r11_source <= request_addr;
                        else
                           second_r11_source <= request_addr;
                        end if;
                        final_word_phase <= '1';
                     else
                        if final_return_count = 0 then
                           first_r15_source <= request_addr;
                        else
                           second_r15_source <= request_addr;
                        end if;
                        final_word_phase <= '0';
                        final_return_count <= final_return_count + 1;
                     end if;
                  end if;

                  if request_rnw = '0' and request_addr = x"00000900" then
                     marker_count <= marker_count + 1;
                  end if;
                  responder_state <= RESP_RELEASE;
               when RESP_RELEASE =>
                  if ena = '0' then responder_state <= RESP_IDLE; end if;
            end case;
         end if;
      end if;
   end process;

   dut : entity work.gba_cpu
      generic map (
         is_simu => '1', is_arm9 => '1',
         arm9_cp15_reset_control => x"00052078",
         arm9_prologue_r11_telemetry => '1'
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
         dma_dword_cycles => '0', dma_toROM => '0',
         dma_init_cycles => '0', dma_cycles_adrup => (others => '0'),
         IRP_in => (others => '0'), cpu_IRP => irq, new_halt => '0',
         clear_halt => '0', DISPSTAT_debug => (others => '0'),
         debug_fifocount => 0, timerdebug0 => (others => '0'),
         timerdebug1 => (others => '0'), timerdebug2 => (others => '0'),
         timerdebug3 => (others => '0'), debug_cpu_pc => debug_pc,
         debug_cpu_execute_pc => execute_pc,
         debug_cpu_mixed => debug_mixed, arm9_dtcm_region => open,
         arm9_dtcm_enable => open
      );

   process
      variable pages : page_array_t := (others => (others => '0'));
      variable seen : std_logic_vector(31 downto 0) := (others => '0');
      variable page_number, lane_number : natural;
   begin
      reset <= '1';
      wait until rising_edge(clk);
      reset <= '0';
      descriptor_valid <= '1';
      wait until boot_ready = '1';

      wait until body_count >= 1 for 2 ms;
      assert body_count >= 1
         report "first invocation did not pass temporary R11 recovery"
         severity failure;
      -- Let MOV r11,sp at 0x01FFD23C commit before injecting the IRQ.
      for i in 1 to 24 loop wait until rising_edge(clk); end loop;
      irq <= '1';
      wait until vector_count >= 1 for 2 ms;
      assert vector_count >= 1
         report "first invocation did not take IRQ" severity failure;
      irq <= '0';
      wait until final_return_count >= 1 for 2 ms;
      assert final_return_count >= 1
         report "first invocation did not complete final POP"
         severity failure;
      assert first_r11_source = x"027E38E4" and
             first_r15_source = x"027E38E8"
         report "recovered/healthy first invocation used bad POP sources"
         severity failure;
      wait until marker_count >= 1 for 2 ms;
      assert marker_count >= 1
         report "first invocation did not return" severity failure;
      wait until rising_edge(clk);
      wait for 0 ns;
      assert debug_mixed = execute_pc
         report "recovered R11 interval incorrectly froze telemetry: " &
                to_hstring(debug_mixed)
         severity failure;

      poison_context_r11 <= '1';
      wait until body_count >= 2 for 2 ms;
      assert body_count >= 2
         report "second invocation did not pass temporary R11 recovery"
         severity failure;
      for i in 1 to 24 loop wait until rising_edge(clk); end loop;
      irq <= '1';
      wait until vector_count >= 2 for 2 ms;
      assert vector_count >= 2
         report "second invocation did not take IRQ" severity failure;
      irq <= '0';
      wait until final_return_count >= 2 for 2 ms;
      assert final_return_count >= 2
         report "second invocation did not complete bad final POP"
         severity failure;
      assert second_r11_source = x"00000010" and
             second_r15_source = x"00000014"
         report "poisoned context did not drive bad POP sources"
         severity failure;

      -- Simulation advances one D8 lane every eight clocks. Capture duplicate
      -- records harmlessly until all 32 page/lane combinations are present.
      for sample in 0 to 1023 loop
         wait until rising_edge(clk);
         wait for 0 ns;
         if debug_mixed(31 downto 24) = x"D8" and
            debug_mixed(16) = '1' and
            debug_mixed(7 downto 0) = x"3C" then
            page_number := to_integer(unsigned(debug_mixed(23 downto 21)));
            lane_number := to_integer(unsigned(debug_mixed(20 downto 19)));
            pages(page_number)(lane_number * 8 + 7 downto lane_number * 8) :=
               debug_mixed(15 downto 8);
            seen(page_number * 4 + lane_number) := '1';
            exit when seen = x"FFFFFFFF";
         end if;
      end loop;
      assert seen = x"FFFFFFFF"
         report "did not observe all eight D8 telemetry pages"
         severity failure;
      assert pages(0) = x"027E38D4"
         report "pre-source SP mismatch: " & to_hstring(pages(0))
         severity failure;
      assert pages(1) = x"027E38D4"
         report "post-writeback R11 mismatch: " & to_hstring(pages(1))
         severity failure;
      assert pages(2) = x"00000528"
         report "loss-writer PC mismatch: " & to_hstring(pages(2))
         severity failure;
      assert pages(3) = x"E9F17FFF"
         report "loss-writer opcode mismatch: " & to_hstring(pages(3))
         severity failure;
      assert pages(4) = x"00001030"
         report "R11 block-source address mismatch: " &
                to_hstring(pages(4))
         severity failure;
      assert pages(5) = x"00000000"
         report "actual post-write R11 mismatch: " & to_hstring(pages(5))
         severity failure;
      assert pages(6) = x"2BBC0002"
         report "loss metadata mismatch: " & to_hstring(pages(6))
         severity failure;
      assert pages(7) = x"00000014"
         report "final bad R15 source mismatch: " & to_hstring(pages(7))
         severity failure;

      report "PASS: ARM9 r183 telemetry derives the healthy POP from non-default SP, ignores recovered R11 loss, and attributes 00000528/E9F17FFF to block source 00001030"
         severity note;
      stop;
      wait;
   end process;
end architecture;
