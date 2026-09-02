library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

-- Reproduce Mario's first r120 hardware/native divergence exactly:
--
--   02024aa8  f7e9    BLX high half
--   02024aaa  ed54    BLX low half
--              ->    ARM target 0200e554
--
-- The reused ARM7TDMI decoder historically treated the ARM9-only EDxx low
-- half as an unconditional Thumb branch and landed at 0202455a instead.
entity tb_nds_arm9_thumb_blx_link is
   generic (bus_response_delay_cycles : natural := 3);
end entity;

architecture sim of tb_nds_arm9_thumb_blx_link is
   type responder_state_t is (RESP_IDLE, RESP_WAIT, RESP_DONE, RESP_RELEASE);
   signal clk, reset : std_logic := '0';
   signal save : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata, debug_pc : std_logic_vector(31 downto 0);
   signal rnw, ena, bus_done : std_logic;
   signal acc : std_logic_vector(1 downto 0);
   signal responder_state : responder_state_t := RESP_IDLE;
   signal wait_count : natural := 0;
   signal request_addr : std_logic_vector(31 downto 0) := (others => '0');
   signal request_rnw : std_logic := '1';
   signal saw_target, saw_wrong_target : std_logic := '0';
begin
   clk <= not clk after 5 ns;

   process(all)
   begin
      case request_addr is
         when x"00000000" => rdata <= x"E59F0008"; -- ldr r0,[pc,#8]
         when x"00000004" => rdata <= x"E12FFF10"; -- bx r0
         when x"00000008" => rdata <= x"EAFFFFFE"; -- b .
         when x"00000010" => rdata <= x"02024AA9"; -- Thumb entry
         when x"02024AA8" => rdata <= x"0000F7E9"; -- exact BLX high half
         when x"02024AAA" => rdata <= x"0000ED54"; -- exact BLX low half
         when x"0200E554" => rdata <= x"EAFFFFFE"; -- correct ARM target
         when others => rdata <= x"E1A00000";
      end case;
   end process;

   process(clk)
   begin
      if rising_edge(clk) then
         bus_done <= '0';
         if reset = '1' then
            responder_state <= RESP_IDLE;
            wait_count <= 0;
         else
            case responder_state is
               when RESP_IDLE =>
                  if ena = '1' then
                     request_addr <= addr;
                     request_rnw <= rnw;
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
                  bus_done <= '1';
                  responder_state <= RESP_RELEASE;
               when RESP_RELEASE =>
                  if ena = '0' then responder_state <= RESP_IDLE; end if;
            end case;
         end if;
      end if;
   end process;

   dut : entity work.gba_cpu
      generic map (is_simu => '1', is_arm9 => '1')
      port map (
         clk100 => clk, gb_on => '1', reset => reset, savestate_bus => save,
         gb_bus_Adr => addr, gb_bus_rnw => rnw, gb_bus_ena => ena,
         gb_bus_acc => acc, gb_bus_dout => wdata, gb_bus_din => rdata,
         gb_bus_done => bus_done, wait_cnt_value => (others => '0'),
         wait_cnt_update => '0', Underclock => "00", bus_lowbits => open,
         settle => '0', dma_on => '0', do_step => '1', done => open,
         CPU_bus_idle => open, PC_in_BIOS => open, lastread => open,
         jump_out => open, new_cycles_out => open, new_cycles_valid => open,
         dma_new_cycles => '0', dma_first_cycles => '0',
         dma_dword_cycles => '0', dma_toROM => '0', dma_init_cycles => '0',
         dma_cycles_adrup => (others => '0'), IRP_in => (others => '0'),
         cpu_IRP => '0', new_halt => '0', clear_halt => '0',
         DISPSTAT_debug => (others => '0'), debug_fifocount => 0,
         timerdebug0 => (others => '0'), timerdebug1 => (others => '0'),
         timerdebug2 => (others => '0'), timerdebug3 => (others => '0'),
         debug_cpu_pc => debug_pc, debug_cpu_execute_pc => open,
         debug_cpu_mixed => open,
         arm9_dtcm_region => open, arm9_dtcm_enable => open
      );

   process(clk)
   begin
      if rising_edge(clk) and bus_done = '1' and request_rnw = '1' then
         if request_addr = x"0200E554" then saw_target <= '1'; end if;
         if request_addr = x"0202455A" then saw_wrong_target <= '1'; end if;
      end if;
   end process;

   process
   begin
      reset <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';
      wait until saw_target = '1' for 20 us;
      assert saw_target = '1'
         report "ARM9 Thumb BLX did not reach ARM target 0200e554"
         severity failure;
      assert saw_wrong_target = '0'
         report "ARM9 Thumb BLX was misdecoded as branch to 0202455a"
         severity failure;
      report "PASS: exact ARM9 Thumb BLX pair reaches ARM target" severity note;
      stop;
      wait;
   end process;
end architecture;
