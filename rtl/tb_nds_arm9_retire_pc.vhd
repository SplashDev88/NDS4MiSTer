library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

-- Proves the exact seam used by the external r155 trace: new_cycles_valid
-- qualifies the execute PC only when an instruction completes. In
-- particular, the four failed EQ predicates still retire in sequence and no
-- speculative return target appears in the architectural trace.
entity tb_nds_arm9_retire_pc is
end entity;

architecture sim of tb_nds_arm9_retire_pc is
   signal clk, reset, descriptor_valid, boot_reset, boot_ready :
      std_logic := '0';
   signal save9, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata, debug_execute :
      std_logic_vector(31 downto 0);
   signal rnw, ena, bus_done, instruction_retired : std_logic;
   signal acc : std_logic_vector(1 downto 0);
   signal cycles : unsigned(7 downto 0);
begin
   clk <= not clk after 5 ns;

   boot : entity work.nds_cpu_boot_sequencer
      port map (
         clk => clk, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => x"020694F8", arm7_entry => x"00001000",
         arm9_current_sp => x"027E3F80", arm9_irq_sp => x"027E3FBC",
         arm9_saved_sp => x"027E3F80", arm7_current_sp => x"00003000",
         arm7_irq_sp => x"00003040", arm7_saved_sp => x"00003080",
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
      bus_done <= ena;
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
         dma_on => '0', do_step => '1', done => open, CPU_bus_idle => open,
         PC_in_BIOS => open, lastread => open, jump_out => open,
         new_cycles_out => cycles,
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
         x"020694F8", x"020694FC", x"02069500", x"02069504",
         x"02069508", x"0206950C", x"02069510", x"02069514",
         x"02069518"
      );
      variable retired : natural := 0;
   begin
      reset <= '1';
      wait until rising_edge(clk);
      reset <= '0';
      descriptor_valid <= '1';
      wait until boot_ready = '1';
      while retired < expected'length loop
         wait until rising_edge(clk) and instruction_retired = '1';
         -- Savestate/boot restoration emits completion pulses before the
         -- first architectural instruction. The production recorder applies
         -- the same main-RAM filter before consuming a retirement.
         if debug_execute(31 downto 22) = "0000001000" then
            assert debug_execute = expected(retired)
               report "retire PC mismatch index=" & integer'image(retired) &
                  " got=" & to_hstring(debug_execute) &
                  " expected=" & to_hstring(expected(retired))
               severity failure;
            retired := retired + 1;
         end if;
      end loop;
      report "PASS: completed-instruction pulse qualifies exact ARM9 execute PCs"
         severity note;
      stop;
      wait;
   end process;
end architecture;
