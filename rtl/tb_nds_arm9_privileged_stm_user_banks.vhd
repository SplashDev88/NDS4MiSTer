library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

-- Directed regression for the native ARM9 scheduler context save/restore.
--
-- In System mode R8-R12 are the live unbanked registers.  A privileged
-- STM^ executed from IRQ must therefore store those live values, plus the
-- User/System R13-R14 bank.  The exact native instructions and layout are:
--
--   01FFD734  E9E07FFC  STMIB r0!,{r2-r14}^  (r0 = 0209438C)
--   01FF8198  E8D07FFF  LDMIA r0,{r0-r14}^   (r0 = 02094388)
--
-- Consequently System R11 must be saved and restored through 020943B4.
-- A second save from FIQ verifies that R8-R12 then come from the user
-- backing bank, while unbanked R2-R7 still come from the live register file.
entity tb_nds_arm9_privileged_stm_user_banks is
   generic (
      bus_response_delay_cycles : natural := 0
   );
end entity;

architecture sim of tb_nds_arm9_privileged_stm_user_banks is
   type responder_state_t is (RESP_IDLE, RESP_WAIT, RESP_DONE, RESP_RELEASE);
   type context_type is array (0 to 63) of std_logic_vector(31 downto 0);

   signal clk, reset, descriptor_valid, cpu_reset, boot_ready :
      std_logic := '0';
   signal save9, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata, debug_pc, execute_pc, debug_mixed :
      std_logic_vector(31 downto 0);
   signal rnw, ena, done : std_logic;
   signal acc : std_logic_vector(1 downto 0);

   signal responder_state : responder_state_t := RESP_IDLE;
   signal pending_wait : natural := 0;
   signal request_addr, request_wdata : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal request_rnw : std_logic := '1';

   signal context_b, fiq_context : context_type :=
      (others => x"A5A5A5A5");
   signal saw_r11_publish, saw_fiq_complete : std_logic := '0';
   signal published_r11 : std_logic_vector(31 downto 0) :=
      (others => '0');

   function program_word(a : std_logic_vector(31 downto 0))
      return std_logic_vector is
   begin
      case a is
         -- Establish the live User/System register bank.
         when x"00000000" => return x"E59F00F8"; -- ldr r0,[pc,#0xf8]
         when x"00000004" => return x"E3A0101F"; -- mov r1,#System
         when x"00000008" => return x"E121F001"; -- msr cpsr_c,r1
         when x"0000000C" => return x"E8907FFC"; -- ldmia r0,{r2-r14}
         when x"00000010" => return x"E1A00000"; -- interlock nop

         -- Exact native privileged context save from IRQ mode.
         when x"00000014" => return x"E3A010D2"; -- mov r1,#IRQ,I,F
         when x"00000018" => return x"E121F001"; -- msr cpsr_c,r1
         when x"0000001C" => return x"E59F00E0"; -- r0 = 0209438c
         when x"00000020" => return x"E9E07FFC"; -- exact STMIB r0!,{r2-r14}^
         when x"00000024" => return x"E1A00000";

         -- Deliberately destroy live R11, then execute the native restore.
         when x"00000028" => return x"E3A0101F"; -- mov r1,#System
         when x"0000002C" => return x"E121F001"; -- msr cpsr_c,r1
         when x"00000030" => return x"E3A0B000"; -- mov r11,#0
         when x"00000034" => return x"E3A010D2"; -- mov r1,#IRQ,I,F
         when x"00000038" => return x"E121F001"; -- msr cpsr_c,r1
         when x"0000003C" => return x"E59F00C4"; -- r0 = 02094388
         when x"00000040" => return x"E8D07FFF"; -- exact LDMIA r0,{r0-r14}^
         when x"00000044" => return x"E1A00000"; -- interlock nop
         when x"00000048" => return x"E3A0101F"; -- mov r1,#System
         when x"0000004C" => return x"E121F001"; -- msr cpsr_c,r1
         when x"00000050" => return x"E59F10B4"; -- marker address
         when x"00000054" => return x"E581B000"; -- publish restored r11

         -- Re-establish the user bank, enter FIQ, install distinct FIQ
         -- R8-R14 values, then repeat the exact privileged save.
         when x"00000058" => return x"E59F00A0"; -- system values
         when x"0000005C" => return x"E8907FFC"; -- ldmia r0,{r2-r14}
         when x"00000060" => return x"E1A00000";
         when x"00000064" => return x"E3A010D1"; -- mov r1,#FIQ,I,F
         when x"00000068" => return x"E121F001"; -- msr cpsr_c,r1
         when x"0000006C" => return x"E59F009C"; -- FIQ values
         when x"00000070" => return x"E8907F00"; -- ldmia r0,{r8-r14}
         when x"00000074" => return x"E1A00000";
         when x"00000078" => return x"E59F0094"; -- FIQ save base
         when x"0000007C" => return x"E9E07FFC"; -- STMIB r0!,{r2-r14}^
         when x"00000080" => return x"E1A00000";
         when x"00000084" => return x"E59F108C"; -- completion marker
         when x"00000088" => return x"E3A02001";
         when x"0000008C" => return x"E5812000";
         when x"00000090" => return x"EAFFFFFE";

         when x"00000100" => return x"00001000";
         when x"00000104" => return x"0209438C";
         when x"00000108" => return x"02094388";
         when x"0000010C" => return x"00002000";
         when x"00000110" => return x"00001100";
         when x"00000114" => return x"0209448C";
         when x"00000118" => return x"00002004";

         -- User/System values.  R11 is the exact native sentinel.
         when x"00001000" => return x"A2000002"; -- r2
         when x"00001004" => return x"A3000003"; -- r3
         when x"00001008" => return x"A4000004"; -- r4
         when x"0000100C" => return x"A5000005"; -- r5
         when x"00001010" => return x"A6000006"; -- r6
         when x"00001014" => return x"A7000007"; -- r7
         when x"00001018" => return x"A8000008"; -- r8
         when x"0000101C" => return x"A9000009"; -- r9
         when x"00001020" => return x"AA00000A"; -- r10
         when x"00001024" => return x"027E3914"; -- r11
         when x"00001028" => return x"AC00000C"; -- r12
         when x"0000102C" => return x"027E4000"; -- r13
         when x"00001030" => return x"01FF8224"; -- r14

         -- Distinct banked FIQ values which STM^ must not save.
         when x"00001100" => return x"F8000008"; -- r8_fiq
         when x"00001104" => return x"F9000009"; -- r9_fiq
         when x"00001108" => return x"FA00000A"; -- r10_fiq
         when x"0000110C" => return x"FB00000B"; -- r11_fiq
         when x"00001110" => return x"FC00000C"; -- r12_fiq
         when x"00001114" => return x"FD00000D"; -- r13_fiq
         when x"00001118" => return x"FE00000E"; -- r14_fiq
         when others => return x"E1A00000";
      end case;
   end function;
begin
   clk <= not clk after 5 ns;

   boot : entity work.nds_cpu_boot_sequencer
      port map (
         clk => clk, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => x"00000000", arm7_entry => x"00003000",
         arm9_current_sp => x"027E3FC0", arm9_irq_sp => x"027E3FBC",
         arm9_saved_sp => x"027E392C", arm7_current_sp => x"00003000",
         arm7_irq_sp => x"00003040", arm7_saved_sp => x"00003080",
         initial_cpsr => x"000000D3", cpu_reset => cpu_reset,
         boot_ready => boot_ready, save9 => save9, save7 => save7
      );

   process(all)
   begin
      if unsigned(request_addr) >= unsigned'(x"02094380") and
         unsigned(request_addr) < unsigned'(x"02094400") then
         rdata <= context_b(
            to_integer(unsigned(request_addr(7 downto 2))));
      elsif unsigned(request_addr) >= unsigned'(x"02094480") and
            unsigned(request_addr) < unsigned'(x"02094500") then
         rdata <= fiq_context(
            to_integer(unsigned(request_addr(7 downto 2))));
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
            context_b <= (others => x"A5A5A5A5");
            fiq_context <= (others => x"A5A5A5A5");
            -- LDMIA r0,{r0-r14}^ starts four bytes before the STMIB^ base.
            context_b(to_integer(unsigned'(x"88") / 4)) <= x"B0000000";
            context_b(to_integer(unsigned'(x"8C") / 4)) <= x"B1000001";
            saw_r11_publish <= '0';
            saw_fiq_complete <= '0';
         else
            case responder_state is
               when RESP_IDLE =>
                  if ena = '1' then
                     request_addr <= addr;
                     request_wdata <= wdata;
                     request_rnw <= rnw;
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
                     unsigned(request_addr) >= unsigned'(x"02094380") and
                     unsigned(request_addr) < unsigned'(x"02094400") then
                     index := to_integer(unsigned(request_addr(7 downto 2)));
                     context_b(index) <= request_wdata;
                  elsif request_rnw = '0' and
                        unsigned(request_addr) >= unsigned'(x"02094480") and
                        unsigned(request_addr) < unsigned'(x"02094500") then
                     index := to_integer(unsigned(request_addr(7 downto 2)));
                     fiq_context(index) <= request_wdata;
                  elsif request_rnw = '0' and
                        request_addr = x"00002000" then
                     published_r11 <= request_wdata;
                     saw_r11_publish <= '1';
                  elsif request_rnw = '0' and
                        request_addr = x"00002004" then
                     saw_fiq_complete <= '1';
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
         cpu_IRP => '0', new_halt => '0', clear_halt => '0',
         DISPSTAT_debug => (others => '0'), debug_fifocount => 0,
         timerdebug0 => (others => '0'), timerdebug1 => (others => '0'),
         timerdebug2 => (others => '0'), timerdebug3 => (others => '0'),
         debug_cpu_pc => debug_pc, debug_cpu_execute_pc => execute_pc,
         debug_cpu_mixed => debug_mixed,
         arm9_dtcm_region => open, arm9_dtcm_enable => open
      );

   process
      procedure assert_saved_context(
         signal image : in context_type;
         constant label_text : in string) is
      begin
         -- Check the proven corrupt word first so a failing run reports the
         -- hardware-localized symptom rather than a less specific low-reg bug.
         assert image(to_integer(unsigned'(x"B4") / 4)) = x"027E3914"
            report label_text & " saved R11 incorrectly at 02094xB4: " &
                   to_hstring(image(to_integer(unsigned'(x"B4") / 4)))
            severity failure;
         assert image(to_integer(unsigned'(x"90") / 4)) = x"A2000002" and
                image(to_integer(unsigned'(x"94") / 4)) = x"A3000003" and
                image(to_integer(unsigned'(x"98") / 4)) = x"A4000004" and
                image(to_integer(unsigned'(x"9C") / 4)) = x"A5000005" and
                image(to_integer(unsigned'(x"A0") / 4)) = x"A6000006" and
                image(to_integer(unsigned'(x"A4") / 4)) = x"A7000007"
            report label_text & " did not save live unbanked R2-R7"
            severity failure;
         assert image(to_integer(unsigned'(x"A8") / 4)) = x"A8000008" and
                image(to_integer(unsigned'(x"AC") / 4)) = x"A9000009" and
                image(to_integer(unsigned'(x"B0") / 4)) = x"AA00000A" and
                image(to_integer(unsigned'(x"B8") / 4)) = x"AC00000C"
            report label_text & " selected the wrong R8-R12 bank"
            severity failure;
         assert image(to_integer(unsigned'(x"BC") / 4)) = x"027E4000" and
                image(to_integer(unsigned'(x"C0") / 4)) = x"01FF8224"
            report label_text & " did not save User/System R13-R14"
            severity failure;
      end procedure;
   begin
      reset <= '1';
      wait until rising_edge(clk);
      reset <= '0';
      descriptor_valid <= '1';
      wait until boot_ready = '1';
      wait until saw_fiq_complete = '1' for 500 us;
      assert saw_fiq_complete = '1'
         report "privileged STM^ test program did not complete"
         severity failure;
      assert saw_r11_publish = '1'
         report "matching privileged LDM^ did not publish restored R11"
         severity failure;

      assert_saved_context(context_b, "IRQ STMIB^");
      assert published_r11 = x"027E3914"
         report "LDMIA^ did not restore System R11 from 020943B4: " &
                to_hstring(published_r11)
         severity failure;
      assert_saved_context(fiq_context, "FIQ STMIB^");

      report "PASS: privileged STMIB^/LDMIA^ preserves live and User/System ARM9 register banks"
         severity note;
      stop;
      wait;
   end process;
end architecture;
