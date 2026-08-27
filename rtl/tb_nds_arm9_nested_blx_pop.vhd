library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

-- Reproduce Mario's next post-r121 hardware/native divergence:
--
--   02025fc8  FAFFFAB5  BLX 02024aa4 (Thumb)
--   02024aa4  B510      PUSH {r4,lr}
--   02024aa8  F7E9
--   02024aaa  ED54      BLX 0200e554 (ARM)
--   0200e55c  E12FFF1E  BX lr
--   02024ab2  BD10      POP {r4,pc}
--                         native -> ARM 02025fcc
--
-- r122 reaches the inner ARM target and returns to Thumb correctly, but the
-- final POP resumes at 02025b12. This test keeps a real writable stack so the
-- ARM/Thumb link value is checked across the complete nested call sequence.
entity tb_nds_arm9_nested_blx_pop is
   generic (bus_response_delay_cycles : natural := 3);
end entity;

architecture sim of tb_nds_arm9_nested_blx_pop is
   type responder_state_t is (RESP_IDLE, RESP_WAIT, RESP_DONE, RESP_RELEASE);
   signal clk, reset : std_logic := '0';
   signal save : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata, debug_pc, debug_execute_pc, debug_mixed :
      std_logic_vector(31 downto 0);
   signal rnw, ena, bus_done : std_logic;
   signal acc : std_logic_vector(1 downto 0);
   signal responder_state : responder_state_t := RESP_IDLE;
   signal wait_count : natural := 0;
   signal request_addr : std_logic_vector(31 downto 0) := (others => '0');
   signal request_wdata : std_logic_vector(31 downto 0) := (others => '0');
   signal request_rnw : std_logic := '1';
   signal stack_r4, stack_lr : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal saw_inner_arm, saw_thumb_return, saw_expected_return : std_logic :=
      '0';
   signal saw_wrong_return : std_logic := '0';
begin
   clk <= not clk after 5 ns;

   process(all)
   begin
      case request_addr is
         -- Reset shim: initialize SP, then branch to Mario's exact ARM caller.
         when x"00000000" => rdata <= x"E59FD010"; -- ldr sp,[pc,#16]
         when x"00000004" => rdata <= x"E59F0010"; -- ldr r0,[pc,#16]
         when x"00000008" => rdata <= x"E59F1010"; -- ldr r1,[pc,#16]
         when x"0000000C" => rdata <= x"E12FFF11"; -- bx r1
         when x"00000018" => rdata <= x"02001000"; -- initial SP
         when x"0000001C" => rdata <= x"02002000"; -- safe r0 payload
         when x"00000020" => rdata <= x"02025FC8"; -- caller address

         -- Exact outer ARM BLX immediate and its expected return.
         when x"02025FC8" => rdata <= x"FAFFFAB5"; -- BLX 02024aa4
         when x"02025FCC" => rdata <= x"E59F0034"; -- exact native ARM word
         when x"02025FD0" => rdata <= x"E59F1034"; -- ARM-state proof
         when x"02025FD4" => rdata <= x"E5801000"; -- str r1,[r0]
         when x"02025FD8" => rdata <= x"EAFFFFFE"; -- b .
         when x"02026008" => rdata <= x"04000188";
         when x"0202600C" => rdata <= x"000000AB";

         -- Exact Thumb function body.
         when x"02024AA4" => rdata <= x"0000B510"; -- push {r4,lr}
         when x"02024AA6" => rdata <= x"00001C04"; -- mov r4,r0
         when x"02024AA8" => rdata <= x"0000F7E9"; -- BLX high half
         when x"02024AAA" => rdata <= x"0000ED54"; -- BLX low half
         when x"02024AAC" => rdata <= x"00004801"; -- ldr r0,[pc,#4]
         when x"02024AAE" => rdata <= x"00006020"; -- str r0,[r4,#0]
         when x"02024AB0" => rdata <= x"00001C20"; -- mov r0,r4
         when x"02024AB2" => rdata <= x"0000BD10"; -- pop {r4,pc}
         when x"02024AB4" => rdata <= x"02002004"; -- literal

         -- Exact inner ARM leaf.
         when x"0200E554" => rdata <= x"E59F1004"; -- ldr r1,[pc,#4]
         when x"0200E558" => rdata <= x"E5801000"; -- str r1,[r0]
         when x"0200E55C" => rdata <= x"E12FFF1E"; -- bx lr
         when x"0200E560" => rdata <= x"12345678";

         -- Writable stack used by PUSH/POP.
         when x"02000FF8" => rdata <= stack_r4;
         when x"02000FFC" => rdata <= stack_lr;
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
            stack_r4 <= (others => '0');
            stack_lr <= (others => '0');
         else
            case responder_state is
               when RESP_IDLE =>
                  if ena = '1' then
                     request_addr <= addr;
                     request_wdata <= wdata;
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
                  if request_rnw = '0' then
                     if request_addr = x"02000FF8" then
                        stack_r4 <= request_wdata;
                     elsif request_addr = x"02000FFC" then
                        stack_lr <= request_wdata;
                     end if;
                  end if;
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
         debug_cpu_pc => debug_pc, debug_cpu_execute_pc => debug_execute_pc,
         debug_cpu_mixed => debug_mixed,
         arm9_dtcm_region => open, arm9_dtcm_enable => open
      );

   process(clk)
   begin
      if rising_edge(clk) then
         if debug_execute_pc = x"0200E554" then saw_inner_arm <= '1'; end if;
         if debug_execute_pc = x"02024AAC" then saw_thumb_return <= '1'; end if;
         if bus_done = '1' and request_rnw = '0' and
            request_addr = x"04000188" and request_wdata = x"000000AB" then
            saw_expected_return <= '1';
         end if;
         if debug_execute_pc = x"02025B12" then saw_wrong_return <= '1'; end if;
      end if;
   end process;

   process
   begin
      reset <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';
      wait until saw_expected_return = '1' for 100 us;
      wait for 2 us;
      assert saw_inner_arm = '1'
         report "nested BLX path did not reach inner ARM target"
         severity failure;
      assert saw_thumb_return = '1'
         report "nested BLX path did not return to Thumb caller"
         severity failure;
      assert stack_lr = x"02025FCC"
         report "outer ARM BLX link was not preserved on the Thumb stack"
         severity failure;
      assert saw_wrong_return = '0'
         report "Thumb POP reproduced hardware's wrong 02025b12 return"
         severity failure;
      assert saw_expected_return = '1'
         report "Thumb POP did not exchange into ARM state at 02025fcc"
         severity failure;
      report "PASS: nested BLX POP exchanges into ARM state at 02025fcc"
         severity note;
      stop;
      wait;
   end process;
end architecture;
