library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

-- Reproduce the Nintendo SDK ARM7 context-restore sequence seen at 037fcb20.
-- The saved worker context contains r10=1/r11=11 while poison values matching
-- the other live thread are kept nearby.  The restored PC and user registers
-- must remain from the same context.
entity tb_nds_arm7_context_restore is end entity;

architecture sim of tb_nds_arm7_context_restore is
   signal clk, reset, descriptor_valid, cpu_reset, boot_ready : std_logic := '0';
   signal save9, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata, debug_pc, debug_mixed :
      std_logic_vector(31 downto 0);
   signal rnw, ena, done : std_logic;
   signal acc : std_logic_vector(1 downto 0);
   signal observed_r4, observed_r5, observed_r10, observed_r11 :
      std_logic_vector(31 downto 0) :=
      (others => '0');
   signal saw_r4, saw_r5, saw_r10, saw_r11, saw_worker_pc :
      std_logic := '0';

   function read_word(a : std_logic_vector(31 downto 0))
      return std_logic_vector is
   begin
      case a is
         -- Supervisor restore routine, matching the SDK code shape.
         when x"00000000" => return x"E59F0058"; -- ldr r0,[pc,#0x58] -> 0x60
         when x"00000004" => return x"E4901004"; -- ldr r1,[r0],#4
         when x"00000008" => return x"E16FF001"; -- msr spsr_fsxc,r1
         when x"0000000C" => return x"E590D040"; -- ldr sp,[r0,#64]
         when x"00000010" => return x"E590E03C"; -- ldr lr,[r0,#60]
         when x"00000014" => return x"E8D07FFF"; -- ldm r0,{r0-r14}^
         when x"00000018" => return x"E1A00000"; -- nop
         when x"0000001C" => return x"E25EF004"; -- subs pc,lr,#4
         when x"00000060" => return x"00000100"; -- context pointer

         -- Worker continuation. Its stores expose restored low and high
         -- unbanked user registers. r89 covered only R8-R12 and therefore
         -- missed the same privileged LDM^ writeback loss for R0-R7.
         when x"00000200" => return x"E59F0010"; -- ldr r0,[pc,#0x10] -> 0x218
         when x"00000204" => return x"E5804000"; -- str r4,[r0]
         when x"00000208" => return x"E5805004"; -- str r5,[r0,#4]
         when x"0000020C" => return x"E580A008"; -- str r10,[r0,#8]
         when x"00000210" => return x"E580B00C"; -- str r11,[r0,#12]
         when x"00000214" => return x"EAFFFFFE"; -- b .
         when x"00000218" => return x"00000300";

         -- Saved CPSR followed by r0-r14 and the exception return address.
         when x"00000100" => return x"0000001F"; -- System ARM state
         when x"00000104" => return x"11110000"; -- r0
         when x"00000108" => return x"11110001"; -- r1
         when x"0000010C" => return x"11110002"; -- r2
         when x"00000110" => return x"11110003"; -- r3
         when x"00000114" => return x"11110004"; -- r4
         when x"00000118" => return x"11110005"; -- r5
         when x"0000011C" => return x"11110006"; -- r6
         when x"00000120" => return x"11110007"; -- r7
         when x"00000124" => return x"11110008"; -- r8
         when x"00000128" => return x"11110009"; -- r9
         when x"0000012C" => return x"00000001"; -- r10 worker value
         when x"00000130" => return x"0000000B"; -- r11 worker value
         when x"00000134" => return x"1111000C"; -- r12
         when x"00000138" => return x"00000400"; -- r13
         when x"0000013C" => return x"00000210"; -- r14
         when x"00000140" => return x"00000204"; -- SUBS returns to 0x200

         -- Adjacent poison context mirrors the values seen in the other
         -- hardware thread.  A mixed restore would expose these at 0x300.
         when x"0000016C" => return x"0000FFFF";
         when x"00000170" => return x"00000014";
         when others => return x"E1A00000";
      end case;
   end function;
begin
   clk <= not clk after 5 ns;

   boot : entity work.nds_cpu_boot_sequencer
      port map (
         clk => clk, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => x"00000000", arm7_entry => x"00000000",
         arm9_current_sp => x"00000800", arm9_irq_sp => x"00000840",
         arm9_saved_sp => x"00000880", arm7_current_sp => x"00000800",
         arm7_irq_sp => x"00000840", arm7_saved_sp => x"00000880",
         initial_cpsr => x"000000D3", cpu_reset => cpu_reset,
         boot_ready => boot_ready, save9 => save9, save7 => save7
      );

   rdata <= read_word(addr);
   done <= ena;

   process(clk)
   begin
      if rising_edge(clk) and ena = '1' then
         if rnw = '1' and addr = x"00000200" then
            saw_worker_pc <= '1';
         elsif rnw = '0' and addr = x"00000300" then
            observed_r4 <= wdata;
            saw_r4 <= '1';
         elsif rnw = '0' and addr = x"00000304" then
            observed_r5 <= wdata;
            saw_r5 <= '1';
         elsif rnw = '0' and addr = x"00000308" then
            observed_r10 <= wdata;
            saw_r10 <= '1';
         elsif rnw = '0' and addr = x"0000030C" then
            observed_r11 <= wdata;
            saw_r11 <= '1';
         end if;
      end if;
   end process;

   dut : entity work.gba_cpu
      generic map (is_simu => '1', is_arm9 => '0')
      port map (
         clk100 => clk, gb_on => '1', reset => cpu_reset,
         savestate_bus => save7, gb_bus_Adr => addr, gb_bus_rnw => rnw,
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
         debug_cpu_pc => debug_pc, debug_cpu_execute_pc => open,
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
      wait until saw_r11 = '1' for 20 us;
      assert saw_worker_pc = '1'
         report "ARM7 context restore did not return to the worker PC"
         severity failure;
      assert saw_r10 = '1' and saw_r11 = '1'
         report "ARM7 worker did not publish restored r10/r11"
         severity failure;
      assert saw_r4 = '1' and saw_r5 = '1'
         report "ARM7 worker did not publish restored r4/r5"
         severity failure;
      assert observed_r4 = x"11110004"
         report "ARM7 context restore lost unbanked r4; observed " &
                to_hstring(observed_r4)
         severity failure;
      assert observed_r5 = x"11110005"
         report "ARM7 context restore lost unbanked r5; observed " &
                to_hstring(observed_r5)
         severity failure;
      assert observed_r10 = x"00000001"
         report "ARM7 context restore mixed r10; observed " &
                to_hstring(observed_r10)
         severity failure;
      assert observed_r11 = x"0000000B"
         report "ARM7 context restore mixed r11; observed " &
                to_hstring(observed_r11)
         severity failure;
      report "PASS: ARM7 LDM^ plus exception return keeps PC, r4/r5, and r10/r11 in one saved context"
         severity note;
      stop;
      wait;
   end process;
end architecture;
