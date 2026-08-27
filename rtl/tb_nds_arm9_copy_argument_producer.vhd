library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

entity tb_nds_arm9_copy_argument_producer is
end entity;

architecture sim of tb_nds_arm9_copy_argument_producer is
   signal clk, reset, descriptor_valid, boot_reset, boot_ready :
      std_logic := '0';
   signal save, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata, debug_execute : std_logic_vector(31 downto 0);
   signal rnw, ena, cpu_done : std_logic;
   signal acc : std_logic_vector(1 downto 0);
   signal preload_seen, postload_seen, postadd_seen : std_logic := '0';
begin
   clk <= not clk after 5 ns;

   boot : entity work.nds_cpu_boot_sequencer
      port map (
         clk => clk, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => x"0206F030", arm7_entry => x"00001000",
         arm9_current_sp => x"027E3F80", arm9_irq_sp => x"027E3FBC",
         arm9_saved_sp => x"027E3F80", arm7_current_sp => x"00003000",
         arm7_irq_sp => x"00003040", arm7_saved_sp => x"00003080",
         initial_cpsr => x"2000001F", cpu_reset => boot_reset,
         boot_ready => boot_ready, save9 => save, save7 => save7
      );

   process(all)
   begin
      case addr is
         when x"0206F030" => rdata <= x"E59F0048"; -- ldr r0,=0x02096920
         when x"0206F034" => rdata <= x"E59F3048"; -- ldr r3,=0x00000141
         when x"0206F038" => rdata <= x"E59F5048"; -- ldr r5,=0x020962e0
         when x"0206F03C" => rdata <= x"EA000003"; -- b 0x0206f050
         when x"0206F040" | x"0206F044" | x"0206F048" | x"0206F04C" =>
            rdata <= x"E1A00000";
         when x"0206F050" => rdata <= x"E2800020"; -- add r0,r0,#0x20
         when x"0206F054" => rdata <= x"E5951020"; -- ldr r1,[r5,#0x20]
         when x"0206F058" => rdata <= x"E1A02004"; -- mov r2,r4
         when x"0206F05C" => rdata <= x"E0800003"; -- add r0,r0,r3
         when x"0206F060" => rdata <= x"EAFFFFFE"; -- b .
         when x"0206F080" => rdata <= x"02096920";
         when x"0206F084" => rdata <= x"00000141";
         when x"0206F088" => rdata <= x"020962E0";
         when x"02096300" => rdata <= x"027E37D8";
         when others => rdata <= (others => '0');
      end case;
      cpu_done <= ena;
   end process;

   process(clk)
   begin
      if rising_edge(clk) then
         if reset = '1' then
            preload_seen <= '0';
            postload_seen <= '0';
            postadd_seen <= '0';
         else
            case debug_execute(31 downto 28) is
               when x"A" =>
                  assert debug_execute = x"A0E04140"
                     report "copy-argument preload snapshot mismatch: " &
                        to_hstring(debug_execute)
                     severity failure;
                  preload_seen <= '1';
               when x"B" =>
                  assert debug_execute = x"B0E0D840"
                     report "copy-argument postload snapshot mismatch: " &
                        to_hstring(debug_execute)
                     severity failure;
                  postload_seen <= '1';
               when x"C" =>
                  assert debug_execute = x"C041D881"
                     report "copy-argument postadd snapshot mismatch: " &
                        to_hstring(debug_execute)
                     severity failure;
                  postadd_seen <= '1';
               when others => null;
            end case;
         end if;
      end if;
   end process;

   dut : entity work.gba_cpu
      generic map (
         is_simu => '1', is_arm9 => '1',
         arm9_cp15_reset_control => x"00052078",
         arm9_copy_argument_telemetry => '1'
      )
      port map (
         clk100 => clk, gb_on => '1', reset => boot_reset,
         savestate_bus => save,
         gb_bus_Adr => addr, gb_bus_rnw => rnw, gb_bus_ena => ena,
         gb_bus_acc => acc, gb_bus_dout => wdata, gb_bus_din => rdata,
         gb_bus_done => cpu_done, wait_cnt_value => (others => '0'),
         wait_cnt_update => '0', Underclock => "00", bus_lowbits => open,
         settle => '0', dma_on => '0', do_step => '1', done => open,
         CPU_bus_idle => open, PC_in_BIOS => open, lastread => open,
         jump_out => open, new_cycles_out => open, new_cycles_valid => open,
         dma_new_cycles => '0', dma_first_cycles => '0',
         dma_dword_cycles => '0', dma_toROM => '0', dma_init_cycles => '0',
         dma_cycles_adrup => (others => '0'), IRP_in => (others => '0'),
         cpu_IRP => '0', new_halt => '0', DISPSTAT_debug => (others => '0'),
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
      wait until preload_seen = '1' and postload_seen = '1' and
                 postadd_seen = '1' for 20 us;
      assert preload_seen = '1' and postload_seen = '1' and postadd_seen = '1'
         report "ARM9 copy-argument snapshots did not complete"
         severity failure;
      report "PASS: ARM9 copy-argument producer snapshots bracket ADD/LDR/ADD"
         severity note;
      stop;
      wait;
   end process;
end architecture;
