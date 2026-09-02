library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

entity tb_nds_arm9_blx_link is
   generic (irq_delay_cycles : natural := 0);
end entity;

architecture sim of tb_nds_arm9_blx_link is
   type responder_state_t is (RESP_IDLE, RESP_WAIT, RESP_DONE,
                              RESP_RELEASE);
   signal clk, reset : std_logic := '0';
   signal save : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata, debug_pc : std_logic_vector(31 downto 0);
   signal rnw, ena, bus_done : std_logic;
   signal acc : std_logic_vector(1 downto 0);
   signal ext_addr, ext_wdata, ext_rdata : std_logic_vector(31 downto 0);
   signal ext_rnw, ext_ena, ext_done, ext_cpu9 : std_logic;
   signal ext_acc : std_logic_vector(1 downto 0);
   signal arm7_addr, arm7_rdata : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal arm7_ena, arm7_done : std_logic := '0';
   signal saw_target, saw_return, saw_blx_fetch, saw_irq_vector :
      std_logic := '0';
   signal irq : std_logic := '0';
   signal responder_state : responder_state_t := RESP_IDLE;
   signal wait_count : natural range 0 to 7 := 0;
   signal request_addr : std_logic_vector(31 downto 0) := (others => '0');
   signal request_rnw : std_logic := '1';
begin
   clk <= not clk after 5 ns;

   process(all)
   begin
      -- Poison every competing ARM7 response with the exact ARM7 BIOS word
      -- that became ARM9's corrupted R14 on hardware. Any response-owner
      -- leakage across nds_dual_cpu_bus must now reproduce deterministically.
      if ext_cpu9 = '0' then
         ext_rdata <= x"E1510000";
      else
       case request_addr is
         when x"00000000" => ext_rdata <= x"E3A0001F"; -- mov r0,#0x1f
         when x"00000004" => ext_rdata <= x"E129F000"; -- msr cpsr_fc,r0
         -- Exact ARM9 opcode seen at Mario PC 0x0207ccac. Relocated to 8,
         -- its signed target is 0xfff83a9c.
         when x"00000008" => ext_rdata <= x"FAFE0EA3";
         when x"0000000C" => ext_rdata <= x"EAFFFFFE"; -- return target: b .
         -- Exact ARM9 BIOS IME helper sequence from 0x01ff8230..0x01ff8258,
         -- relocated to 0x20. Hardware telemetry proved LR is still correct
         -- through the final read but BX then uses opcode value 0xe1510000.
         -- Thumb target: BX LR followed by a NOP. This must return to the
         -- ARM instruction immediately after BLX-immediate at 0x00000004.
         when x"FFF83A9C" => ext_rdata <= x"46C04770";
         -- Minimal architectural IRQ return. Test both vector bases because
         -- this focused test does not otherwise program CP15 V.
         when x"00000018" | x"FFFF0018" => ext_rdata <= x"E25EF004";
         when others => ext_rdata <= x"E1A00000";
       end case;
      end if;
   end process;

   -- Model the multi-cycle mailbox completion that exposed the hardware-only
   -- failure. Immediate combinational completion hides stale pipeline/control
   -- state across the BIOS helper's final STRH and BX.
   process(clk)
   begin
      if rising_edge(clk) then
         ext_done <= '0';
         if reset = '1' then
            responder_state <= RESP_IDLE;
            wait_count <= 0;
         else
            case responder_state is
               when RESP_IDLE =>
                  if ext_ena = '1' then
                     request_addr <= ext_addr;
                     request_rnw <= ext_rnw;
                     wait_count <= 3;
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
               when RESP_RELEASE =>
                  if ext_ena = '0' then responder_state <= RESP_IDLE; end if;
            end case;
         end if;
      end if;
   end process;

   router : entity work.nds_dual_cpu_bus
      port map (
         clk => clk, reset => reset,
         arm9_addr => addr, arm9_rnw => rnw, arm9_ena => ena,
         arm9_acc => acc, arm9_wdata => wdata,
         arm9_debug_pc => debug_pc, arm9_rdata => rdata,
         arm9_done => bus_done,
         arm7_addr => arm7_addr, arm7_rnw => '1', arm7_ena => arm7_ena,
         arm7_acc => "10", arm7_wdata => (others => '0'),
         arm7_debug_pc => (others => '0'),
         arm7_rdata => arm7_rdata, arm7_done => arm7_done,
         ext_addr => ext_addr, ext_rnw => ext_rnw, ext_ena => ext_ena,
         ext_acc => ext_acc, ext_wdata => ext_wdata,
         ext_cpu_is_arm9 => ext_cpu9, ext_debug_pc => open,
         ext_rdata => ext_rdata,
         ext_done => ext_done
      );

   -- Keep ARM7 competing for the shared port, as it does in the hardware
   -- failure. Its reads are irrelevant; only the grant interleaving matters.
   process
   begin
      wait until reset = '0';
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
         cpu_IRP => irq, new_halt => '0', clear_halt => '0',
         DISPSTAT_debug => (others => '0'), debug_fifocount => 0,
         timerdebug0 => (others => '0'), timerdebug1 => (others => '0'),
         timerdebug2 => (others => '0'), timerdebug3 => (others => '0'),
         debug_cpu_pc => debug_pc, debug_cpu_execute_pc => open,
         debug_cpu_mixed => open,
         arm9_dtcm_region => open, arm9_dtcm_enable => open
      );

   process(clk)
   begin
      if rising_edge(clk) and ext_done = '1' and ext_cpu9 = '1' and
         request_rnw = '1' then
         if request_addr = x"00000008" then saw_blx_fetch <= '1'; end if;
         if request_addr = x"00000018" or
            request_addr = x"FFFF0018" then
            saw_irq_vector <= '1';
         end if;
         if request_addr = x"FFF83A9C" then saw_target <= '1'; end if;
         if saw_target = '1' and request_addr = x"0000000C" then
            saw_return <= '1';
         end if;
      end if;
   end process;

   process
   begin
      reset <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';
      wait until saw_blx_fetch = '1' for 5 us;
      assert saw_blx_fetch = '1'
         report "ARM9 did not fetch the exact BLX-immediate opcode"
         severity failure;
      for cycle in 1 to irq_delay_cycles loop
         wait until rising_edge(clk);
      end loop;
      irq <= '1';
      wait until saw_irq_vector = '1' for 5 us;
      irq <= '0';
      wait for 10 us;
      assert saw_irq_vector = '1'
         report "ARM9 did not take the interleaved IRQ" severity failure;
      assert saw_target = '1'
         report "ARM9 BLX-immediate did not reach its Thumb target" severity failure;
      assert saw_return = '1'
         report "ARM9 BLX-immediate/BX did not preserve the link return address"
         severity failure;
      report "PASS: ARM9 BLX-immediate link returns through Thumb BX LR" severity note;
      stop;
      wait;
   end process;
end architecture;
