library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

entity tb_nds_arm9_diag_request_latch is
end entity;

architecture sim of tb_nds_arm9_diag_request_latch is
   signal clk, reset, descriptor_valid, boot_reset, boot_ready : std_logic := '0';
   signal save9, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata, debug_pc, execute_debug_pc, debug_mixed :
      std_logic_vector(31 downto 0);
   signal rnw, ena, done : std_logic := '0';
   signal acc : std_logic_vector(1 downto 0);
   signal pending : std_logic := '0';
   signal pending_wait : natural := 0;
   signal request_addr : std_logic_vector(31 downto 0) := (others => '0');
   signal request_rnw : std_logic := '1';
   signal target_complete : std_logic := '0';
begin
   clk <= not clk after 5 ns;

   boot : entity work.nds_cpu_boot_sequencer
      port map (
         clk => clk, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => x"01FFA84C", arm7_entry => x"00001000",
         arm9_current_sp => x"027E3F80", arm9_irq_sp => x"027E3FBC",
         arm9_saved_sp => x"027E3F80", arm7_current_sp => x"00003000",
         arm7_irq_sp => x"00003040", arm7_saved_sp => x"00003080",
         initial_cpsr => x"0000001F", cpu_reset => boot_reset,
         boot_ready => boot_ready, save9 => save9, save7 => save7
      );

   process(all)
   begin
      case request_addr is
         -- Execute the real handler operation instead of seeding R1: load
         -- command 0x6B from IPCFIFORECV through a delayed external bus
         -- completion, then require it to be architectural at 01FFA854.
         when x"01FFA84C" => rdata <= x"E3A07641"; -- mov r7,#0x04100000
         when x"01FFA850" => rdata <= x"E5971000"; -- ldr r1,[r7]
         when x"01FFA854" => rdata <= x"E1A00000"; -- target milestone
         when x"01FFA858" => rdata <= x"E59F6010"; -- ldr r6,[pc,#0x10]
         when x"01FFA85C" => rdata <= x"E5960000"; -- ldr r0,[r6]
         when x"01FFA860" => rdata <= x"EAFFFFFD"; -- b 01ffa85c
         when x"01FFA870" => rdata <= x"04000000";
         when x"04100000" => rdata <= x"0000006B";
         when others => rdata <= x"00000000";
      end case;
   end process;

   -- Latch the request like the real memory bridge, then allow the CPU-side
   -- address mux to move before asserting completion.
   process(clk)
   begin
      if rising_edge(clk) then
         done <= '0';
         if boot_reset = '1' then
            pending <= '0';
            pending_wait <= 0;
            target_complete <= '0';
         elsif pending = '0' and ena = '1' then
            if addr = x"04100000" then
               assert execute_debug_pc = x"01FFA858"
                  report "dedicated fetch-PC output did not identify the FIFO LDR successor: " &
                         to_hstring(execute_debug_pc)
                  severity failure;
               assert debug_mixed = x"01FFA850"
                  report "independent execute-PC output did not identify the stalled FIFO LDR: " &
                         to_hstring(debug_mixed)
                  severity failure;
            end if;
            request_addr <= addr;
            request_rnw <= rnw;
            pending <= '1';
            pending_wait <= 2;
         elsif pending = '1' and pending_wait /= 0 then
            pending_wait <= pending_wait - 1;
         elsif pending = '1' then
            done <= '1';
            pending <= '0';
            if request_rnw = '1' and request_addr = x"01FFA854" then
               target_complete <= '1';
            end if;
         end if;
      end if;
   end process;

   dut : entity work.gba_cpu
      generic map (
         is_simu => '0', is_arm9 => '1',
         arm9_cp15_reset_control => x"00052078",
         arm9_bios_lr_telemetry => '1',
         arm9_fetch_pc_telemetry => '1'
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
         dma_dword_cycles => '0', dma_toROM => '0', dma_init_cycles => '0',
         dma_cycles_adrup => (others => '0'), IRP_in => (others => '0'),
         cpu_IRP => '0', new_halt => '0', clear_halt => '0',
         DISPSTAT_debug => (others => '0'), debug_fifocount => 0,
         timerdebug0 => (others => '0'), timerdebug1 => (others => '0'),
         timerdebug2 => (others => '0'), timerdebug3 => (others => '0'),
         debug_cpu_pc => debug_pc,
         debug_cpu_execute_pc => execute_debug_pc,
         debug_cpu_mixed => debug_mixed,
         arm9_dtcm_region => open, arm9_dtcm_enable => open
      );

   process
      variable saw_lr_tag, saw_sp_tag : boolean := false;
      variable saw_first_pc, saw_first_lr, saw_first_sp : boolean := false;
      variable saw_bus_tags : std_logic_vector(8 downto 0) :=
         (others => '0');
   begin
      reset <= '1';
      wait until rising_edge(clk);
      reset <= '0';
      descriptor_valid <= '1';
      wait until boot_ready = '1';
      wait until target_complete = '1' for 200 us;
      assert target_complete = '1'
         report "ARM9 diagnostic test never reached the post-0x6B milestone"
         severity failure;
      for cycle in 1 to 10000 loop
         wait until rising_edge(clk);
         if debug_pc(31 downto 24) = x"60" then
            saw_lr_tag := true;
         elsif debug_pc(31 downto 24) = x"61" then
            saw_sp_tag := true;
            assert debug_pc(23 downto 0) = x"7E3F80"
               report "ARM9 diagnostic captured the wrong SP at 0x6B completion"
               severity failure;
         elsif debug_pc(31 downto 24) = x"70" then
            saw_first_pc := true;
            assert debug_pc(23 downto 0) = x"FFA854"
               report "ARM9 first-0x6B diagnostic captured the wrong PC"
               severity failure;
         elsif debug_pc(31 downto 24) = x"71" then
            saw_first_lr := true;
         elsif debug_pc(31 downto 24) = x"72" then
            saw_first_sp := true;
            assert debug_pc(23 downto 0) = x"7E3F80"
               report "ARM9 first-0x6B diagnostic captured the wrong SP"
               severity failure;
         elsif debug_pc(31 downto 24) = x"73" then
            saw_bus_tags(0) := '1';
         elsif debug_pc(31 downto 24) = x"74" then
            saw_bus_tags(1) := '1';
         elsif debug_pc(31 downto 24) = x"75" then
            saw_bus_tags(2) := '1';
            assert debug_pc(23 downto 0) = x"00006B"
               report "ARM9 0x6B diagnostic captured the wrong bus word"
               severity failure;
         elsif debug_pc(31 downto 24) = x"76" then
            saw_bus_tags(3) := '1';
         elsif debug_pc(31 downto 24) = x"77" then
            saw_bus_tags(4) := '1';
            assert debug_pc(23 downto 0) = x"00006B"
               report "ARM9 0x6B completion did not reach calc_result"
               severity failure;
         elsif debug_pc(31 downto 24) = x"78" then
            saw_bus_tags(5) := '1';
         elsif debug_pc(31 downto 24) = x"79" then
            saw_bus_tags(6) := '1';
         elsif debug_pc(31 downto 24) = x"7A" then
            saw_bus_tags(7) := '1';
         elsif debug_pc(31 downto 24) = x"7B" then
            saw_bus_tags(8) := '1';
            assert debug_pc(23 downto 0) = x"00006B"
               report "ARM9 0x6B completion did not commit to R1"
               severity failure;
         end if;
         exit when saw_bus_tags = "111111111";
      end loop;
      assert saw_bus_tags = "111111111"
         report "0x6B completion/writeback telemetry was incomplete"
         severity failure;
      report "PASS: ARM9 0x6B external load completes and commits to R1"
         severity note;
      stop;
      wait;
   end process;
end architecture;
