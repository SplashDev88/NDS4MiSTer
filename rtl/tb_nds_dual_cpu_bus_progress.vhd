library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_nds_dual_cpu_bus_progress is
end entity;

architecture sim of tb_nds_dual_cpu_bus_progress is
   type responder_state_t is (RESP_IDLE, RESP_ACK, RESP_WAIT_RELEASE);
   signal clk, reset, descriptor_valid, boot_ready : std_logic := '0';
   signal addr9, wdata9, rdata9, addr7, wdata7, rdata7 :
      std_logic_vector(31 downto 0);
   signal rnw9, ena9, done9, rnw7, ena7, done7 : std_logic;
   signal acc9, acc7 : std_logic_vector(1 downto 0);
   signal cycles9, cycles7 : std_logic_vector(7 downto 0);
   signal cycles_valid9, cycles_valid7 : std_logic;
   signal debug_pc9, debug_pc7 : std_logic_vector(31 downto 0);
   signal ext_addr, ext_wdata, ext_rdata : std_logic_vector(31 downto 0);
   signal ext_rnw, ext_ena, ext_owner9 : std_logic;
   signal ext_done : std_logic := '0';
   signal responder_state : responder_state_t := RESP_IDLE;
   signal ext_acc : std_logic_vector(1 downto 0);
   signal completed9, completed7, cycle_events9, cycle_events7 : natural := 0;
   signal retired_cycles9, retired_cycles7 : natural := 0;
   signal delivered9, delivered7 : natural := 0;
   signal halt9, halt7 : std_logic := '0';
   signal global_step_enable, manual_pause : std_logic := '0';
begin
   clk <= not clk after 5 ns;
   -- Model the r114 top-level contract: implementation latency on the shared
   -- external service pauses both CPUs, including the completion/release edge.
   -- manual_pause separately exercises an extended idle mailbox hold.
   global_step_enable <= not ext_ena and not manual_pause;

   cpus : entity work.nds_dual_cpu_core
      port map (
         clk => clk, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => x"02004800", arm7_entry => x"02380000",
         arm9_current_sp => x"03002F7C", arm9_irq_sp => x"03003F80",
         arm9_saved_sp => x"03003FC0", arm7_current_sp => x"0380FD80",
         arm7_irq_sp => x"0380FF80", arm7_saved_sp => x"0380FFC0",
         initial_cpsr => x"000000D3", boot_ready => boot_ready,
         global_step_enable => global_step_enable,
         arm9_cycles => cycles9, arm9_cycles_valid => cycles_valid9,
         arm7_cycles => cycles7, arm7_cycles_valid => cycles_valid7,
         arm9_debug_pc => debug_pc9, arm7_debug_pc => debug_pc7,
         arm9_diag_word => open,
         arm9_dtcm_region => open, arm9_dtcm_enable => open,
         arm9_addr => addr9, arm9_rnw => rnw9, arm9_ena => ena9,
         arm9_acc => acc9, arm9_wdata => wdata9, arm9_rdata => rdata9,
         arm9_done => done9, arm9_halt => halt9,
         arm7_addr => addr7, arm7_rnw => rnw7, arm7_ena => ena7,
         arm7_acc => acc7, arm7_wdata => wdata7, arm7_rdata => rdata7,
         arm7_done => done7, arm7_halt => halt7
      );

   shared_bus : entity work.nds_dual_cpu_bus
      port map (
         clk => clk, reset => reset,
         arm9_addr => addr9, arm9_rnw => rnw9, arm9_ena => ena9,
         arm9_acc => acc9, arm9_wdata => wdata9,
         arm9_debug_pc => debug_pc9,
         arm9_rdata => rdata9, arm9_done => done9,
         arm7_addr => addr7, arm7_rnw => rnw7, arm7_ena => ena7,
         arm7_acc => acc7, arm7_wdata => wdata7,
         arm7_debug_pc => debug_pc7,
         arm7_rdata => rdata7, arm7_done => done7,
         ext_addr => ext_addr, ext_rnw => ext_rnw, ext_ena => ext_ena,
         ext_acc => ext_acc, ext_wdata => ext_wdata,
         ext_cpu_is_arm9 => ext_owner9,
         ext_debug_pc => open,
         ext_rdata => ext_rdata, ext_done => ext_done
      );

   -- A one-cycle-latency shared memory containing an ARM branch-to-self at
   -- both entry points. Both CPUs must repeatedly win the same external port;
   -- an unfair or stuck grant leaves one completion counter at zero.
   ext_rdata <= x"EAFFFFFE";
   process(clk)
   begin
      if rising_edge(clk) then
         ext_done <= '0';
         case responder_state is
            when RESP_IDLE =>
               if ext_ena = '1' then responder_state <= RESP_ACK; end if;
            when RESP_ACK =>
               ext_done <= '1';
               responder_state <= RESP_WAIT_RELEASE;
            when RESP_WAIT_RELEASE =>
               if ext_ena = '0' then responder_state <= RESP_IDLE; end if;
         end case;
         if reset = '1' then
            responder_state <= RESP_IDLE;
            ext_done <= '0';
            completed9 <= 0;
            completed7 <= 0;
            cycle_events9 <= 0;
            cycle_events7 <= 0;
            retired_cycles9 <= 0;
            retired_cycles7 <= 0;
            delivered9 <= 0;
            delivered7 <= 0;
         else
            if ext_done = '1' then
               assert ext_rnw = '1'
                  report "branch-loop memory unexpectedly written"
                  severity failure;
               if ext_owner9 = '1' then
                  completed9 <= completed9 + 1;
               else
                  completed7 <= completed7 + 1;
               end if;
            end if;
            if cycles_valid9 = '1' then
               cycle_events9 <= cycle_events9 + 1;
               retired_cycles9 <= retired_cycles9 +
                  to_integer(unsigned(cycles9));
            end if;
            if cycles_valid7 = '1' then
               cycle_events7 <= cycle_events7 + 1;
               retired_cycles7 <= retired_cycles7 +
                  to_integer(unsigned(cycles7));
            end if;
            if done9 = '1' then delivered9 <= delivered9 + 1; end if;
            if done7 = '1' then delivered7 <= delivered7 + 1; end if;
         end if;
      end if;
   end process;

   process
      variable before_halt7, during_halt7 : natural;
      variable paused_cycles9, paused_cycles7 : natural;
      variable paused_completed9, paused_completed7 : natural;
   begin
      reset <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';
      descriptor_valid <= '1';
      wait for 5 us;
      before_halt7 := completed7;
      halt7 <= '1';
      wait for 2 us;
      during_halt7 := completed7;
      assert during_halt7 <= before_halt7 + 2
         report "ARM7 continued fetching after authoritative halt asserted"
         severity failure;
      halt7 <= '0';
      wait for 5 us;
      assert completed7 > during_halt7 + 8
         report "ARM7 did not resume when authoritative halt deasserted"
         severity failure;
      -- Model a long HPS mailbox service. Once the current pipelines settle,
      -- neither CPU may retire cycles or continue branch-loop fetches while
      -- the shared pause is active.
      manual_pause <= '1';
      wait for 1 us;
      paused_cycles9 := cycle_events9;
      paused_cycles7 := cycle_events7;
      paused_completed9 := completed9;
      paused_completed7 := completed7;
      wait for 2 us;
      assert cycle_events9 = paused_cycles9 and
             cycle_events7 = paused_cycles7
         report "a CPU retired emulated cycles during shared oracle pause"
         severity failure;
      assert completed9 = paused_completed9 and
             completed7 = paused_completed7
         report "a CPU kept fetching during shared oracle pause"
         severity failure;
      manual_pause <= '0';
      wait for 3 us;
      assert completed9 > paused_completed9 and
             completed7 > paused_completed7
         report "dual CPUs did not resume after shared oracle pause"
         severity failure;
      -- Do not stop as soon as the responder has acknowledged requests: a CPU
      -- may still need several pipeline fetches before retiring its first
      -- instruction and publishing cycle accounting.
      wait for 8 us;
      report "dual CPU progress: arm9 completions=" & natural'image(completed9) &
             " arm7 completions=" & natural'image(completed7) &
             " arm9 cycle events=" & natural'image(cycle_events9) &
             " arm7 cycle events=" & natural'image(cycle_events7) &
             " arm9 cycles=" & natural'image(retired_cycles9) &
             " arm7 cycles=" & natural'image(retired_cycles7) &
             " arm9 done pulses=" & natural'image(delivered9) &
             " arm7 done pulses=" & natural'image(delivered7) &
             " arm9 pc=" & to_hstring(debug_pc9) &
             " arm7 pc=" & to_hstring(debug_pc7) &
             " arm9 ena/addr=" & std_logic'image(ena9) & "/" & to_hstring(addr9) &
             " arm7 ena/addr=" & std_logic'image(ena7) & "/" & to_hstring(addr7)
         severity note;
      assert completed9 >= 16 and completed7 >= 16
         report "shared dual-CPU bus starved a boot CPU"
         severity failure;
      assert cycle_events9 > 0 and cycle_events7 > 0
         report "one boot CPU emitted no cycle accounting"
         severity failure;
      -- ARM9 runs at twice the ARM7 clock in the NDS, so it must retire
      -- substantially more CPU events. Its exported cycle count is divided
      -- by two into the common 33.5-MHz DS timebase, where the two cumulative
      -- timestamps must remain aligned.
      assert cycle_events9 * 3 > cycle_events7 * 5 and
             retired_cycles9 + 16 >= retired_cycles7 and
             retired_cycles9 <= retired_cycles7 + 16
         report "dual CPUs do not preserve the NDS 2:1 clock relationship"
         severity failure;
      assert (debug_pc9 xor x"40000000") = x"02004800"
         report "ARM9 execute-PC XOR telemetry did not decode to its loop"
         severity failure;
      assert (debug_pc7 xor x"80000000") = x"02380000"
         report "ARM7 execute-PC XOR telemetry did not decode to its loop"
         severity failure;
      report "PASS: both boot CPUs make sustained progress through one shared bus"
         severity note;
      stop;
      wait;
   end process;
end architecture;
