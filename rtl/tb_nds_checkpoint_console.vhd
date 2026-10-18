-- Authored dual-CPU program through the actual console and HLE loader.
-- Behavioral external memory/host sink only: this is not a renderer/host
-- checkpoint implementation and does not establish persistent game resume.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pexport.all;
use work.pProc_bus_gba.all;
use work.checkpoint_fixture_rom.all;
entity tb_nds_checkpoint_console is
   generic(LATENCY : positive := 2; ARM9_HALF_NS : positive := 20);
end;
architecture sim of tb_nds_checkpoint_console is
   signal clk1x : std_logic := '0';
   signal clk2x : std_logic := '0';
   signal clkMem : std_logic := '0';
   signal clkMemIndex : unsigned(1 downto 0) := (others => '0');
   signal reset : std_logic := '1';
   signal boot_done : std_logic := '0';
   signal boot_error : std_logic := '0';
   signal card_ena : std_logic := '0';
   signal card_addr : std_logic_vector(28 downto 2) := (others => '0');
   signal card_din : std_logic_vector(31 downto 0) := (others => '0');
   signal card_done : std_logic := '0';
   signal fw_req : std_logic := '0';
   signal fw_wr : std_logic := '0';
   signal sdram_ena : std_logic := '0';
   signal sdram_rnw : std_logic := '0';
   signal sdram_Adr : std_logic_vector(26 downto 0) := (others => '0');
   signal sdram_Din : std_logic_vector(31 downto 0) := (others => '0');
   signal sdram_be : std_logic_vector(3 downto 0) := (others => '0');
   signal sdram_Dout : std_logic_vector(31 downto 0) := (others => '0');
   signal sdram_done32 : std_logic := '0';
   signal sdram_Dout_hi : std_logic_vector(31 downto 0) := (others => '0');
   signal sdram_done64 : std_logic := '0';
   signal vsrv_req : std_logic := '0';
   signal vsrv_rnw : std_logic := '0';
   signal vsrv_bank : std_logic_vector(1 downto 0) := (others => '0');
   signal vsrv_addr : unsigned(16 downto 2) := (others => '0');
   signal vsrv_be : std_logic_vector(3 downto 0) := (others => '0');
   signal vsrv_din : std_logic_vector(31 downto 0) := (others => '0');
   signal vsrv_dout : std_logic_vector(31 downto 0) := (others => '0');
   signal vsrv_done : std_logic := '0';
   signal vsrv_dout_hi : std_logic_vector(31 downto 0) := (others => '0');
   signal vsrv_seq : std_logic := '0';
   signal vsrv_wide : std_logic := '0';
   signal vsrv_din_hi : std_logic_vector(31 downto 0) := (others => '0');
   signal vsrv_be_hi : std_logic_vector(3 downto 0) := (others => '0');
   signal vrsrv_req : std_logic := '0';
   signal math_request : std_logic := '0';
   signal math_address : std_logic_vector(31 downto 0) := (others => '0');
   signal h3d_timestamp : std_logic_vector(63 downto 0) := (others => '0');
   signal h3d_source_fault : std_logic := '0';
   signal h3d_gpu_write_valid : std_logic := '0';
   signal h3d_vram9_write_valid : std_logic := '0';
   signal h3d_vram7_write_valid : std_logic := '0';
   signal h3d_hblank_valid : std_logic := '0';
   signal h3d_frame_valid : std_logic := '0';
   signal dbg_cpu_err9 : std_logic := '0';
   signal dbg_cpu_err7 : std_logic := '0';
   signal dbg_pc9 : std_logic_vector(31 downto 0) := (others => '0');
   signal dbg_pc7 : std_logic_vector(31 downto 0) := (others => '0');
   signal dbg_vfy_bad : std_logic_vector(17 downto 0) := (others => '0');
   signal dbg_vfy_addr : std_logic_vector(31 downto 0) := (others => '0');
   signal checkpoint_request : std_logic := '0';
   signal checkpoint_keepalive : std_logic := '0';
   signal checkpoint_keepalive_epoch : unsigned(31 downto 0) := (others => '0');
   signal checkpoint_ready : std_logic := '0';
   signal checkpoint_busy : std_logic := '0';
   signal checkpoint_pair_paused : std_logic := '0';
   signal checkpoint_timed_out : std_logic := '0';
   signal checkpoint_release_stalled : std_logic := '0';
   signal checkpoint_lease_expired : std_logic := '0';
   signal checkpoint_epoch : unsigned(31 downto 0) := (others => '0');
   signal checkpoint_dma_stopped : std_logic := '0';
   signal checkpoint_arm9_memory_idle : std_logic := '0';
   signal checkpoint_sound_stopped : std_logic := '0';
   signal checkpoint_timing_stopped : std_logic := '0';
   signal checkpoint_mainram_idle : std_logic := '0';
   signal checkpoint_vram_idle : std_logic := '0';
   signal checkpoint_arm7_memory_idle : std_logic := '0';
   signal checkpoint_shared_wram_idle : std_logic := '0';
   signal checkpoint_irq_idle : std_logic := '0';
   signal checkpoint_ipc_idle : std_logic := '0';
   signal checkpoint_card_stopped : std_logic := '0';
   signal checkpoint_spi_stopped : std_logic := '0';
   signal checkpoint_inputs_held : std_logic := '0';
   signal checkpoint_rtc_ready : std_logic := '0';
   signal checkpoint_external_seen : std_logic := '0';
   signal checkpoint_external_paused : std_logic := '0';
   signal checkpoint_owner_request : std_logic := '0';
   signal checkpoint_owners_paused : std_logic := '0';
   signal checkpoint_local_idle : std_logic := '0';
   signal checkpoint_graphics_stopped : std_logic := '0';
   signal checkpoint_read_strobe : std_logic := '0';
   signal checkpoint_read_cpu : std_logic := '0';
   signal checkpoint_read_address : std_logic_vector(7 downto 0) := (others => '0');
   signal checkpoint_read_epoch : unsigned(31 downto 0) := (others => '0');
   signal checkpoint_read_ready : std_logic := '0';
   signal checkpoint_read_done : std_logic := '0';
   signal checkpoint_read_error : std_logic := '0';
   signal checkpoint_read_data : std_logic_vector(31 downto 0) := (others => '0');
   signal checkpoint_result_epoch : unsigned(31 downto 0) := (others => '0');
   signal sound_left, sound_right : std_logic_vector(15 downto 0);
   signal sound_samples, sound_varied, sound_fetches, dma9_writes, dma7_writes : natural := 0;
   signal sound_inflight, dma9_active, dma7_active : std_logic := '0';
   signal sound_loops_complete, sound_memory_pending : boolean := false;
   signal hold_sound_response : std_logic := '0';
   signal phase_index : natural range 0 to 2 := 2;
   signal count9, count7, physical_writes : natural := 0;
   signal sink_ready, allow_host, respond : std_logic := '1';
   signal delivery : std_logic_vector(2 downto 0) := "000";
   signal memory_pending : boolean := false;

begin
   clk1x <= not clk1x after 30 ns;
   clk2x <= not clk2x after ARM9_HALF_NS * 1 ns;
   clkMem <= not clkMem after 10 ns;
   clkMemIndex <= to_unsigned(phase_index,2);
   process(clkMem) begin if rising_edge(clkMem) then phase_index <= (phase_index+1) mod 3; end if; end process;
   dut : entity work.nds_nitro_console_top
      generic map(is_simu => '1', Softmap_NDS_MAINRAM_ADDR => 0, GPU2D_A_ENABLE => 0, GPU2D_B_ENABLE => 0,
         HOST_SAVE_PROFILE => 1, H3D_MATCHED_DISPLAY_TEST => 1, H3D_COMPRESS_HBLANK => true,
         SOUND_ENABLE => 1, DEBUG_ENABLE => 0, CHECKPOINT_CPU_ENABLE => true,
         CHECKPOINT_OWNERS_ENABLE => true, CHECKPOINT_TIMEOUT_CYCLES => 4096, CHECKPOINT_LEASE_CYCLES => 20000)
      port map(
      clk1x => clk1x,
      clk2x => clk2x,
      clkMem => clkMem,
      clkMemIndex => clkMemIndex,
      reset => reset,
      nds_on => '1',
      direct_boot => '1',
      cart_present => '1',
      host_save_valid => '1',
      host_save_code => x"54534554",
      profile_addr => open,
      rtc_datetime => open,
      rtc_date_written => open,
      KeyA => '0',
      KeyB => '0',
      KeySelect => '0',
      KeyStart => '0',
      KeyRight => '0',
      KeyLeft => '0',
      KeyUp => '0',
      KeyDown => '0',
      KeyR => '0',
      KeyL => '0',
      KeyX => '0',
      KeyY => '0',
      lid_closed => '0',
      touch_active => '0',
      touch_x => (others => '0'),
      touch_y => (others => '0'),
      boot_done => boot_done,
      boot_error => boot_error,
      card_ena => card_ena,
      card_addr => card_addr,
      card_din => card_din,
      card_done => card_done,
      backup_addr => open,
      backup_write_data => open,
      backup_write_enable => open,
      backup_read_data => (others => '0'),
      backup_write_toggle => open,
      backup_is_64k => open,
      backup_save_type => open,
      backup_profile_valid => open,
      backup_access_active => open,
      backup_cache_ready => '1',
      backup_run_ready => '1',
      fw_addr => open,
      fw_req => fw_req,
      fw_done => '0',
      fw_data => (others => '0'),
      fw_wr => fw_wr,
      fw_wlane => open,
      fw_wdata => open,
      fw_release => open,
      mainram_allow => '1',
      mainram_active => open,
      mainram_busy => open,
      sdram_ena => sdram_ena,
      sdram_rnw => sdram_rnw,
      sdram_Adr => sdram_Adr,
      sdram_Din => sdram_Din,
      sdram_be => sdram_be,
      sdram_Dout => sdram_Dout,
      sdram_done32 => sdram_done32,
      sdram_Dout_hi => sdram_Dout_hi,
      sdram_done64 => sdram_done64,
      vsrv_req => vsrv_req,
      vsrv_rnw => vsrv_rnw,
      vsrv_bank => vsrv_bank,
      vsrv_addr => vsrv_addr,
      vsrv_be => vsrv_be,
      vsrv_din => vsrv_din,
      vsrv_dout => vsrv_dout,
      vsrv_done => vsrv_done,
      vsrv_dout_hi => vsrv_dout_hi,
      vsrv_seq => vsrv_seq,
      vsrv_wide => vsrv_wide,
      vsrv_din_hi => vsrv_din_hi,
      vsrv_be_hi => vsrv_be_hi,
      vsrv_more => open,
      vrsrv_req => vrsrv_req,
      vrsrv_bank => open,
      vrsrv_addr => open,
      vrsrv_dout => (others => '0'),
      vrsrv_done => '0',
      math_request => math_request,
      math_address => math_address,
      math_rnw => open,
      math_access => open,
      math_write_data => open,
      h3d_line_request => open,
      h3d_line_request_y => open,
      h3d_merge_line_start => open,
      h3d_merge_line_end => open,
      h3d_merge_pixel_x => open,
      h3d_merge_pixel_y => open,
      h3d_service_ready => '1',
      h3d_readback_request => open,
      h3d_readback_id => open,
      h3d_readback_index => open,
      h3d_engine_b_enable => '1',
      h3d_gx_stack_ack => open,
      h3d_timestamp => h3d_timestamp,
      h3d_current_frame => open,
      h3d_source_fault => h3d_source_fault,
      h3d_source_fault_reason => open,
      h3d_gpu_write_valid => h3d_gpu_write_valid,
      h3d_gpu_write_ready => sink_ready,
      h3d_gpu_write_address => open,
      h3d_gpu_write_access => open,
      h3d_gpu_write_byte_enable => open,
      h3d_gpu_write_data => open,
      h3d_gpu_write_scanline => open,
      h3d_gpu_write_timestamp => open,
      h3d_vram9_write_valid => h3d_vram9_write_valid,
      h3d_vram9_write_ready => sink_ready,
      h3d_vram9_write_address => open,
      h3d_vram9_write_access => open,
      h3d_vram9_write_byte_enable => open,
      h3d_vram9_write_data => open,
      h3d_vram9_write_scanline => open,
      h3d_vram9_write_timestamp => open,
      h3d_vram7_write_valid => h3d_vram7_write_valid,
      h3d_vram7_write_ready => sink_ready,
      h3d_vram7_write_address => open,
      h3d_vram7_write_access => open,
      h3d_vram7_write_byte_enable => open,
      h3d_vram7_write_data => open,
      h3d_vram7_write_scanline => open,
      h3d_vram7_write_timestamp => open,
      h3d_lcd_phase_raw => open,
      h3d_lcd_line_raw => open,
      h3d_hblank_valid => h3d_hblank_valid,
      h3d_hblank_ready => sink_ready,
      h3d_hblank_line => open,
      h3d_hblank_frame => open,
      h3d_hblank_timestamp => open,
      h3d_frame_valid => h3d_frame_valid,
      h3d_frame_ready => sink_ready,
      h3d_frame_number => open,
      h3d_frame_timestamp => open,
      pixel_out_x => open,
      pixel_out_y => open,
      pixel_out_data => open,
      pixel_out_we => open,
      pixelb_out_x => open,
      pixelb_out_y => open,
      pixelb_out_data => open,
      pixelb_out_we => open,
      vblank_out => open,
      sound_diagnostic => open,
      sound_stream_diagnostic => open,
      sound_out_left => sound_left,
      sound_out_right => sound_right,
      dbg_export9_done => open,
      dbg_export9 => open,
      dbg_export7_done => open,
      dbg_export7 => open,
      dbg_line_drop => open,
      dbg_line_drop_a => open,
      dbg_line_drop_b => open,
      dbg_line_busy => open,
      dbg_bg1_scroll_triplet => open,
      dbg_query_sample_toggle => open,
      dbg_cpu_err9 => dbg_cpu_err9,
      dbg_cpu_err7 => dbg_cpu_err7,
      dbg_pc9 => dbg_pc9,
      dbg_pc7 => dbg_pc7,
      dbg_r0_9 => open,
      dbg_lr9 => open,
      dbg_cpsr9 => open,
      dbg_mem_probe => open,
      dbg_cpu9_addr => open,
      dbg_vfy_bad => dbg_vfy_bad,
      dbg_vfy_addr => dbg_vfy_addr,
      dbg_rsp_data => open,
      dbg_rsp_stb => open,
      dbg_hwstat => open,
      checkpoint_request => checkpoint_request,
      checkpoint_keepalive => checkpoint_keepalive,
      checkpoint_keepalive_epoch => checkpoint_keepalive_epoch,
      checkpoint_ready => checkpoint_ready,
      checkpoint_busy => checkpoint_busy,
      checkpoint_pair_paused => checkpoint_pair_paused,
      checkpoint_timed_out => checkpoint_timed_out,
      checkpoint_release_stalled => checkpoint_release_stalled,
      checkpoint_lease_expired => checkpoint_lease_expired,
      checkpoint_epoch => checkpoint_epoch,
      checkpoint_dma_stopped => checkpoint_dma_stopped,
      checkpoint_arm9_memory_idle => checkpoint_arm9_memory_idle,
      checkpoint_sound_stopped => checkpoint_sound_stopped,
      checkpoint_timing_stopped => checkpoint_timing_stopped,
      checkpoint_mainram_idle => checkpoint_mainram_idle,
      checkpoint_vram_idle => checkpoint_vram_idle,
      checkpoint_arm7_memory_idle => checkpoint_arm7_memory_idle,
      checkpoint_shared_wram_idle => checkpoint_shared_wram_idle,
      checkpoint_irq_idle => checkpoint_irq_idle,
      checkpoint_ipc_idle => checkpoint_ipc_idle,
      checkpoint_card_stopped => checkpoint_card_stopped,
      checkpoint_spi_stopped => checkpoint_spi_stopped,
      checkpoint_inputs_held => checkpoint_inputs_held,
      checkpoint_rtc_ready => checkpoint_rtc_ready,
      checkpoint_external_seen => checkpoint_external_seen,
      checkpoint_external_paused => checkpoint_external_paused,
      checkpoint_math_idle_2x => '1',
      checkpoint_owner_request => checkpoint_owner_request,
      checkpoint_owners_paused => checkpoint_owners_paused,
      checkpoint_local_idle => checkpoint_local_idle,
      checkpoint_graphics_stopped => checkpoint_graphics_stopped,
      checkpoint_rtc_datetime => open,
      checkpoint_rtc_subsecond => open,
      checkpoint_read_strobe => checkpoint_read_strobe,
      checkpoint_read_cpu => checkpoint_read_cpu,
      checkpoint_read_address => checkpoint_read_address,
      checkpoint_read_epoch => checkpoint_read_epoch,
      checkpoint_read_ready => checkpoint_read_ready,
      checkpoint_read_done => checkpoint_read_done,
      checkpoint_read_error => checkpoint_read_error,
      checkpoint_read_data => checkpoint_read_data,
      checkpoint_result_epoch => checkpoint_result_epoch);
   active_audio_check : if ACTIVE_DEVICES generate
      signal registers : proc_bus_gb_type;
      signal reset_sound, ref_request, ref_owner, ref_ena, ref_done, ref_valid, dut_valid : std_logic := '0';
      signal ref_address, ref_data : std_logic_vector(31 downto 0) := (others => '0');
      signal ref_left, ref_right : std_logic_vector(15 downto 0);
   begin
      observe : process(all)
         alias actual_bus is << signal .tb_nds_checkpoint_console.dut.io_bus7 : proc_bus_gb_type >>;
         alias actual_reset is << signal .tb_nds_checkpoint_console.dut.resetCpu : std_logic >>;
         alias actual_valid is << signal .tb_nds_checkpoint_console.dut.gsound.isound.sample_valid : std_logic >>;
         alias actual_own is << signal .tb_nds_checkpoint_console.dut.snd_bus_own : std_logic >>;
         alias actual_dma9 is << signal .tb_nds_checkpoint_console.dut.dma_bus_on : std_logic >>;
         alias actual_dma7 is << signal .tb_nds_checkpoint_console.dut.dma7_bus_on : std_logic >>;
      begin
         registers <= actual_bus; reset_sound <= actual_reset; dut_valid <= actual_valid;
         sound_inflight <= actual_own; dma9_active <= actual_dma9; dma7_active <= actual_dma7;
      end process;
      -- Independent uninterrupted SPU with the same observed configuration
      -- writes and authored source bytes. It never sees the checkpoint request
      -- or console bus grants. Compare sample sequence, not wall-clock phase.
      reference : entity work.nds_sound
         generic map(is_simu => '1')
         port map(clk => clk1x, ce => '1', reset => reset_sound, bus7 => registers,
            wired_out7 => open, wired_done7 => open, snd_bus_req => ref_request,
            snd_bus_ok => '1', snd_bus_own => ref_owner, mb_ena => ref_ena,
            mb_adr => ref_address, mb_din => ref_data, mb_done => ref_done,
            sample_l => ref_left, sample_r => ref_right, sample_valid => ref_valid,
            snd_enable => open, snd_active => open);
      reference_memory : process(clk1x)
         variable pending : boolean := false;
         variable delay, address : natural := 0;
      begin
         if rising_edge(clk1x) then
            ref_done <= '0';
            if reset_sound = '1' then pending := false;
            else
               if pending then
                  if delay > 0 then delay := delay-1;
                  else ref_data <= rom_word(address); ref_done <= '1'; pending := false; end if;
               end if;
               if ref_ena = '1' then
                  assert not pending report "reference SPU overlapped requests" severity failure;
                  assert unsigned(ref_address) >= x"02001400" and unsigned(ref_address) < x"02001700"
                     report "reference SPU used unexpected sample address" severity failure;
                  address := (to_integer(unsigned(ref_address))-16#02001000#+16#1000#)/4;
                  pending := true; delay := LATENCY;
               end if;
            end if;
         end if;
      end process;
      stream_check : process(clk1x)
         alias ena is << signal .tb_nds_checkpoint_console.dut.sndb7_ena : std_logic >>;
         alias adr is << signal .tb_nds_checkpoint_console.dut.sndb7_adr : std_logic_vector(31 downto 0) >>;
         alias own is << signal .tb_nds_checkpoint_console.dut.snd_bus_own : std_logic >>;
         alias req is << signal .tb_nds_checkpoint_console.dut.snd_bus_req : std_logic >>;
         type samples_t is array(0 to 8191) of std_logic_vector(31 downto 0);
         type counts_t is array(0 to 2) of natural;
         variable samples : samples_t;
         variable fetched : counts_t := (others => 0);
         variable produced, consumed, channel : natural := 0;
         variable previous : std_logic_vector(31 downto 0) := (others => '0');
      begin
         if rising_edge(clk1x) then
            if reset_sound = '1' then
               produced := 0; consumed := 0; fetched := (others => 0);
               sound_samples <= 0; sound_varied <= 0; sound_fetches <= 0; sound_loops_complete <= false; previous := (others => '0');
            else
               assert not (own = '1' and dma7_active = '1') report "connected SPU/DMA double grant" severity failure;
               if ref_valid = '1' then
                  assert produced < samples'length report "reference sample log overflow" severity failure;
                  samples(produced) := ref_left & ref_right; produced := produced+1;
               end if;
               if dut_valid = '1' then
                  assert consumed < produced report "paused SPU ran ahead of reference" severity failure;
                  assert (sound_left & sound_right) = samples(consumed)
                     report "connected resumed audio differs from reference at sample " & integer'image(consumed) &
                     " got=" & to_hstring(sound_left & sound_right) & " expected=" & to_hstring(samples(consumed)) severity failure;
                  if (sound_left & sound_right) /= previous then sound_varied <= sound_varied+1; end if;
                  previous := sound_left & sound_right; consumed := consumed+1; sound_samples <= consumed;
               end if;
               if ena = '1' then
                  assert own = '1' report "unowned connected SPU read" severity failure;
                  assert unsigned(adr) >= x"02001400" and unsigned(adr) < x"02001700"
                     report "connected SPU read outside authored source" severity failure;
                  channel := (to_integer(unsigned(adr))-16#02001400#)/256;
                  assert to_integer(unsigned(adr(7 downto 0))) = (fetched(channel) mod 64)*4
                     report "connected SPU fetch pointer skipped/repeated" severity failure;
                  fetched(channel) := fetched(channel)+1; sound_fetches <= sound_fetches+1;
                  sound_loops_complete <= fetched(0) > 64 and fetched(1) > 64 and fetched(2) > 64;
               end if;
               if checkpoint_pair_paused = '1' then
                  assert dut_valid = '0' and own = '0' and req = '0' and ena = '0'
                     report "captured console still has sound work" severity failure;
               end if;
            end if;
         end if;
      end process;
   end generate;
   -- The host fixture acknowledges delivered request independently of its
   -- ability to pause. It consumes records normally until local producers
   -- stop and their queues drain. No software state is modeled or serialized.
   process(clk1x) begin
      if rising_edge(clk1x) then
         delivery <= delivery(1 downto 0) & checkpoint_owner_request;
         checkpoint_external_seen <= delivery(2);
         checkpoint_external_paused <= delivery(2) and checkpoint_local_idle and allow_host;
         assert not (math_request = '1' and unsigned(math_address) >= x"04000280" and unsigned(math_address) < x"040002C0")
            report "fixture accessed unmodeled math unit" severity failure;
         assert fw_req = '0' and fw_wr = '0' and vrsrv_req = '0'
            report "fixture accessed unmodeled external owner" severity failure;
         assert h3d_source_fault = '0' report "graphics sink overflow" severity failure;
      end if;
   end process;
   cartridge : process(clk1x)
      variable pending : boolean := false;
      variable delay, a : natural := 0;
   begin
      if rising_edge(clk1x) then
         card_done <= '0';
         if pending then
            if delay > 0 then delay := delay-1;
            else card_din <= rom_word(a); card_done <= '1'; pending := false; end if;
         end if;
         if card_ena = '1' then
            assert not pending report "overlapping cartridge requests" severity failure;
            pending := true; a := to_integer(unsigned(card_addr)); delay := LATENCY;
         end if;
      end if;
   end process;
   main_memory : process(clkMem)
      type memory_t is array(0 to 1048575) of std_logic_vector(31 downto 0);
      variable memory : memory_t := (others => (others => '0'));
      variable pending, low_returned : boolean := false;
      variable delay, tail, a : natural := 0;
      variable rd : std_logic;
      variable value : std_logic_vector(31 downto 0);
      variable mask : std_logic_vector(3 downto 0);
   begin
      if rising_edge(clkMem) then
         sdram_done32 <= '0'; sdram_done64 <= '0';
         if pending then
            if not low_returned then
               if delay > 0 then delay := delay-1;
               elsif respond = '1' and not (hold_sound_response = '1' and
                  a >= 16#1400#/4 and a < 16#1700#/4 and rd = '1') then
                  if rd = '0' then
                     for b in 0 to 3 loop if mask(b) = '1' then memory(a)(b*8+7 downto b*8) := value(b*8+7 downto b*8); end if; end loop;
                     physical_writes <= physical_writes+1;
                     if ACTIVE_DEVICES and a >= 16#3000#/4 and a < 16#3100#/4 then
                        assert a-16#3000#/4 = dma9_writes mod 64 and
                           unsigned(value) = 16#69000000#+dma9_writes mod 64 and mask = "1111"
                           report "ARM9 DMA skipped/repeated/corrupted destination" severity failure;
                        dma9_writes <= dma9_writes+1;
                     elsif ACTIVE_DEVICES and a >= 16#3400#/4 and a < 16#3500#/4 then
                        assert a-16#3400#/4 = dma7_writes mod 64 and
                           unsigned(value) = 16#67000000#+dma7_writes mod 64 and mask = "1111"
                           report "ARM7 DMA skipped/repeated/corrupted destination" severity failure;
                        dma7_writes <= dma7_writes+1;
                     end if;
                     if a = 16#2000#/4 then
                        assert unsigned(value) = count9+1 report "ARM9 counter skipped/repeated" severity failure;
                        count9 <= count9+1;
                     elsif a = 16#2004#/4 then
                        assert unsigned(value) = count7+1 report "ARM7 counter skipped/repeated" severity failure;
                        count7 <= count7+1;
                     end if;
                  end if;
                  sdram_Dout <= memory(a); sdram_done32 <= '1'; low_returned := true; tail := 1;
               end if;
            elsif tail > 0 then tail := tail-1;
            else sdram_Dout_hi <= memory((a+1) mod 1048576); sdram_done64 <= '1'; pending := false; end if;
         end if;
         if sdram_ena = '1' then
            assert not pending report "overlapping SDRAM requests" severity failure;
            pending := true; low_returned := false; delay := LATENCY-1;
            a := to_integer(unsigned(sdram_Adr(21 downto 2))); rd := sdram_rnw; value := sdram_Din; mask := sdram_be;
         end if;
         memory_pending <= pending;
         sound_memory_pending <= pending and not low_returned and a >= 16#1400#/4 and a < 16#1700#/4 and rd = '1';
      end if;
   end process;
   vram_backing : process(clk1x)
      type memory_t is array(0 to 131071) of std_logic_vector(31 downto 0);
      variable memory : memory_t := (others => x"5AA55AA5");
      variable pending : boolean := false;
      variable seq : std_logic := '0';
      variable delay, a : natural := 0;
      variable rd, wide : std_logic;
      variable value, high : std_logic_vector(31 downto 0);
      variable mask, highmask : std_logic_vector(3 downto 0);
   begin
      if rising_edge(clk1x) then
         vsrv_done <= '0';
         if pending then
            if delay > 0 then delay := delay-1;
            else
               if rd = '0' then
                  for b in 0 to 3 loop
                     if mask(b) = '1' then memory(a)(b*8+7 downto b*8) := value(b*8+7 downto b*8); end if;
                     if wide = '1' and highmask(b) = '1' then memory(a+1)(b*8+7 downto b*8) := high(b*8+7 downto b*8); end if;
                  end loop;
               end if;
               vsrv_dout <= memory(a); vsrv_dout_hi <= memory((a+1) mod 131072); vsrv_done <= '1'; pending := false;
            end if;
         end if;
         if vsrv_req = '1' and vsrv_seq /= seq then
            assert not pending report "overlapping VRAM requests" severity failure;
            seq := vsrv_seq; pending := true; delay := LATENCY;
            a := to_integer(unsigned(vsrv_bank))*32768+to_integer(vsrv_addr);
            rd := vsrv_rnw; wide := vsrv_wide; value := vsrv_din; high := vsrv_din_hi;
            mask := vsrv_be; highmask := vsrv_be_hi;
         end if;
      end if;
   end process;
   stimulus : process
      variable c9, c7, writes : natural;
      variable stamp : std_logic_vector(63 downto 0);
      type snapshot_t is array(0 to 139) of std_logic_vector(31 downto 0);
      variable snapshot : snapshot_t;
      variable address, words, slot : natural;
      procedure step(n : positive := 1) is
      begin for i in 1 to n loop wait until rising_edge(clk1x); wait for 1 ns; end loop; end;
      procedure progress is
      begin
         c9 := count9; c7 := count7;
         for i in 1 to 200000 loop step; exit when count9 >= c9+5 and count7 >= c7+5; end loop;
         assert count9 >= c9+5 and count7 >= c7+5 report "CPU progress failed PC9=" & to_hstring(dbg_pc9) & " PC7=" & to_hstring(dbg_pc7) severity failure;
      end;
      procedure release_owner is
      begin
         checkpoint_request <= '0';
         for i in 1 to 1000 loop step; exit when checkpoint_ready = '1'; end loop;
         assert checkpoint_ready = '1' and checkpoint_pair_paused = '0' report "release did not finish" severity failure;
      end;
   begin
      step(10); reset <= '0';
      for i in 1 to 4000000 loop step; exit when boot_done = '1'; end loop;
      assert boot_done = '1' and boot_error = '0' report "authored direct boot failed" severity failure;
      assert unsigned(dbg_vfy_bad) = 0 report "loader copy verification failed" severity failure;
      report "BOOT_PASS time=" & time'image(now);
      progress;
      for attempt in 0 to 3 loop
         step(attempt*13+1);
         if ACTIVE_DEVICES then
            -- Target real owner phases instead of hoping a random request
            -- overlaps traffic. These are observations, never forced grants.
            for i in 1 to 20000 loop
               step;
               exit when (attempt = 0 and dma9_active = '1') or
                  (attempt = 1 and dma7_active = '1') or
                  (attempt = 2 and sound_inflight = '1') or
                  (attempt = 3 and dma7_active = '1' and memory_pending);
            end loop;
            assert (attempt = 0 and dma9_active = '1') or
               (attempt = 1 and dma7_active = '1') or
               (attempt = 2 and sound_inflight = '1') or
               (attempt = 3 and dma7_active = '1' and memory_pending)
               report "fixture did not reach requested active owner phase" severity failure;
         end if;
         checkpoint_request <= '1';
         for i in 1 to 4500 loop step; exit when checkpoint_pair_paused = '1' or checkpoint_timed_out = '1'; end loop;
         assert checkpoint_pair_paused = '1' report "common acquisition failed local=" & std_logic'image(checkpoint_local_idle) &
            " graphics=" & std_logic'image(checkpoint_graphics_stopped) & " owners=" &
            to_string(std_logic_vector'(checkpoint_dma_stopped & checkpoint_sound_stopped & checkpoint_timing_stopped & checkpoint_mainram_idle & checkpoint_vram_idle &
            checkpoint_arm7_memory_idle & checkpoint_shared_wram_idle & checkpoint_irq_idle & checkpoint_ipc_idle & checkpoint_card_stopped &
            checkpoint_spi_stopped & checkpoint_inputs_held & checkpoint_arm9_memory_idle)) severity failure;
         c9 := count9; c7 := count7; writes := physical_writes; stamp := h3d_timestamp;
         step(100);
         assert count9 = c9 and count7 = c7 and physical_writes = writes and not memory_pending and h3d_timestamp = stamp
            report "held console continued mutating" severity failure;
         -- Read every defined CPU word twice through the real control CDC.
         -- Compare the stable image and check PC/R0/R1 against guest effects.
         for pass in 0 to 1 loop
          for cpu in 0 to 1 loop
            if cpu = 0 then checkpoint_read_cpu <= '0'; words := 80;
            else checkpoint_read_cpu <= '1'; words := 60; end if;
            for word_index in 0 to words-1 loop
               slot := cpu*80+word_index;
               if word_index < 47 then address := word_index;
               elsif cpu = 0 and word_index < 68 then address := word_index+81;
               elsif cpu = 0 then address := word_index+92;
               elsif word_index = 47 then address := 148;
               else address := word_index+112; end if;
               for i in 1 to 100 loop step; exit when checkpoint_read_ready = '1'; end loop;
               assert checkpoint_read_ready = '1' report "CPU read transport unavailable" severity failure;
               checkpoint_read_address <= std_logic_vector(to_unsigned(address,8)); checkpoint_read_epoch <= checkpoint_epoch;
               checkpoint_read_strobe <= '1'; step; checkpoint_read_strobe <= '0';
               for i in 1 to 100 loop step; exit when checkpoint_read_done = '1'; end loop;
               assert checkpoint_read_done = '1' and checkpoint_read_error = '0' and checkpoint_result_epoch = checkpoint_epoch
                  report "CPU state read failed" severity failure;
               assert not is_x(checkpoint_read_data) report "CPU image contains unknown state" severity failure;
               if pass = 0 then snapshot(slot) := checkpoint_read_data;
               else assert snapshot(slot) = checkpoint_read_data report "held CPU image changed" severity failure; end if;
               if address = 0 then
                  if cpu = 0 then assert checkpoint_read_data = LOOP_PC_9 or checkpoint_read_data = DMA_WAIT_PC_9 report "ARM9 captured wrong branch target" severity failure;
                  else assert checkpoint_read_data = LOOP_PC_7 or checkpoint_read_data = DMA_WAIT_PC_7 report "ARM7 captured wrong branch target" severity failure; end if;
               elsif address = 1 then
                  if cpu = 0 then assert checkpoint_read_data = x"02002000" severity failure;
                  else assert checkpoint_read_data = x"02002004" severity failure; end if;
               elsif address = 2 then
                  if cpu = 0 then assert unsigned(checkpoint_read_data) = c9 report "ARM9 capture differs from committed RAM" severity failure;
                  else assert unsigned(checkpoint_read_data) = c7 report "ARM7 capture differs from committed RAM" severity failure; end if;
               end if;
            end loop;
          end loop;
         end loop;
         assert h3d_timestamp = stamp and count9 = c9 and count7 = c7 and physical_writes = writes
            report "console changed during CPU image read" severity failure;
         release_owner; progress;
      end loop;
      allow_host <= '0'; checkpoint_request <= '1';
      for i in 1 to 4500 loop step; exit when checkpoint_timed_out = '1'; end loop;
      assert checkpoint_timed_out = '1' and checkpoint_pair_paused = '0' report "missing host did not time out" severity failure;
      release_owner; allow_host <= '1'; progress;
      -- Backpressured graphics must drain through the connected gate before
      -- the local/host owners can certify a pause.
      sink_ready <= '0';
      for i in 1 to 3000 loop step; exit when h3d_hblank_valid = '1'; end loop;
      assert h3d_hblank_valid = '1' report "fixture did not observe HBlank traffic" severity failure;
      checkpoint_request <= '1'; step(200);
      assert checkpoint_pair_paused = '0' and checkpoint_graphics_stopped = '0'
         report "stalled graphics bypassed common barrier" severity failure;
      sink_ready <= '1';
      for i in 1 to 4000 loop step; exit when checkpoint_pair_paused = '1'; end loop;
      assert checkpoint_pair_paused = '1' report "drained graphics did not acquire" severity failure;
      release_owner; progress;
      -- An accepted SDRAM read with no reply cannot be hidden by a pause.
      -- Timeout must cancel ownership without discarding that transaction.
      respond <= '0'; step(100);
      assert memory_pending report "missing-response fixture has no outstanding request" severity failure;
      checkpoint_request <= '1';
      for i in 1 to 4500 loop step; exit when checkpoint_timed_out = '1'; end loop;
      assert checkpoint_timed_out = '1' and checkpoint_pair_paused = '0' report "missing SDRAM response falsely acquired" severity failure;
      release_owner; respond <= '1'; progress;
      -- Lost host software cannot leave a successfully held machine stuck.
      checkpoint_request <= '1';
      for i in 1 to 4000 loop step; exit when checkpoint_pair_paused = '1'; end loop;
      assert checkpoint_pair_paused = '1' report "lease scenario failed to acquire" severity failure;
      step(20050);
      assert checkpoint_lease_expired = '1' and checkpoint_pair_paused = '0' report "console hold outlived host lease" severity failure;
      release_owner; progress;
      if ACTIVE_DEVICES then
         hold_sound_response <= '1';
         for i in 1 to 20000 loop step; exit when sound_memory_pending; end loop;
         assert sound_memory_pending report "no accepted SPU memory request to withhold" severity failure;
         checkpoint_request <= '1';
         for i in 1 to 4500 loop step; exit when checkpoint_timed_out = '1'; end loop;
         assert checkpoint_timed_out = '1' and checkpoint_pair_paused = '0' and checkpoint_sound_stopped = '0'
            report "missing SPU response falsely acquired" severity failure;
         release_owner; hold_sound_response <= '0'; progress;
         step(650000); progress;
         checkpoint_request <= '1';
         for i in 1 to 4000 loop step; exit when checkpoint_pair_paused = '1'; end loop;
         assert checkpoint_pair_paused = '1' report "final active-device drain failed" severity failure;
         assert dma9_writes mod 64 = 0 and dma7_writes mod 64 = 0
            report "common hold left a partial immediate DMA transfer" severity failure;
         assert sound_samples >= 600 and sound_varied >= 100 and sound_loops_complete
            report "connected audio lacked active loop/refill coverage" severity failure;
         assert dma9_writes >= 10*64 and dma7_writes >= 10*64
            report "connected DMA lacked repeated transfer coverage" severity failure;
         report "CHECKPOINT_CONSOLE_DEVICES_PASS samples=" & integer'image(sound_samples) &
            " varied=" & integer'image(sound_varied) & " fetches=" & integer'image(sound_fetches) &
            " DMA9_words=" & integer'image(dma9_writes) & " DMA7_words=" & integer'image(dma7_writes);
      end if;
      report "CHECKPOINT_CONSOLE_PASS latency=" & integer'image(LATENCY) & " ARM9_half_ns=" & integer'image(ARM9_HALF_NS) &
         " counters=" & integer'image(count9) & "," & integer'image(count7);
      std.env.stop; wait;
   end process;
   process begin wait for 250 ms; assert false report "console test watchdog" severity failure; end process;
end;
