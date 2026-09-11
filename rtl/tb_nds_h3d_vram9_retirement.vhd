-- Integration regression: production DMA + event gate + exact console mux.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

entity tb_nds_h3d_vram9_retirement is
   generic (CASE_ID : natural := 0; STALL_SINK : boolean := false; LOCAL_ONLY : boolean := false; ENGINE_B : boolean := false);
end;
architecture sim of tb_nds_h3d_vram9_retirement is
   signal clk, reset : std_logic := '0';
   alias clk1x : std_logic is clk;
   alias reset_boot : std_logic is reset;
   signal regs_bus : proc_bus_gb_type :=
      (Din => (others => '0'), Adr => (others => '0'), rnw => '1',
       ena => '0', acc => ACCESS_32BIT, bEna => "1111", rst => '0');
   signal dma_on, dma_bus_on : std_logic;
   signal dma_state : std_logic_vector(3 downto 0);
   signal mb_ena, mb_rnw, mb_done : std_logic := '0';
   signal mb_adr, mb_dout, mb_din : std_logic_vector(31 downto 0) := (others => '0');
   signal dma_vr_ena, dma_vr_rnw, dma_vr_wpost, dma_vram_write_valid : std_logic;
   signal dma_vr_addr : unsigned(23 downto 2);
   signal dma_vr_be : std_logic_vector(3 downto 0);
   signal dma_vr_din : std_logic_vector(31 downto 0);
   signal dma_vr_wok_safe : std_logic;
   signal vram9_ena : std_logic := '0';
   signal vram9_rnw : std_logic := '1';
   signal vram9_addr : unsigned(23 downto 2) := (others => '0');
   signal vram9_be : std_logic_vector(3 downto 0) := "1111";
   signal vram9_din : std_logic_vector(31 downto 0) := (others => '0');
   signal vr9_src_ena, vr9_ena, vr9_rnw, vr9_wpost, vr9_welig, vr9_wok : std_logic;
   signal vr9_addr : unsigned(23 downto 2);
   signal vr9_be : std_logic_vector(3 downto 0);
   signal vr9_din : std_logic_vector(31 downto 0);
   signal h3d_service_ready : std_logic := '1';
   signal h3d_engine_b_enable : std_logic;
   signal h3d_vram9_unposted_pending : std_logic := '0';
   signal h3d_vram9_source_address, h3d_vram9_source_data : std_logic_vector(31 downto 0);
   signal h3d_vram9_source_be : std_logic_vector(3 downto 0);
   signal h3d_vram9_source_access : std_logic_vector(1 downto 0);
   signal h3d_vram9_needed_by_h3d, h3d_vram9_source_valid, h3d_vram9_source_ready : std_logic;
   signal h3d_vram9_issue, event_valid : std_logic;
   signal event_ready : std_logic := '1';
   signal h3d_vram9_write_address, h3d_vram9_write_data : std_logic_vector(31 downto 0);
   signal h3d_vram9_write_byte_enable : std_logic_vector(3 downto 0);
   signal local_writes, arm_writes : natural := 0;
   signal local_reads : natural := 0;
   signal local_done : std_logic := '0';
   signal local_dout : std_logic_vector(31 downto 0) := (others => '0');
   signal cycle : natural := 0;
   function source_address return natural is begin
      if CASE_ID = 1 then return 16#06020000#; else return 16#02000000#; end if;
   end;
   constant SOURCE_BASE : natural := source_address;
   function destination_address return natural is begin
      if LOCAL_ONLY then return 16#06000000#; else return 16#06800000#; end if;
   end;
   constant DEST_BASE : natural := destination_address;
   function h3d_access_from_be(be : std_logic_vector(3 downto 0)) return std_logic_vector is
   begin
      if be = "1111" then return "10"; else return "01"; end if;
   end;
begin
   clk <= not clk after 5 ns;
   h3d_engine_b_enable <= '1' when ENGINE_B else '0';
   dma : entity work.nds_dma9 port map (
      clk => clk, reset => reset, gb_bus => regs_bus, wired_out => open, wired_done => open,
      trig_vblank => '0', trig_hblank => '0', trig_card => '0', cpu_bus_idle => '1',
      dma_on => dma_on, dma_bus_on => dma_bus_on, dbg_state => dma_state,
      mb_ena => mb_ena, mb_rnw => mb_rnw, mb_adr => mb_adr, mb_acc => open,
      mb_lowbits => open, mb_dout => mb_dout, mb_din => mb_din, mb_done => mb_done,
      io_fast_ena => open, io_fast_rnw => open, io_fast_adr => open, io_fast_acc => open,
      io_fast_be => open, io_fast_dout => open, io_fast_din => (others => '0'),
      vram_fast_ena => dma_vr_ena, vram_fast_rnw => dma_vr_rnw,
      vram_fast_addr => dma_vr_addr, vram_fast_be => dma_vr_be, vram_fast_din => dma_vr_din,
      vram_fast_dout => local_dout, vram_fast_done => local_done,
      vram_fast_wpost => dma_vr_wpost, vram_fast_welig => vr9_welig,
      vram_fast_wok => dma_vr_wok_safe, vram_write_valid => dma_vram_write_valid,
      irq_dma => open);
   gate : entity work.nds_h3d_console_event_gate port map (
      clk => clk, reset => reset, service_ready => h3d_service_ready,
      timestamp => open, current_frame => open, source_fault => open,
      gpu_source_valid => '0', gpu_source_is_cpu => '1', gpu_source_address => (others => '0'),
      gpu_source_access => "10", gpu_source_be => "1111", gpu_source_data => (others => '0'),
      gpu_source_ready => open, gpu_cpu_complete => open, gpu_event_valid => open,
      gpu_event_ready => '1', gpu_event_address => open, gpu_event_access => open,
      gpu_event_be => open, gpu_event_data => open, gpu_event_scanline => open,
      gpu_event_timestamp => open,
      vram9_source_valid => h3d_vram9_source_valid, vram9_source_address => h3d_vram9_source_address,
      vram9_source_access => h3d_vram9_source_access, vram9_source_be => h3d_vram9_source_be,
      vram9_source_data => h3d_vram9_source_data, vram9_source_ready => h3d_vram9_source_ready,
      vram9_issue => h3d_vram9_issue, vram9_event_valid => event_valid,
      vram9_event_ready => event_ready, vram9_event_address => h3d_vram9_write_address,
      vram9_event_data => h3d_vram9_write_data, vram9_event_be => h3d_vram9_write_byte_enable,
      vram9_event_access => open, vram9_event_scanline => open, vram9_event_timestamp => open,
      vram7_source_valid => '0', vram7_source_address => (others => '0'), vram7_source_access => "10",
      vram7_source_be => "1111", vram7_source_data => (others => '0'), vram7_source_ready => open,
      vram7_issue => open, vram7_event_valid => open, vram7_event_ready => '1',
      vram7_event_address => open, vram7_event_access => open, vram7_event_be => open,
      vram7_event_data => open, vram7_event_scanline => open, vram7_event_timestamp => open,
      hblank_pulse => '0', hblank_line => (others => '0'), hblank_event_valid => open,
      hblank_event_ready => '1', hblank_event_line => open, hblank_event_frame => open,
      hblank_event_timestamp => open, frame_pulse => '0', frame_event_valid => open,
      frame_event_ready => '1', frame_event_number => open, frame_event_timestamp => open,
      frame_pending_level => open);

   -- The runner inserts these assignments verbatim from the production top.
   -- @PRODUCTION_VRAM9_MUX@

   -- Single A..D bank with an always-available posted-write slot. This is the
   -- documented nds_vram credit rule, not a second implementation of its RAM.
   vr9_welig <= vr9_wpost and not vr9_rnw when CASE_ID /= 3 else '0';
   vr9_wok <= vr9_welig when cycle mod 13 < 9 else '0';
   event_ready <= '1' when not STALL_SINK or cycle mod 43 < 8 else '0';
   h3d_service_ready <= '0' when CASE_ID = 4 else '1';
   memory : process(clk) begin
      if rising_edge(clk) then
         cycle <= cycle + 1;
         mb_done <= mb_ena;
         if mb_ena = '1' then mb_din <= mb_adr xor x"A5A50000"; end if;
         local_done <= '0';
         if reset = '0' then
            if vr9_ena = '1' then
               if vr9_rnw = '0' then
                  assert vr9_addr = to_unsigned((DEST_BASE mod 16#1000000#) / 4 + local_writes, 22)
                     report "local write address/order mismatch" severity failure;
                  if CASE_ID = 2 then
                     assert vr9_din = std_logic_vector(to_unsigned(16#0EAD0000# + local_writes, 32))
                        report "CPU held payload changed" severity failure;
                  else
                     assert vr9_din = (std_logic_vector(to_unsigned(SOURCE_BASE + local_writes * 4, 32)) xor x"A5A50000")
                        report "local DMA write data mismatch" severity failure;
                  end if;
                  local_writes <= local_writes + 1;
                  if vr9_wok = '0' then local_done <= '1'; end if;
               else
                  local_reads <= local_reads + 1;
                  local_dout <= (x"06" & std_logic_vector(vr9_addr) & "00") xor x"A5A50000";
                  local_done <= '1';
               end if;
            end if;
            if event_valid = '1' and event_ready = '1' then
               arm_writes <= arm_writes + 1;
               assert h3d_vram9_write_address = std_logic_vector(to_unsigned(DEST_BASE + arm_writes*4, 32))
                  report "ARM event address/order mismatch" severity failure;
               assert local_writes > arm_writes report "HPS event has no preceding local write" severity failure;
               if CASE_ID = 2 then
                  assert h3d_vram9_write_data = std_logic_vector(to_unsigned(16#0EAD0000# + arm_writes, 32))
                     report "HPS CPU data mismatch" severity failure;
               else
                  assert h3d_vram9_write_data = (std_logic_vector(to_unsigned(SOURCE_BASE + arm_writes*4, 32)) xor x"A5A50000")
                     report "HPS DMA data mismatch" severity failure;
               end if;
            end if;
         end if;
      end if;
   end process;
   stimulus : process
      procedure regwrite(address, data : std_logic_vector(31 downto 0)) is begin
         wait until falling_edge(clk);
         regs_bus.Adr <= address(27 downto 0); regs_bus.Din <= data; regs_bus.rnw <= '0'; regs_bus.ena <= '1';
         wait until falling_edge(clk); regs_bus.ena <= '0';
      end;
   begin
      reset <= '1'; wait for 30 ns; wait until falling_edge(clk); reset <= '0';
      if CASE_ID = 2 then
         for i in 0 to 15 loop
            wait until falling_edge(clk);
            vram9_addr <= to_unsigned((DEST_BASE mod 16#1000000#) / 4 + i, 22);
            vram9_din <= std_logic_vector(to_unsigned(16#0EAD0000# + i, 32));
            vram9_rnw <= '0'; vram9_ena <= '1';
            wait until falling_edge(clk); vram9_ena <= '0';
            while local_done /= '1' loop wait until falling_edge(clk); end loop;
         end loop;
      else
         regwrite(x"000000B0", std_logic_vector(to_unsigned(SOURCE_BASE, 32)));
         regwrite(x"000000B4", std_logic_vector(to_unsigned(DEST_BASE, 32)));
         regwrite(x"000000B8", x"84000010");
      end if;
      wait for 10000 ns;
      report "VRAM receipt case=" & integer'image(CASE_ID) & " stall=" & boolean'image(STALL_SINK) &
         " engine_b=" & boolean'image(ENGINE_B) & " local_only=" & boolean'image(LOCAL_ONLY) & " ARM=" & integer'image(arm_writes) & " FPGA=" & integer'image(local_writes) &
         " reads=" & integer'image(local_reads);
      assert (((CASE_ID = 4 or (LOCAL_ONLY and not ENGINE_B)) and arm_writes = 0) or (CASE_ID /= 4 and (not LOCAL_ONLY or ENGINE_B) and arm_writes = 16)) and local_writes = 16
         report "FPGA local VRAM did not receive exactly the same writes as HPS" severity failure;
      assert CASE_ID /= 1 or local_reads = 16 report "read following posted write was lost" severity failure;
      report "PASS: local VRAM and HPS have matching ordered write receipts";
      stop; wait;
   end process;
   timeout : process begin wait for 30 us; assert false report "test timed out" severity failure; end process;
end;
