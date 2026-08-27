library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

-- Full architectural multiply check for ARM9.  The constants below are
-- independently assembled ARMv5TE instructions and melonDS-equivalent
-- results.  The stream deliberately changes x/y/word/long controls on every
-- instruction so a pipeline that consumes live decoder controls is exposed.
entity tb_nds_arm9_multiply_oracle is
   generic (
      bus_response_delay_cycles : natural := 0;
      step_period : positive := 1
   );
end entity;

architecture sim of tb_nds_arm9_multiply_oracle is
   constant entry_address : std_logic_vector(31 downto 0) := x"0205B040";
   constant marker_address : unsigned(31 downto 0) := x"04000000";

   type result_array_t is array (natural range <>) of
      std_logic_vector(31 downto 0);
   constant expected : result_array_t := (
      x"8000FFEC", x"7FFF7FF2", x"7FFEFFF2", x"80007FEF",
      x"0000FFFC", x"FFFF8002", x"FFFF0002", x"00007FFF",
      x"7FFEFFF2", x"80007FEE", x"FFFF0002", x"00007FFE",
      x"0001000C", x"00000001", x"FFFF8012", x"00000000",
      x"FFFF0012", x"00000000", x"0000800F", x"00000001",
      x"8004FFFC", x"0004FFEC", x"8004FFFC", x"8000FFFD",
      x"8005000C", x"8000FFFE", x"8004FFFC", x"00007FFD",
      x"8005000C", x"00007FFE"
   );

   signal clk, reset, boot_reset, boot_ready : std_logic := '0';
   signal save9 : proc_bus_gb_type :=
      ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');
   signal addr, wdata, rdata : std_logic_vector(31 downto 0);
   signal rnw, ena, bus_done : std_logic := '0';
   signal acc : std_logic_vector(1 downto 0);
   signal cpu_step : std_logic := '1';
   signal step_counter : natural := 0;

   type response_state_t is
      (response_idle, response_wait, response_release);
   signal response_state : response_state_t := response_idle;
   signal response_delay : natural := 0;
   signal pending_addr, pending_wdata : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal pending_rnw : std_logic := '1';
   signal pending_acc : std_logic_vector(1 downto 0) := ACCESS_32BIT;
   signal result_count : natural range 0 to expected'length := 0;
   type boot_state_t is (boot_clear, boot_write, boot_load, boot_run);
   type boot_address_array_t is array (0 to 8) of natural range 0 to 46;
   constant boot_address : boot_address_array_t :=
      (0, 13, 14, 15, 16, 17, 24, 34, 46);
   signal boot_state : boot_state_t := boot_clear;
   signal boot_index : natural range 0 to 8 := 0;
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

   process(all)
   begin
      save9 <= ((others => '0'), (others => '0'), '1', '0',
                "00", "0000", '0');
      boot_reset <= '1';
      boot_ready <= '0';
      case boot_state is
         when boot_clear =>
            save9.rst <= '1';
         when boot_write =>
            save9.Adr <= std_logic_vector(to_unsigned(
               boot_address(boot_index), save9.Adr'length));
            save9.rnw <= '0';
            save9.ena <= '1';
            save9.acc <= ACCESS_32BIT;
            save9.bEna <= "1111";
            case boot_index is
               when 0 | 1 | 3 => save9.Din <= entry_address;
               when 2 | 6 => save9.Din <= x"0205C000";
               when 4 => save9.Din <= std_logic_vector(
                  unsigned(entry_address) + 8);
               when 5 => save9.Din <= x"0000001F";
               when 7 => save9.Din <= x"027E3FBC";
               when others => save9.Din <= x"00000CC0";
            end case;
         when boot_load =>
            null;
         when boot_run =>
            boot_reset <= '0';
            boot_ready <= '1';
      end case;
   end process;

   process(clk)
   begin
      if rising_edge(clk) then
         if reset = '1' then
            boot_state <= boot_clear;
            boot_index <= 0;
         else
            case boot_state is
               when boot_clear =>
                  boot_state <= boot_write;
               when boot_write =>
                  if boot_index = boot_address'high then
                     boot_state <= boot_load;
                  else
                     boot_index <= boot_index + 1;
                  end if;
               when boot_load =>
                  boot_state <= boot_run;
               when boot_run =>
                  null;
            end case;
         end if;
      end if;
   end process;

   process(all)
   begin
      case pending_addr is
         when x"0205B040" => rdata <= x"E3A07301";
         when x"0205B044" => rdata <= x"E59F0108";
         when x"0205B048" => rdata <= x"E59F1108";
         when x"0205B04C" => rdata <= x"E3E0213E";
         when x"0205B050" => rdata <= x"E1042180";
         when x"0205B054" => rdata <= x"E5874000";
         when x"0205B058" => rdata <= x"E10421C0";
         when x"0205B05C" => rdata <= x"E5874004";
         when x"0205B060" => rdata <= x"E10421A0";
         when x"0205B064" => rdata <= x"E5874008";
         when x"0205B068" => rdata <= x"E10421E0";
         when x"0205B06C" => rdata <= x"E587400C";
         when x"0205B070" => rdata <= x"E1640180";
         when x"0205B074" => rdata <= x"E5874010";
         when x"0205B078" => rdata <= x"E16401C0";
         when x"0205B07C" => rdata <= x"E5874014";
         when x"0205B080" => rdata <= x"E16401A0";
         when x"0205B084" => rdata <= x"E5874018";
         when x"0205B088" => rdata <= x"E16401E0";
         when x"0205B08C" => rdata <= x"E587401C";
         when x"0205B090" => rdata <= x"E1242180";
         when x"0205B094" => rdata <= x"E5874020";
         when x"0205B098" => rdata <= x"E12421C0";
         when x"0205B09C" => rdata <= x"E5874024";
         when x"0205B0A0" => rdata <= x"E12401A0";
         when x"0205B0A4" => rdata <= x"E5874028";
         when x"0205B0A8" => rdata <= x"E12401E0";
         when x"0205B0AC" => rdata <= x"E587402C";
         when x"0205B0B0" => rdata <= x"E3A05010";
         when x"0205B0B4" => rdata <= x"E3A06001";
         when x"0205B0B8" => rdata <= x"E1465180";
         when x"0205B0BC" => rdata <= x"E5875030";
         when x"0205B0C0" => rdata <= x"E5876034";
         when x"0205B0C4" => rdata <= x"E3A05010";
         when x"0205B0C8" => rdata <= x"E3A06001";
         when x"0205B0CC" => rdata <= x"E14651C0";
         when x"0205B0D0" => rdata <= x"E5875038";
         when x"0205B0D4" => rdata <= x"E587603C";
         when x"0205B0D8" => rdata <= x"E3A05010";
         when x"0205B0DC" => rdata <= x"E3A06001";
         when x"0205B0E0" => rdata <= x"E14651A0";
         when x"0205B0E4" => rdata <= x"E5875040";
         when x"0205B0E8" => rdata <= x"E5876044";
         when x"0205B0EC" => rdata <= x"E3A05010";
         when x"0205B0F0" => rdata <= x"E3A06001";
         when x"0205B0F4" => rdata <= x"E14651E0";
         when x"0205B0F8" => rdata <= x"E5875048";
         when x"0205B0FC" => rdata <= x"E587604C";
         when x"0205B100" => rdata <= x"E0040190";
         when x"0205B104" => rdata <= x"E5874050";
         when x"0205B108" => rdata <= x"E0242190";
         when x"0205B10C" => rdata <= x"E5874054";
         when x"0205B110" => rdata <= x"E0865190";
         when x"0205B114" => rdata <= x"E5875058";
         when x"0205B118" => rdata <= x"E587605C";
         when x"0205B11C" => rdata <= x"E3A05010";
         when x"0205B120" => rdata <= x"E3A06001";
         when x"0205B124" => rdata <= x"E0A65190";
         when x"0205B128" => rdata <= x"E5875060";
         when x"0205B12C" => rdata <= x"E5876064";
         when x"0205B130" => rdata <= x"E0C65190";
         when x"0205B134" => rdata <= x"E5875068";
         when x"0205B138" => rdata <= x"E587606C";
         when x"0205B13C" => rdata <= x"E3A05010";
         when x"0205B140" => rdata <= x"E3A06001";
         when x"0205B144" => rdata <= x"E0E65190";
         when x"0205B148" => rdata <= x"E5875070";
         when x"0205B14C" => rdata <= x"E5876074";
         when x"0205B150" => rdata <= x"EAFFFFFE";
         when x"0205B154" => rdata <= x"80017FFE";
         when x"0205B158" => rdata <= x"FFFF0002";
         when others => rdata <= (others => '0');
      end case;
   end process;

   process(clk)
      variable offset : natural;
   begin
      if rising_edge(clk) then
         bus_done <= '0';
         if reset = '1' then
            response_state <= response_idle;
            response_delay <= 0;
            pending_addr <= (others => '0');
            pending_wdata <= (others => '0');
            pending_rnw <= '1';
            pending_acc <= ACCESS_32BIT;
            result_count <= 0;
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
                     bus_done <= '1';
                     if unsigned(pending_addr) >= marker_address and
                           unsigned(pending_addr) < marker_address +
                              to_unsigned(expected'length * 4, 32) and
                           pending_rnw = '0' then
                        offset := to_integer(unsigned(pending_addr) -
                           marker_address) / 4;
                        assert pending_acc = ACCESS_32BIT
                           report "multiply oracle store was not 32-bit"
                           severity failure;
                        assert offset = result_count
                           report "multiply oracle store order mismatch"
                           severity failure;
                        assert pending_wdata = expected(offset)
                           report "multiply result mismatch index=" &
                              integer'image(offset) & " got=" &
                              to_hstring(pending_wdata) & " expected=" &
                              to_hstring(expected(offset))
                           severity failure;
                        result_count <= result_count + 1;
                     end if;
                     response_state <= response_release;
                  end if;
               when response_release =>
                  if ena = '1' and
                     (addr /= pending_addr or rnw /= pending_rnw) then
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

   dut : entity work.nds_cpu9
      generic map (
         is_simu => '1', SS_PRESET_ONLY => '1'
      )
      port map (
         clk => clk, ce => cpu_step, reset => boot_reset,
         cpu_export_done => open, cpu_export => open,
         error_cpu => open, dbg_pc => open, dbg_r0 => open,
         dbg_lr => open, dbg_cpsr => open,
         dbg_regsel => (others => '0'), dbg_regval => open,
         savestate_bus => save9, gb_bus_Adr => addr, gb_bus_rnw => rnw,
         ss_wired_out => open, ss_wired_done => open,
         gb_bus_ena => ena, gb_bus_seq => open, gb_bus_code => open,
         gb_bus_acc => acc, gb_bus_dout => wdata, gb_bus_din => rdata,
         gb_bus_done => bus_done, gb_bus_lock => open,
         bus_lowbits => open, dma_on => '0', done => open,
         CPU_bus_idle => open, PC_in_BIOS => open, cpu_halt => open,
         lastread => open, jump_out => open, IRQ_in => '0',
         unhalt => '0', new_halt => '0', cp15_vector_hi => open,
         cp15_pu_enable => open, cp15_icache_ena => open,
         cp15_dcache_ena => open, cp15_itcm_ena => open,
         cp15_itcm_load => open, cp15_dtcm_ena => open,
         cp15_dtcm_load => open, cp15_dtcm_base => open,
         cp15_dtcm_size => open, cp15_itcm_size => open,
         bus_cacheable_i => open, bus_cacheable_d => open,
         cache_op_ena => open, cache_op => open, cache_op_addr => open,
         cache_op_busy => '0'
      );

   process
   begin
      reset <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';
      wait until boot_ready = '1';
      wait until result_count = expected'length for 500 us;
      assert result_count = expected'length
         report "multiply oracle did not complete all results"
         severity failure;
      report "PASS: ARM9 multiply families match architectural oracle"
         severity note;
      stop;
      wait;
   end process;

   process
   begin
      wait for 1 ms;
      assert false report "timeout waiting for multiply oracle"
         severity failure;
      wait;
   end process;
end architecture;
