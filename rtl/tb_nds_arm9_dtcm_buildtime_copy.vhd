library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

entity tb_nds_arm9_dtcm_buildtime_copy is
   generic (
      bus_response_delay_cycles : natural := 0;
      step_period : positive := 1
   );
end entity;

architecture sim of tb_nds_arm9_dtcm_buildtime_copy is
   signal clk, reset, descriptor_valid, boot_reset, boot_ready :
      std_logic := '0';
   signal save9, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata : std_logic_vector(31 downto 0);
   signal rnw, ena, done : std_logic;
   signal acc : std_logic_vector(1 downto 0);
   signal cpu_step : std_logic := '1';
   signal step_counter : natural := 0;
   signal write_count : natural range 0 to 5 := 0;
   signal dtcm_word0 : std_logic_vector(31 downto 0) := (others => '0');
   signal dtcm_word1 : std_logic_vector(31 downto 0) := (others => '0');
   signal dtcm_word2 : std_logic_vector(31 downto 0) := (others => '0');

   type response_state_t is (response_idle, response_wait, response_release);
   signal response_state : response_state_t := response_idle;
   signal response_delay : natural := 0;
   signal pending_addr, pending_wdata : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal pending_rnw : std_logic := '1';
   signal pending_acc : std_logic_vector(1 downto 0) := (others => '0');

   type word_array_t is array (0 to 4) of std_logic_vector(31 downto 0);
   constant expected_address : word_array_t := (
      x"027E37D8", x"027E37DA", x"027E37DC", x"027E37DE",
      x"027E37E0");
   constant expected_data : word_array_t := (
      x"00495542", x"00444C49", x"00495444", x"00454D49",
      x"00000045");
begin
   clk <= not clk after 5 ns;
   cpu_step <= '1' when step_counter = 0 else '0';

   process(clk)
   begin
      if rising_edge(clk) then
         if reset = '1' or step_counter + 1 >= step_period then
            step_counter <= 0;
         else
            step_counter <= step_counter + 1;
         end if;
      end if;
   end process;

   boot : entity work.nds_cpu_boot_sequencer
      port map (
         clk => clk, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => x"02067000", arm7_entry => x"00001000",
         arm9_current_sp => x"027E3F80", arm9_irq_sp => x"027E3FBC",
         arm9_saved_sp => x"027E3F80", arm7_current_sp => x"00003000",
         arm7_irq_sp => x"00003040", arm7_saved_sp => x"00003080",
         initial_cpsr => x"2000001F", cpu_reset => boot_reset,
         boot_ready => boot_ready, save9 => save9, save7 => save7
      );

   process(all)
   begin
      rdata <= (others => '0');
      case pending_addr is
         -- Load the native copy arguments, then enter the exact SDK copy
         -- sequence used to build the DTCM string "BUILDTIME".
         when x"02067000" => rdata <= x"E59F0010"; -- ldr r0,[pc,#16]
         when x"02067004" => rdata <= x"E59F1010"; -- ldr r1,[pc,#16]
         when x"02067008" => rdata <= x"E3A02009"; -- mov r2,#9
         when x"0206700C" => rdata <= x"E59FE00C"; -- ldr lr,[pc,#12]
         when x"02067010" => rdata <= x"EA00001B"; -- b 0x02067084
         when x"02067018" => rdata <= x"02096A89";
         when x"0206701C" => rdata <= x"027E37D8";
         when x"02067020" => rdata <= x"020697B0";

         when x"02067084" => rdata <= x"E3520000";
         when x"02067088" => rdata <= x"012FFF1E";
         when x"0206708C" => rdata <= x"E3110001";
         when x"02067090" => rdata <= x"0A00000B";
         when x"020670C4" => rdata <= x"E021C000";
         when x"020670C8" => rdata <= x"E31C0001";
         when x"020670CC" => rdata <= x"0A000011";
         when x"020670D0" => rdata <= x"E3C00001";
         when x"020670D4" => rdata <= x"E0D0C0B2";
         when x"020670D8" => rdata <= x"E1A0342C";
         when x"020670DC" => rdata <= x"E2522002";
         when x"020670E0" => rdata <= x"3A000005";
         when x"020670E4" => rdata <= x"E0D0C0B2";
         when x"020670E8" => rdata <= x"E183C40C";
         when x"020670EC" => rdata <= x"E0C1C0B2";
         when x"020670F0" => rdata <= x"E1A0382C";
         when x"020670F4" => rdata <= x"E2522002";
         when x"020670F8" => rdata <= x"2AFFFFF9";
         when x"020670FC" => rdata <= x"E3120001";
         when x"02067100" => rdata <= x"012FFF1E";
         when x"02067104" => rdata <= x"E1D1C0B0";
         when x"02067108" => rdata <= x"E20CCCFF";
         when x"0206710C" => rdata <= x"E18CC003";
         when x"02067110" => rdata <= x"E1C1C0B0";
         when x"02067114" => rdata <= x"E12FFF1E";

         -- Source halfwords for the odd-address copy.
         when x"02096A88" => rdata <= x"00004209";
         when x"02096A8A" => rdata <= x"00004955";
         when x"02096A8C" => rdata <= x"0000444C";
         when x"02096A8E" => rdata <= x"00004954";
         when x"02096A90" => rdata <= x"0000454D";

         -- Destination readback used by the final odd-byte merge.
         when x"027E37D8" => rdata <= dtcm_word0;
         when x"027E37DC" => rdata <= dtcm_word1;
         when x"027E37E0" => rdata <= dtcm_word2;

         -- The return target is sufficient to prove the copy completed.
         when x"020697B0" => rdata <= x"EAFFFFFE";
         when others => rdata <= x"EAFFFFFE";
      end case;
   end process;

   process(clk)
      variable write_index : natural;
   begin
      if rising_edge(clk) then
         done <= '0';
         if reset = '1' then
            response_state <= response_idle;
            response_delay <= 0;
            pending_addr <= (others => '0');
            pending_wdata <= (others => '0');
            pending_rnw <= '1';
            pending_acc <= (others => '0');
            write_count <= 0;
            dtcm_word0 <= (others => '0');
            dtcm_word1 <= (others => '0');
            dtcm_word2 <= (others => '0');
         else
            case response_state is
               when response_idle =>
                  if ena = '1' then
                     pending_addr <= addr;
                     pending_wdata <= wdata;
                     pending_rnw <= rnw;
                     pending_acc <= acc;
                     response_delay <= bus_response_delay_cycles;
                     response_state <= response_wait;
                  end if;

               when response_wait =>
                  if response_delay > 0 then
                     response_delay <= response_delay - 1;
                  else
                     done <= '1';
                     if pending_rnw = '0' and
                           unsigned(pending_addr) >= unsigned'(x"027E37D8") and
                           unsigned(pending_addr) <= unsigned'(x"027E37E0") then
                        write_index := write_count;
                        assert write_index < 5
                           report "unexpected extra BUILDTIME DTCM write"
                           severity failure;
                        assert pending_addr = expected_address(write_index)
                           report "post-index STRH address mismatch at write " &
                              integer'image(write_index) & ": " &
                              to_hstring(pending_addr)
                           severity failure;
                        assert pending_acc = "01"
                           report "BUILDTIME copy did not issue a halfword write"
                           severity failure;
                        assert pending_wdata = expected_data(write_index)
                           report "post-index STRH data mismatch at write " &
                              integer'image(write_index) & ": " &
                              to_hstring(pending_wdata)
                           severity failure;
                        write_count <= write_count + 1;
                        case pending_addr(3 downto 2) is
                           when "10" =>
                              if pending_addr(1) = '0' then
                                 dtcm_word0(15 downto 0) <=
                                    pending_wdata(15 downto 0);
                              else
                                 dtcm_word0(31 downto 16) <=
                                    pending_wdata(15 downto 0);
                              end if;
                           when "11" =>
                              if pending_addr(1) = '0' then
                                 dtcm_word1(15 downto 0) <=
                                    pending_wdata(15 downto 0);
                              else
                                 dtcm_word1(31 downto 16) <=
                                    pending_wdata(15 downto 0);
                              end if;
                           when others =>
                              dtcm_word2(15 downto 0) <=
                                 pending_wdata(15 downto 0);
                        end case;
                     end if;
                     response_state <= response_release;
                  end if;

               when response_release =>
                  if ena = '1' and
                        (addr /= pending_addr or rnw /= pending_rnw or
                         acc /= pending_acc) then
                     pending_addr <= addr;
                     pending_wdata <= wdata;
                     pending_rnw <= rnw;
                     pending_acc <= acc;
                     response_delay <= bus_response_delay_cycles;
                     response_state <= response_wait;
                  elsif ena = '0' then
                     response_state <= response_idle;
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
         clk100 => clk, gb_on => '1', reset => boot_reset,
         savestate_bus => save9, gb_bus_Adr => addr, gb_bus_rnw => rnw,
         gb_bus_ena => ena, gb_bus_acc => acc, gb_bus_dout => wdata,
         gb_bus_din => rdata, gb_bus_done => done,
         wait_cnt_value => (others => '0'), wait_cnt_update => '0',
         Underclock => "00", bus_lowbits => open, settle => '0',
         dma_on => '0', do_step => cpu_step, done => open,
         CPU_bus_idle => open, PC_in_BIOS => open, lastread => open,
         jump_out => open, new_cycles_out => open, new_cycles_valid => open,
         dma_new_cycles => '0', dma_first_cycles => '0',
         dma_dword_cycles => '0', dma_toROM => '0',
         dma_init_cycles => '0', dma_cycles_adrup => (others => '0'),
         IRP_in => (others => '0'), cpu_IRP => '0', new_halt => '0',
         clear_halt => '0', DISPSTAT_debug => (others => '0'),
         debug_fifocount => 0, timerdebug0 => (others => '0'),
         timerdebug1 => (others => '0'), timerdebug2 => (others => '0'),
         timerdebug3 => (others => '0'), debug_cpu_pc => open,
         debug_cpu_execute_pc => open, debug_cpu_mixed => open,
         arm9_dtcm_region => open, arm9_dtcm_enable => open
      );

   process
   begin
      reset <= '1';
      wait until rising_edge(clk);
      reset <= '0';
      descriptor_valid <= '1';
      wait until boot_ready = '1';
      wait until write_count = 5 for 500 us;
      assert write_count = 5
         report "BUILDTIME copy did not complete five DTCM writes"
         severity failure;
      wait until rising_edge(clk);
      assert dtcm_word0 = x"4C495542"
         report "BUILDTIME bytes 0..3 corrupt: " & to_hstring(dtcm_word0)
         severity failure;
      assert dtcm_word1 = x"4D495444"
         report "BUILDTIME bytes 4..7 corrupt: " & to_hstring(dtcm_word1)
         severity failure;
      assert dtcm_word2(15 downto 0) = x"0045"
         report "BUILDTIME final byte corrupt: " & to_hstring(dtcm_word2)
         severity failure;
      report "PASS: exact SDK post-index STRH loop builds BUILDTIME in DTCM"
         severity note;
      stop;
      wait;
   end process;
end architecture;
