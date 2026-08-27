library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

entity tb_nds_arm9_cmp_condition_hazard is
end entity;

architecture sim of tb_nds_arm9_cmp_condition_hazard is
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
begin
   clk <= not clk after 5 ns;

   boot : entity work.nds_cpu_boot_sequencer
      port map (
         clk => clk, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => x"020694F8", arm7_entry => x"00001000",
         arm9_current_sp => x"027E3F80", arm9_irq_sp => x"027E3FBC",
         arm9_saved_sp => x"027E3F80", arm7_current_sp => x"00003000",
         arm7_irq_sp => x"00003040", arm7_saved_sp => x"00003080",
         -- Mario enters this sequence with Z set. CMP R2,#0 must clear it
         -- before the immediately following EQ-predicated return sequence.
         initial_cpsr => x"4000001F", cpu_reset => boot_reset,
         boot_ready => boot_ready, save9 => save9, save7 => save7
      );

   process(all)
   begin
      case addr is
         when x"020694F8" => rdata <= x"E3A01007"; -- mov r1,#7
         when x"020694FC" => rdata <= x"E3A02007"; -- mov r2,#7
         when x"02069500" => rdata <= x"E1A00000"; -- nop
         when x"02069504" => rdata <= x"E3520000"; -- cmp r2,#0
         when x"02069508" => rdata <= x"028DD00C"; -- addeq sp,sp,#12
         when x"0206950C" => rdata <= x"03A00001"; -- moveq r0,#1
         when x"02069510" => rdata <= x"08BD4030"; -- popeq {r4,r5,lr}
         when x"02069514" => rdata <= x"012FFF1E"; -- bxeq lr
         when x"02069518" => rdata <= x"E3A03053"; -- success marker
         when others => rdata <= x"EAFFFFFE";
      end case;
      done <= ena;
   end process;

   process(clk)
   begin
      if rising_edge(clk) then
         if ena = '1' and addr = x"027E3F80" then
            stack_access_seen <= '1';
         end if;
      end if;
   end process;

   dut : entity work.gba_cpu
      generic map (
         is_simu => '1', is_arm9 => '1',
         arm9_cmp_flow_telemetry => '1'
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
      wait until debug_execute(31 downto 28) = x"E" for 20 us;
      assert debug_execute = x"E2050707"
         report "CMP flow snapshot mismatch: " & to_hstring(debug_execute)
         severity failure;
      assert stack_access_seen = '0'
         report "POPEQ executed despite CMP R2=7 clearing Z"
         severity failure;
      report "PASS: CMP result predicates the immediately following EQ return"
         severity note;
      stop;
      wait;
   end process;
end architecture;
