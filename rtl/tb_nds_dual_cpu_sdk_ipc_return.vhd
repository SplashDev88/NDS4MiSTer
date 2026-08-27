library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

-- Integrated replay of Mario's first failing IPC exchange. Unlike the
-- single-ARM9 SDK replay, this test runs both real gba_cpu pipelines through
-- nds_dual_cpu_core's 2:1 scheduler and nds_dual_cpu_bus. ARM7 generates
-- command 0x6B, ARM9 services the exact SDK/GPU/BIOS path, and the test
-- requires the real outer routine to publish reply 0xAB.
entity tb_nds_dual_cpu_sdk_ipc_return is
   generic (
      oracle_response_delay_cycles : natural := 31
   );
end entity;

architecture sim of tb_nds_dual_cpu_sdk_ipc_return is
   type responder_state_t is (RESP_IDLE, RESP_WAIT, RESP_DONE, RESP_RELEASE);
   type irq_stack_type is array (0 to 63) of std_logic_vector(31 downto 0);
   type system_stack_type is array (0 to 127) of std_logic_vector(31 downto 0);

   signal clk, reset, descriptor_valid, boot_ready : std_logic := '0';
   signal addr9, wdata9, rdata9, addr7, wdata7, rdata7 :
      std_logic_vector(31 downto 0);
   signal rnw9, ena9, done9, irq9, halt9 : std_logic;
   signal rnw7, ena7, done7, irq7, halt7 : std_logic;
   signal acc9, acc7 : std_logic_vector(1 downto 0);
   signal cycles9, cycles7 : std_logic_vector(7 downto 0);
   signal cycles_valid9, cycles_valid7 : std_logic;
   signal debug_pc9, debug_pc7 : std_logic_vector(31 downto 0);
   signal dtcm_region : std_logic_vector(31 downto 0);
   signal dtcm_enable : std_logic;

   signal ext_addr, ext_wdata, ext_rdata, ext_debug_pc :
      std_logic_vector(31 downto 0);
   signal ext_rnw, ext_ena, ext_owner9, ext_done : std_logic := '0';
   signal ext_acc : std_logic_vector(1 downto 0);
   signal request_addr, request_wdata : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal request_rnw, request_owner9 : std_logic := '1';
   signal response_data : std_logic_vector(31 downto 0) := (others => '0');
   signal responder_state : responder_state_t := RESP_IDLE;
   signal wait_count : natural := 0;
   signal global_step_enable : std_logic;

   signal irq_stack : irq_stack_type := (others => x"A5A5A5A5");
   signal system_stack : system_stack_type := (others => x"A5A5A5A5");
   signal fifo_status_reads, gpu_reads, gpu_writes : natural := 0;
   signal arm7_sent_6b, arm9_read_6b, arm9_sent_ab : std_logic := '0';
   signal saw_irq_vector, saw_bios_epilogue, saw_outer_fifo :
      std_logic := '0';

   function is_oracle_address(a : std_logic_vector(31 downto 0))
      return boolean is
   begin
      return a(31 downto 24) = x"04" or a(31 downto 16) = x"FFFF";
   end function;

   function is_gpu_register(a : std_logic_vector(31 downto 0))
      return boolean is
   begin
      return a = x"04000290" or a = x"04000294" or
             a = x"04000298" or a = x"0400029C" or
             a = x"04000280" or a = x"040002B8" or
             a = x"040002BC" or a = x"040002B0";
   end function;

   function arm7_word(a : std_logic_vector(31 downto 0))
      return std_logic_vector is
   begin
      case a is
         when x"037F8000" => return x"E3A0001F"; -- MOV R0,#System CPSR
         when x"037F8004" => return x"E129F000"; -- MSR CPSR_fc,R0
         when x"037F8008" => return x"E3A04080"; -- delay for ARM9 setup
         when x"037F800C" => return x"E2544001";
         when x"037F8010" => return x"1AFFFFFD";
         when x"037F8014" => return x"E59F0008";
         when x"037F8018" => return x"E3A0106B";
         when x"037F801C" => return x"E5801000"; -- send command 0x6B
         when x"037F8020" => return x"EAFFFFFE";
         when x"037F8024" => return x"04000188";
         when others => return x"E1A00000";
      end case;
   end function;

   function arm9_word(a : std_logic_vector(31 downto 0))
      return std_logic_vector is
   begin
      case a is
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
         when x"0207CCD8" => return x"E24DD028";
         when x"0207CCDC" => return x"EBFFAF46";
         when x"0207CCE0" => return x"E28DD028";
         when x"0207CCE4" => return x"EAFFFFFE";
         when x"0207CCF0" => return x"04001000";

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
begin
   clk <= not clk after 5 ns;
   ext_rdata <= response_data;
   -- Match r114/r116: local RAM execution continues, but both CPUs pause
   -- throughout an unresolved HPS-owned I/O or BIOS request.
   global_step_enable <= '0'
      when ext_ena = '1' and is_oracle_address(ext_addr) else '1';

   cpus : entity work.nds_dual_cpu_core
      port map (
         clk => clk, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => x"00000000", arm7_entry => x"037F8000",
         arm9_current_sp => x"027E392C", arm9_irq_sp => x"027E3F78",
         arm9_saved_sp => x"027E392C", arm7_current_sp => x"0380FD80",
         arm7_irq_sp => x"0380FF80", arm7_saved_sp => x"0380FD80",
         initial_cpsr => x"0000001F",
         global_step_enable => global_step_enable, boot_ready => boot_ready,
         arm9_cycles => cycles9, arm9_cycles_valid => cycles_valid9,
         arm7_cycles => cycles7, arm7_cycles_valid => cycles_valid7,
         arm9_debug_pc => debug_pc9, arm7_debug_pc => debug_pc7,
         arm9_diag_word => open,
         arm9_dtcm_region => dtcm_region, arm9_dtcm_enable => dtcm_enable,
         arm9_addr => addr9, arm9_rnw => rnw9, arm9_ena => ena9,
         arm9_acc => acc9, arm9_wdata => wdata9, arm9_rdata => rdata9,
         arm9_done => done9, arm9_irq => irq9, arm9_halt => halt9,
         arm7_addr => addr7, arm7_rnw => rnw7, arm7_ena => ena7,
         arm7_acc => acc7, arm7_wdata => wdata7, arm7_rdata => rdata7,
         arm7_done => done7, arm7_irq => irq7, arm7_halt => halt7
      );

   shared_bus : entity work.nds_dual_cpu_bus
      port map (
         clk => clk, reset => reset,
         arm9_addr => addr9, arm9_rnw => rnw9, arm9_ena => ena9,
         arm9_acc => acc9, arm9_wdata => wdata9,
         arm9_debug_pc => debug_pc9, arm9_rdata => rdata9,
         arm9_done => done9,
         arm7_addr => addr7, arm7_rnw => rnw7, arm7_ena => ena7,
         arm7_acc => acc7, arm7_wdata => wdata7,
         arm7_debug_pc => debug_pc7, arm7_rdata => rdata7,
         arm7_done => done7,
         ext_addr => ext_addr, ext_rnw => ext_rnw, ext_ena => ext_ena,
         ext_acc => ext_acc, ext_wdata => ext_wdata,
         ext_cpu_is_arm9 => ext_owner9, ext_debug_pc => ext_debug_pc,
         ext_rdata => ext_rdata, ext_done => ext_done
      );

   process(clk)
      variable local_delay : natural;
   begin
      if rising_edge(clk) then
         ext_done <= '0';
         if reset = '1' then
            responder_state <= RESP_IDLE;
            wait_count <= 0;
            response_data <= (others => '0');
            irq9 <= '0';
            irq7 <= '0';
            halt9 <= '0';
            halt7 <= '0';
            fifo_status_reads <= 0;
            gpu_reads <= 0;
            gpu_writes <= 0;
            arm7_sent_6b <= '0';
            arm9_read_6b <= '0';
            arm9_sent_ab <= '0';
            saw_irq_vector <= '0';
            saw_bios_epilogue <= '0';
            saw_outer_fifo <= '0';
         else
            case responder_state is
               when RESP_IDLE =>
                  if ext_ena = '1' then
                     request_addr <= ext_addr;
                     request_wdata <= ext_wdata;
                     request_rnw <= ext_rnw;
                     request_owner9 <= ext_owner9;
                     if ext_owner9 = '0' then
                        response_data <= arm7_word(ext_addr);
                     elsif unsigned(ext_addr) >= unsigned'(x"027E3E80") and
                           unsigned(ext_addr) < unsigned'(x"027E3F80") then
                        response_data <= irq_stack(
                           to_integer(unsigned(ext_addr(7 downto 2))));
                     elsif unsigned(ext_addr) >= unsigned'(x"027E3800") and
                           unsigned(ext_addr) < unsigned'(x"027E3A00") then
                        response_data <= system_stack(
                           to_integer(unsigned(ext_addr(8 downto 2))));
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
                           (0 => saw_bios_epilogue, others => '0');
                     elsif is_gpu_register(ext_addr) then
                        response_data <= (others => '0');
                     else
                        response_data <= arm9_word(ext_addr);
                     end if;
                     if is_oracle_address(ext_addr) then
                        local_delay := oracle_response_delay_cycles;
                     else
                        local_delay := 0;
                     end if;
                     wait_count <= local_delay;
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
                  if request_owner9 = '1' then
                     if request_rnw = '0' and
                        unsigned(request_addr) >= unsigned'(x"027E3E80") and
                        unsigned(request_addr) < unsigned'(x"027E3F80") then
                        irq_stack(
                           to_integer(unsigned(request_addr(7 downto 2)))) <=
                           request_wdata;
                     elsif request_rnw = '0' and
                           unsigned(request_addr) >= unsigned'(x"027E3800") and
                           unsigned(request_addr) < unsigned'(x"027E3A00") then
                        system_stack(
                           to_integer(unsigned(request_addr(8 downto 2)))) <=
                           request_wdata;
                     end if;
                     if request_rnw = '1' and
                        request_addr = x"04000184" then
                        fifo_status_reads <= fifo_status_reads + 1;
                     elsif request_rnw = '1' and
                           request_addr = x"04100000" then
                        arm9_read_6b <= '1';
                        irq9 <= '0';
                     elsif request_rnw = '0' and
                           request_addr = x"04000188" and
                           request_wdata = x"000000AB" then
                        arm9_sent_ab <= '1';
                     elsif is_gpu_register(request_addr) then
                        if request_rnw = '1' then
                           gpu_reads <= gpu_reads + 1;
                        else
                           gpu_writes <= gpu_writes + 1;
                        end if;
                     end if;
                     if request_rnw = '1' and request_addr = x"FFFF0018" then
                        saw_irq_vector <= '1';
                     elsif request_rnw = '1' and
                           request_addr = x"FFFF06F0" then
                        saw_bios_epilogue <= '1';
                     elsif request_rnw = '1' and
                           unsigned(request_addr) >= unsigned'(x"020689FC") and
                           unsigned(request_addr) <= unsigned'(x"02068AA4") then
                        saw_outer_fifo <= '1';
                     end if;
                  elsif request_rnw = '0' and
                        request_addr = x"04000188" and
                        request_wdata = x"0000006B" then
                     arm7_sent_6b <= '1';
                     irq9 <= '1';
                  end if;
               when RESP_RELEASE =>
                  if ext_ena = '0' then
                     responder_state <= RESP_IDLE;
                  end if;
            end case;
         end if;
      end if;
   end process;

   process
   begin
      reset <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';
      descriptor_valid <= '1';
      wait until arm9_sent_ab = '1' for 10 ms;
      report "dual SDK replay: sent6b=" & std_logic'image(arm7_sent_6b) &
             " read6b=" & std_logic'image(arm9_read_6b) &
             " irq=" & std_logic'image(saw_irq_vector) &
             " gpu=" & natural'image(gpu_reads) & "/" &
             natural'image(gpu_writes) &
             " bios=" & std_logic'image(saw_bios_epilogue) &
             " outer=" & std_logic'image(saw_outer_fifo) &
             " ab=" & std_logic'image(arm9_sent_ab) &
             " pc9=" & to_hstring(debug_pc9)
         severity note;
      assert arm7_sent_6b = '1'
         report "real ARM7 pipeline did not send command 0x6B"
         severity failure;
      assert arm9_read_6b = '1'
         report "real ARM9 pipeline did not consume command 0x6B"
         severity failure;
      assert saw_irq_vector = '1'
         report "ARM9 did not enter the high IRQ vector"
         severity failure;
      assert gpu_reads = 8 and gpu_writes = 8
         report "integrated GPU transaction count mismatch"
         severity failure;
      assert saw_bios_epilogue = '1'
         report "integrated ARM9 did not reach the BIOS epilogue"
         severity failure;
      assert saw_outer_fifo = '1'
         report "integrated ARM9 did not resume the outer FIFO routine"
         severity failure;
      assert arm9_sent_ab = '1'
         report "integrated ARM9 did not send reply 0xAB"
         severity failure;
      report "PASS: two scheduled FPGA CPUs complete Mario 0x6B -> 0xAB IPC"
         severity note;
      stop;
      wait;
   end process;
end architecture;
