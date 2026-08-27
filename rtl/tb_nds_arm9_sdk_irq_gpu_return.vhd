library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

-- Replay the Mario command-0x6B IRQ path that immediately precedes the
-- hardware divergence: BIOS wrapper, exact SDK handler control flow,
-- indirect BLX R3, delayed GPU register traffic, conditional handler frame
-- restore, and the final BIOS SUBS return.
entity tb_nds_arm9_sdk_irq_gpu_return is
   generic (
      bus_response_delay_cycles : natural := 0;
      irq_assert_delay_cycles : natural := 0;
      -- r114 pauses both integrated CPUs while the HPS mailbox owns an
      -- external request. Exercise that exact do_step contract across the
      -- full SDK/GPU/BIOS return rather than only in the generic bus test.
      pause_during_external : boolean := false
   );
end entity;

architecture sim of tb_nds_arm9_sdk_irq_gpu_return is
   type responder_state_t is (RESP_IDLE, RESP_WAIT, RESP_DONE, RESP_RELEASE);
   type stack_type is array (0 to 63) of std_logic_vector(31 downto 0);
   type restored_type is array (0 to 6) of std_logic_vector(31 downto 0);
   signal clk, reset, descriptor_valid, cpu_reset, boot_ready : std_logic := '0';
   signal save9, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata, debug_pc, execute_pc, raw_fetch_pc :
      std_logic_vector(31 downto 0);
   signal rnw, ena, cpu_done : std_logic;
   signal step_enable : std_logic;
   signal acc : std_logic_vector(1 downto 0);
   signal irq : std_logic := '0';

   signal ext_addr, ext_wdata, ext_rdata, ext_debug_pc :
      std_logic_vector(31 downto 0);
   signal ext_rnw, ext_ena, ext_done, ext_cpu9 : std_logic;
   signal ext_acc : std_logic_vector(1 downto 0);
   signal request_addr, request_wdata, request_debug_pc :
      std_logic_vector(31 downto 0) :=
      (others => '0');
   signal response_data : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal request_rnw, request_cpu9 : std_logic := '1';
   signal responder_state : responder_state_t := RESP_IDLE;
   signal wait_count : natural := 0;

   signal arm7_addr, arm7_rdata : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal arm7_ena, arm7_done : std_logic := '0';
   signal irq_stack : stack_type := (others => x"A5A5A5A5");
   signal system_stack : stack_type := (others => x"A5A5A5A5");
   signal fifo_status_reads, gpu_reads, gpu_writes : natural := 0;
   signal saw_system_loop, saw_irq_vector, saw_low_irq_vector, saw_fifo_6b, saw_blx :
      std_logic := '0';
   signal saw_handler_restore, saw_bios_epilogue, saw_resume, saw_fifo_ab,
      post_bios_loop_seen, saw_raw_outer_fetch : std_logic := '0';
   signal resume_address : std_logic_vector(31 downto 0) := (others => '0');
   signal restored_values : restored_type := (others => (others => '0'));
   signal restored_seen : std_logic_vector(6 downto 0) := (others => '0');

   function program_word(a : std_logic_vector(31 downto 0))
      return std_logic_vector is
   begin
      case a is
         -- The boot sequencer intentionally starts the reused core in
         -- supervisor mode; direct-boot firmware performs this transition
         -- before normal System code can accept IRQs.
         when x"00000000" => return x"E3A0001F";
         when x"00000004" => return x"E129F000";
         when x"00000008" => return x"E59FF000";
         when x"00000010" => return x"0207CC60";
         when x"0207CC60" => return x"E3A04044";
         when x"0207CC64" => return x"E3A05055";
         when x"0207CC68" => return x"E3A06066";
         when x"0207CC6C" => return x"E3A07077";
         when x"0207CC70" => return x"E3A08088";
         when x"0207CC74" => return x"E3A09099";
         when x"0207CC78" => return x"E3A0A0AA";
         when x"0207CC7C" => return x"EA000007";
         -- Preserve the interrupted System registers for inspection, then
         -- wait until the BIOS epilogue has completed before entering the
         -- real Mario SDK PXI/FIFO send routine. This closes the prior test
         -- gap where execution returned only to a synthetic branch loop.
         when x"0207CCA0" => return x"E59FC048";
         when x"0207CCA4" => return x"E58C4000";
         when x"0207CCA8" => return x"E58C5004";
         when x"0207CCAC" => return x"E58C6008";
         when x"0207CCB0" => return x"E58C700C";
         when x"0207CCB4" => return x"E58C8010";
         when x"0207CCB8" => return x"E58C9014";
         when x"0207CCBC" => return x"E58CA018";
         when x"0207CCC0" => return x"E59C001C";
         when x"0207CCC4" => return x"E3500000";
         when x"0207CCC8" => return x"0AFFFFF4";
         when x"0207CCCC" => return x"E3A0000B";
         when x"0207CCD0" => return x"E3A01002";
         when x"0207CCD4" => return x"E3A02001";
         -- Native reference enters the send routine with SP=0x027E3904.
         when x"0207CCD8" => return x"E24DD028";
         when x"0207CCDC" => return x"EBFFAF46";
         when x"0207CCE0" => return x"E28DD028";
         when x"0207CCE4" => return x"EAFFFFFE";
         when x"0207CCF0" => return x"04001000";

         -- Exact ARM words dumped from Mario's outer FIFO send routine at
         -- 0x020689FC..0x02068AAC. The native trace constructs 0xAB, sees
         -- status 0x8501, and writes the reply to 0x04000188.
         when x"020689FC" => return x"E92D4000";
         when x"02068A00" => return x"E24DD004";
         when x"02068A04" => return x"E59D3000";
         when x"02068A08" => return x"E200001F";
         when x"02068A0C" => return x"E3C3301F";
         when x"02068A10" => return x"E183C000";
         when x"02068A14" => return x"E3CC3020";
         when x"02068A18" => return x"E2020001";
         when x"02068A1C" => return x"E1833280";
         when x"02068A20" => return x"E58DC000";
         when x"02068A24" => return x"E203203F";
         when x"02068A28" => return x"E3C1033F";
         when x"02068A2C" => return x"E1820300";
         when x"02068A30" => return x"E58D3000";
         when x"02068A34" => return x"E59F206C";
         when x"02068A38" => return x"E58D0000";
         when x"02068A3C" => return x"E1D200B0";
         when x"02068A40" => return x"E2100901";
         when x"02068A44" => return x"11D210B0";
         when x"02068A48" => return x"128DD004";
         when x"02068A4C" => return x"13E00000";
         when x"02068A50" => return x"13811903";
         when x"02068A54" => return x"11C210B0";
         when x"02068A58" => return x"18BD4000";
         when x"02068A5C" => return x"112FFF1E";
         when x"02068A60" => return x"EBFE46D7";
         when x"02068A64" => return x"E59F103C";
         when x"02068A68" => return x"E1D110B0";
         when x"02068A6C" => return x"E2111002";
         when x"02068A70" => return x"0A000004";
         when x"02068A74" => return x"EBFE4711";
         when x"02068A78" => return x"E28DD004";
         when x"02068A7C" => return x"E3E00001";
         when x"02068A80" => return x"E8BD4000";
         when x"02068A84" => return x"E12FFF1E";
         when x"02068A88" => return x"E59D2000";
         when x"02068A8C" => return x"E59F1018";
         when x"02068A90" => return x"E5812000";
         when x"02068A94" => return x"EBFE4709";
         when x"02068A98" => return x"E3A00000";
         when x"02068A9C" => return x"E28DD004";
         when x"02068AA0" => return x"E8BD4000";
         when x"02068AA4" => return x"E12FFF1E";
         when x"02068AA8" => return x"04000184";
         when x"02068AAC" => return x"04000188";

         -- Exact ARM9 high-vector BIOS wrapper.
         when x"FFFF0018" => return x"EA0001AE";
         when x"FFFF06D8" => return x"E92D500F";
         when x"FFFF06DC" => return x"EE190F11";
         when x"FFFF06E0" => return x"E3C000FF";
         when x"FFFF06E4" => return x"E2800901";
         when x"FFFF06E8" => return x"E1A0E00F";
         when x"FFFF06EC" => return x"E510F004";
         when x"FFFF06F0" => return x"E8BD500F";
         when x"FFFF06F4" => return x"E25EF004";
         when x"03003FFC" => return x"01FFA7EC";

         -- Exact SDK handler path from the focused native trace.
         when x"01FFA7EC" => return x"E92D47F0";
         when x"01FFA7F0" => return x"E24DD008";
         when x"01FFA7F4" => return x"E59FA108";
         when x"01FFA7F8" => return x"E59F5108";
         when x"01FFA7FC" => return x"E59F4108";
         when x"01FFA800" => return x"E3A07641";
         when x"01FFA804" => return x"E3A06000";
         when x"01FFA808" => return x"E3E08003";
         when x"01FFA80C" => return x"E3E09002";
         when x"01FFA810" => return x"E1DA00B0";
         when x"01FFA814" => return x"E2100901";
         when x"01FFA818" => return x"11DA00B0";
         when x"01FFA81C" => return x"11A01009";
         when x"01FFA820" => return x"13800903";
         when x"01FFA824" => return x"11CA00B0";
         when x"01FFA828" => return x"1A00000A";
         when x"01FFA82C" => return x"EBFFFF64";
         when x"01FFA830" => return x"E1DA10B0";
         when x"01FFA834" => return x"E2111C01";
         when x"01FFA838" => return x"0A000002";
         when x"01FFA83C" => return x"EBFFFF9F";
         when x"01FFA840" => return x"E1A01008";
         when x"01FFA844" => return x"EA000003";
         when x"01FFA848" => return x"E5971000";
         when x"01FFA84C" => return x"E58D1000";
         when x"01FFA850" => return x"EBFFFF9A";
         when x"01FFA854" => return x"E1A01006";
         when x"01FFA858" => return x"E1510008";
         when x"01FFA85C" => return x"028DD008";
         when x"01FFA860" => return x"08BD47F0";
         when x"01FFA864" => return x"012FFF1E";
         when x"01FFA868" => return x"E3E00002";
         when x"01FFA86C" => return x"E1510000";
         when x"01FFA870" => return x"0AFFFFE6";
         when x"01FFA874" => return x"E59D1000";
         when x"01FFA878" => return x"E1A00D81";
         when x"01FFA87C" => return x"E1B00DA0";
         when x"01FFA880" => return x"0AFFFFE2";
         when x"01FFA884" => return x"E7953100";
         when x"01FFA888" => return x"E3530000";
         when x"01FFA88C" => return x"0A000004";
         when x"01FFA890" => return x"E1A02D01";
         when x"01FFA894" => return x"E1A01321";
         when x"01FFA898" => return x"E1A02FA2";
         when x"01FFA89C" => return x"E12FFF33";
         when x"01FFA8A0" => return x"EAFFFFDA";
         -- Exact SDK IRQ-mask helpers used on both sides of the FIFO read.
         -- The earlier one-instruction BX stubs proved the frame mechanics
         -- but did not reproduce their CPSR side effects.
         when x"01FFA5C4" => return x"E10F0000";
         when x"01FFA5C8" => return x"E3801080";
         when x"01FFA5CC" => return x"E121F001";
         when x"01FFA5D0" => return x"E2000080";
         when x"01FFA5D4" => return x"E12FFF1E";
         when x"01FFA6C0" => return x"E10F1000";
         when x"01FFA6C4" => return x"E3C12080";
         when x"01FFA6C8" => return x"E1822000";
         when x"01FFA6CC" => return x"E121F002";
         when x"01FFA6D0" => return x"E2010080";
         when x"01FFA6D4" => return x"E12FFF1E";
         when x"01FFA904" => return x"04000184";
         when x"01FFA908" => return x"027E0394";
         when x"01FFA90C" => return x"04000188";
         when x"027E03C0" => return x"02001000";

         -- Command target: reproduce the eight GPU reads and writes observed
         -- immediately before the bad hardware BIOS return.
         when x"02001000" => return x"E59F0058";
         when x"02001004" => return x"E5901000";
         when x"02001008" => return x"E5901004";
         when x"0200100C" => return x"E5901008";
         when x"02001010" => return x"E590100C";
         when x"02001014" => return x"E2402010";
         when x"02001018" => return x"E5921000";
         when x"0200101C" => return x"E5901028";
         when x"02001020" => return x"E590102C";
         when x"02001024" => return x"E5901020";
         when x"02001028" => return x"E3A01000";
         when x"0200102C" => return x"E5801000";
         when x"02001030" => return x"E5801004";
         when x"02001034" => return x"E5801008";
         when x"02001038" => return x"E580100C";
         when x"0200103C" => return x"E5821000";
         when x"02001040" => return x"E5801028";
         when x"02001044" => return x"E580102C";
         when x"02001048" => return x"E5801020";
         when x"0200104C" => return x"E12FFF1E";
         when x"02001060" => return x"04000290";
         when others => return x"E1A00000";
      end case;
   end function;

   function is_gpu_register(a : std_logic_vector(31 downto 0))
      return boolean is
   begin
      return a = x"04000290" or a = x"04000294" or
             a = x"04000298" or a = x"0400029C" or
             a = x"04000280" or a = x"040002B8" or
             a = x"040002BC" or a = x"040002B0";
   end function;
begin
   clk <= not clk after 5 ns;
   ext_rdata <= response_data;
   step_enable <= '0' when pause_during_external and ext_ena = '1' else '1';

   boot : entity work.nds_cpu_boot_sequencer
      port map (
         clk => clk, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => x"00000000", arm7_entry => x"00001000",
         arm9_current_sp => x"027E392C", arm9_irq_sp => x"027E3F78",
         arm9_saved_sp => x"027E392C", arm7_current_sp => x"00003000",
         arm7_irq_sp => x"00003040", arm7_saved_sp => x"00003080",
         initial_cpsr => x"0000001F", cpu_reset => cpu_reset,
         boot_ready => boot_ready, save9 => save9, save7 => save7
      );

   process(clk)
   begin
      if rising_edge(clk) then
         ext_done <= '0';
         if cpu_reset = '1' then
            responder_state <= RESP_IDLE;
            wait_count <= 0;
            fifo_status_reads <= 0;
            gpu_reads <= 0;
            gpu_writes <= 0;
         else
            case responder_state is
               when RESP_IDLE =>
                  if ext_ena = '1' then
                     request_addr <= ext_addr;
                     request_wdata <= ext_wdata;
                     request_debug_pc <= ext_debug_pc;
                     request_rnw <= ext_rnw;
                     request_cpu9 <= ext_cpu9;
                     -- Capture response data with the request and keep it
                     -- stable through ext_done. In particular, incrementing
                     -- fifo_status_reads on completion must not retroactively
                     -- change the word consumed by the CPU on that edge.
                     if ext_cpu9 = '0' then
                        response_data <= x"E1A00000";
                     elsif unsigned(ext_addr) >= unsigned'(x"027E3E80") and
                           unsigned(ext_addr) < unsigned'(x"027E3F80") then
                        response_data <=
                           irq_stack(to_integer(unsigned(ext_addr(7 downto 2))));
                     elsif unsigned(ext_addr) >= unsigned'(x"027E3800") and
                           unsigned(ext_addr) < unsigned'(x"027E3A00") then
                        response_data <=
                           system_stack(
                              to_integer(unsigned(ext_addr(7 downto 2))));
                     elsif ext_addr = x"04000184" then
                        if fifo_status_reads < 2 then
                           response_data <= x"00008401";
                        else
                           response_data <= x"00008501";
                        end if;
                     elsif ext_addr = x"04100000" then
                        response_data <= x"0000006B";
                     elsif ext_addr = x"0400101C" then
                        response_data <=
                           (0 => post_bios_loop_seen, others => '0');
                     elsif is_gpu_register(ext_addr) then
                        response_data <= (others => '0');
                     else
                        response_data <= program_word(ext_addr);
                     end if;
                     wait_count <= bus_response_delay_cycles;
                     responder_state <= RESP_WAIT;
                  end if;
               when RESP_WAIT =>
                  if wait_count = 0 then
                     responder_state <= RESP_DONE;
                  else
                     wait_count <= wait_count - 1;
                  end if;
               when RESP_DONE =>
                  ext_done <= '1';
                  responder_state <= RESP_RELEASE;
                  if request_cpu9 = '1' then
                     if request_rnw = '1' and
                        unsigned(request_addr) >= unsigned'(x"01FFA830") and
                        unsigned(request_addr) <= unsigned'(x"01FFA850") then
                        report "SDK handler fetch/data address=" &
                               to_hstring(request_addr) & " pc=" &
                               to_hstring(request_debug_pc) & " value=" &
                               to_hstring(ext_rdata)
                           severity note;
                     end if;
                     if request_rnw = '0' and
                        unsigned(request_addr) >= unsigned'(x"027E3E80") and
                        unsigned(request_addr) < unsigned'(x"027E3F80") then
                        irq_stack(to_integer(unsigned(request_addr(7 downto 2)))) <=
                           request_wdata;
                     elsif request_rnw = '0' and
                           unsigned(request_addr) >= unsigned'(x"027E3800") and
                           unsigned(request_addr) < unsigned'(x"027E3A00") then
                        system_stack(
                           to_integer(unsigned(request_addr(7 downto 2)))) <=
                           request_wdata;
                     end if;
                     if request_rnw = '1' and request_addr = x"04000184" then
                        report "SDK FIFO status completion index=" &
                               integer'image(fifo_status_reads) &
                               " pc=" & to_hstring(request_debug_pc) &
                               " value=" & to_hstring(ext_rdata)
                           severity note;
                        fifo_status_reads <= fifo_status_reads + 1;
                     elsif request_rnw = '1' and request_addr = x"04100000" then
                        saw_fifo_6b <= '1';
                     elsif request_rnw = '0' and
                           request_addr = x"04000188" and
                           request_wdata = x"000000AB" then
                        saw_fifo_ab <= '1';
                     elsif is_gpu_register(request_addr) then
                        if request_rnw = '1' then
                           gpu_reads <= gpu_reads + 1;
                        else
                           gpu_writes <= gpu_writes + 1;
                        end if;
                     end if;
                  end if;
               when RESP_RELEASE =>
                  if ext_ena = '0' then responder_state <= RESP_IDLE; end if;
            end case;
         end if;
      end if;
   end process;

   router : entity work.nds_dual_cpu_bus
      port map (
         clk => clk, reset => cpu_reset,
         arm9_addr => addr, arm9_rnw => rnw, arm9_ena => ena,
         arm9_acc => acc, arm9_wdata => wdata,
         arm9_debug_pc => execute_pc, arm9_rdata => rdata,
         arm9_done => cpu_done,
         arm7_addr => arm7_addr, arm7_rnw => '1', arm7_ena => arm7_ena,
         arm7_acc => "10", arm7_wdata => (others => '0'),
         arm7_debug_pc => (others => '0'),
         arm7_rdata => arm7_rdata, arm7_done => arm7_done,
         ext_addr => ext_addr, ext_rnw => ext_rnw, ext_ena => ext_ena,
         ext_acc => ext_acc, ext_wdata => ext_wdata,
         ext_cpu_is_arm9 => ext_cpu9, ext_debug_pc => ext_debug_pc,
         ext_rdata => ext_rdata, ext_done => ext_done
      );

   -- Continuous ARM7 pressure reproduces the shared-port interleaving.
   process
   begin
      wait until cpu_reset = '0';
      loop
         arm7_addr <= std_logic_vector(unsigned(arm7_addr) + 4);
         arm7_ena <= '1';
         wait until rising_edge(clk);
         arm7_ena <= '0';
         wait until arm7_done = '1';
         wait until rising_edge(clk);
      end loop;
   end process;

   dut : entity work.gba_cpu
      generic map (
         is_simu => '1', is_arm9 => '1',
         arm9_cp15_reset_control => x"00052078",
         arm9_bios_lr_telemetry => '0'
      )
      port map (
         clk100 => clk, gb_on => '1', reset => cpu_reset,
         savestate_bus => save9, gb_bus_Adr => addr, gb_bus_rnw => rnw,
         gb_bus_ena => ena, gb_bus_acc => acc, gb_bus_dout => wdata,
         gb_bus_din => rdata, gb_bus_done => cpu_done,
         wait_cnt_value => (others => '0'), wait_cnt_update => '0',
         Underclock => "00", bus_lowbits => open, settle => '0',
         dma_on => '0', do_step => step_enable, done => open,
         CPU_bus_idle => open,
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
         debug_cpu_mixed => raw_fetch_pc,
         arm9_dtcm_region => open, arm9_dtcm_enable => open
      );

   process(clk)
   begin
      if rising_edge(clk) then
         if unsigned(raw_fetch_pc) >= unsigned'(x"020689FC") and
            unsigned(raw_fetch_pc) <= unsigned'(x"02068AA4") then
            saw_raw_outer_fetch <= '1';
         end if;
      end if;
      if rising_edge(clk) and ext_done = '1' and request_cpu9 = '1' and
         request_rnw = '1' then
         if request_addr = x"0207CCA0" then saw_system_loop <= '1'; end if;
         if saw_bios_epilogue = '1' and request_addr = x"0207CCA0" then
            post_bios_loop_seen <= '1';
         end if;
         if request_addr = x"FFFF0018" then saw_irq_vector <= '1'; end if;
         if request_addr = x"00000018" then saw_low_irq_vector <= '1'; end if;
         if request_addr = x"01FFA89C" then saw_blx <= '1'; end if;
         if request_addr = x"01FFA860" then saw_handler_restore <= '1'; end if;
         if request_addr = x"FFFF06F0" then saw_bios_epilogue <= '1'; end if;
         if saw_bios_epilogue = '1' and
            unsigned(request_addr) >= unsigned'(x"0207CCA0") and
            unsigned(request_addr) <= unsigned'(x"0207CCC0") and
            saw_resume = '0' then
            resume_address <= request_addr;
            saw_resume <= '1';
         end if;
      end if;
   end process;

   process(clk)
      variable slot : natural;
   begin
      if rising_edge(clk) then
         if cpu_reset = '1' then
            restored_values <= (others => (others => '0'));
            restored_seen <= (others => '0');
         elsif ext_done = '1' and request_cpu9 = '1' and
               request_rnw = '0' and saw_bios_epilogue = '1' and
               unsigned(request_addr) >= unsigned'(x"04001000") and
               unsigned(request_addr) <= unsigned'(x"04001018") and
               request_addr(1 downto 0) = "00" then
            slot := to_integer(unsigned(request_addr(4 downto 2)));
            if slot <= 6 then
               restored_values(slot) <= request_wdata;
               restored_seen(slot) <= '1';
            end if;
         end if;
      end if;
   end process;

   process
   begin
      reset <= '1';
      wait until rising_edge(clk);
      reset <= '0';
      descriptor_valid <= '1';
      wait until boot_ready = '1';
      wait until saw_system_loop = '1' for 100 us;
      for i in 1 to irq_assert_delay_cycles loop
         wait until rising_edge(clk);
      end loop;
      irq <= '1';
      wait until saw_irq_vector = '1' or saw_low_irq_vector = '1' for 500 us;
      irq <= '0';
      wait until saw_resume = '1' for 2 ms;
      wait until restored_seen = "1111111" for 2 ms;
      wait until saw_fifo_ab = '1' for 2 ms;
      report "SDK replay diagnostic execute_pc=" & to_hstring(execute_pc) &
             " high_vector=" & std_logic'image(saw_irq_vector) &
             " low_vector=" & std_logic'image(saw_low_irq_vector) &
             " fifo_reads=" & integer'image(fifo_status_reads)
         severity note;
      assert saw_irq_vector = '1'
         report "exact SDK replay did not enter the high IRQ vector"
         severity failure;
      assert saw_fifo_6b = '1'
         report "exact SDK replay did not consume FIFO command 0x6B"
         severity failure;
      assert saw_blx = '1'
         report "exact SDK replay did not execute indirect BLX R3"
         severity failure;
      assert gpu_reads = 8 and gpu_writes = 8
         report "GPU stub traffic mismatch: reads=" & integer'image(gpu_reads) &
                " writes=" & integer'image(gpu_writes)
         severity failure;
      assert saw_handler_restore = '1' and saw_bios_epilogue = '1'
         report "SDK handler did not restore its frame and reach BIOS epilogue"
         severity failure;
      assert saw_resume = '1' and
             unsigned(resume_address) >= unsigned'(x"0207CCA0") and
             unsigned(resume_address) <= unsigned'(x"0207CCE4")
         report "BIOS returned outside interrupted code: " &
                to_hstring(resume_address)
         severity failure;
      assert saw_fifo_ab = '1'
         report "real post-IRQ FIFO routine did not write reply 0xAB"
         severity failure;
      assert saw_raw_outer_fetch = '1'
         report "independent raw ARM9 fetch seam missed the outer FIFO routine"
         severity failure;
      for i in 0 to 6 loop
         assert restored_seen(i) = '1' and
                restored_values(i) =
                   std_logic_vector(to_unsigned(16#44# + i * 16#11#, 32))
            report "System callee-saved register R" &
                   integer'image(i + 4) & " was not restored: " &
                   to_hstring(restored_values(i))
            severity failure;
      end loop;
      report "PASS: exact SDK BLX/GPU IRQ path returns and sends FIFO 0xAB"
         severity note;
      stop;
      wait;
   end process;
end architecture;
