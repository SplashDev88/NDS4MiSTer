library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

-- Reproduce the hardware-proven r129 failure:
--   01FFA7E4  BL  01FF8624  (outer LR = 01FFA7E8)
--   01FF8624  BL  01FFA6A8  (inner LR must become 01FF8628)
--   01FFA6A8  MRS r0,CPSR
--   01FFA6AC  AND r0,r0,#0x1f
--   01FFA6B0  BX  lr
-- An IRQ around the nested BL must not let the old outer LR survive the
-- deferred inner link write. The exact hardware symptom is BX LR returning
-- to 01FFA7E8 instead of 01FF8628.
entity tb_nds_arm9_bl_irq_link is
   generic (irq_assert_delay_cycles : natural := 0);
end entity;

architecture sim of tb_nds_arm9_bl_irq_link is
   signal clk, reset, descriptor_valid, cpu_reset, boot_ready :
      std_logic := '0';
   signal save9, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata, execute_pc :
      std_logic_vector(31 downto 0);
   signal rnw, ena, done : std_logic;
   signal acc : std_logic_vector(1 downto 0);
   signal pending : std_logic := '0';
   signal request_addr, request_wdata : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal request_rnw : std_logic := '1';
   signal irq : std_logic := '0';
   signal step_enable : std_logic := '1';
   signal saw_outer, saw_inner, saw_vector, saw_low_vector, saw_success,
      saw_stale :
      std_logic := '0';
   type stack_type is array (0 to 63) of std_logic_vector(31 downto 0);
   signal stack : stack_type := (others => x"A5A5A5A5");

   function program_word(a : std_logic_vector(31 downto 0))
      return std_logic_vector is
   begin
      case a is
         when x"02000000" => return x"E3A0001F"; -- mov r0,#0x1f
         when x"02000004" => return x"E129F000"; -- msr cpsr_fc,r0
         when x"02000008" => return x"E59FF000"; -- ldr pc,[pc]
         when x"02000010" => return x"01FFA7E4";
         when x"01FFA7E4" => return x"EBFFF78E"; -- bl 01ff8624
         when x"01FFA7E8" => return x"EAFFFFFE"; -- stale-link failure
         when x"01FF8624" => return x"EB00081F"; -- bl 01ffa6a8
         when x"01FF8628" => return x"EAFFFFFE"; -- correct-link success
         when x"01FFA6A8" => return x"E10F0000";
         when x"01FFA6AC" => return x"E200001F";
         when x"01FFA6B0" => return x"E12FFF1E";

         -- Exact high-vector wrapper with a minimal handler.
         when x"FFFF0018" => return x"EA0001AE";
         when x"FFFF06D8" => return x"E92D500F";
         when x"FFFF06DC" => return x"EE190F11";
         when x"FFFF06E0" => return x"E3C000FF";
         when x"FFFF06E4" => return x"E2800901";
         when x"FFFF06E8" => return x"E1A0E00F";
         when x"FFFF06EC" => return x"E510F004";
         when x"03003FFC" => return x"02001000";
         when x"02001000" => return x"E12FFF1E";
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
         arm9_entry => x"02000000", arm7_entry => x"00001000",
         arm9_current_sp => x"027E392C", arm9_irq_sp => x"027E3FBC",
         arm9_saved_sp => x"027E392C", arm7_current_sp => x"00003000",
         arm7_irq_sp => x"00003040", arm7_saved_sp => x"00003080",
         initial_cpsr => x"0000001F", cpu_reset => cpu_reset,
         boot_ready => boot_ready, save9 => save9, save7 => save7
      );

   process(all)
   begin
      if unsigned(request_addr) >= unsigned'(x"027E3F00") and
         unsigned(request_addr) < unsigned'(x"027E4000") then
         rdata <= stack(to_integer(unsigned(request_addr(7 downto 2))));
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
         elsif pending = '0' and ena = '1' then
            request_addr <= addr;
            request_wdata <= wdata;
            request_rnw <= rnw;
            pending <= '1';
         elsif pending = '1' then
            done <= '1';
            pending <= '0';
            if request_rnw = '0' and
               unsigned(request_addr) >= unsigned'(x"027E3F00") and
               unsigned(request_addr) < unsigned'(x"027E4000") then
               stack(to_integer(unsigned(request_addr(7 downto 2)))) <=
                  request_wdata;
            end if;
         end if;
         if cpu_reset = '0' then
            if execute_pc = x"01FFA7E4" then saw_outer <= '1'; end if;
            if execute_pc = x"01FF8624" then saw_inner <= '1'; end if;
            if execute_pc = x"FFFF0018" then saw_vector <= '1'; end if;
            if execute_pc = x"00000018" then saw_low_vector <= '1'; end if;
            if saw_inner = '1' and execute_pc = x"01FF8628" then
               saw_success <= '1';
            end if;
            if saw_inner = '1' and execute_pc = x"01FFA7E8" then
               saw_stale <= '1';
            end if;
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
         dma_on => '0', do_step => step_enable, done => open,
         CPU_bus_idle => open,
         PC_in_BIOS => open, lastread => open, jump_out => open,
         new_cycles_out => open, new_cycles_valid => open,
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
      wait until saw_outer = '1' for 20 us;
      for i in 1 to irq_assert_delay_cycles loop
         wait until rising_edge(clk);
      end loop;
      irq <= '1';
      wait until saw_inner = '1' for 20 us;
      step_enable <= '0';
      for i in 1 to 8 loop
         wait until rising_edge(clk);
      end loop;
      step_enable <= '1';
      wait until saw_vector = '1' or saw_low_vector = '1' for 50 us;
      irq <= '0';
      wait until saw_success = '1' or saw_stale = '1' for 50 us;
      assert saw_outer = '1' and saw_inner = '1'
         report "nested BL test did not reach both call sites"
         severity failure;
      assert saw_vector = '1' and saw_low_vector = '0'
         report "nested BL test did not accept a high-vector IRQ; pc=" &
                to_hstring(execute_pc) & " success=" &
                std_logic'image(saw_success) & " stale=" &
                std_logic'image(saw_stale)
         severity failure;
      assert saw_stale = '0'
         report "IRQ lost inner BL link and exposed stale outer LR 0x01FFA7E8"
         severity failure;
      assert saw_success = '1'
         report "inner BL helper did not return to 0x01FF8628"
         severity failure;
      report "PASS: IRQ cannot discard a pending nested ARM9 BL link"
         severity note;
      stop;
      wait;
   end process;
end architecture;
