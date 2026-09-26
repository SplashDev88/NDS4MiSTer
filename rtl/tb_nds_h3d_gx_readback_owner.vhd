library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

entity tb_nds_h3d_gx_readback_owner is end entity;
architecture test of tb_nds_h3d_gx_readback_owner is
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal service_ready, cpu_read, geometry_write : std_logic := '0';
   signal address : std_logic_vector(27 downto 0) := (others=>'0');
   signal selected, busy, complete, fence_valid, request_valid : std_logic;
   signal request_ready, response_valid : std_logic := '0';
   signal request_id, read_data : std_logic_vector(31 downto 0);
   signal response_id, response_status : std_logic_vector(31 downto 0) := (others=>'0');
   signal cache_index : std_logic_vector(4 downto 0);
   signal cache_data : std_logic_vector(31 downto 0) := (others=>'0');
   signal bank_base : unsigned(31 downto 0) := x"10000000";
   signal fences : natural := 0;
   signal gx_write : std_logic := '0';
   signal gx_address : std_logic_vector(27 downto 0) := (others=>'0');
   signal gx_data : std_logic_vector(31 downto 0) := (others=>'0');
   signal test_bits : std_logic_vector(1 downto 0);

   signal wrap_reset : std_logic := '1';
   signal wrap_cpu_read, wrap_geometry_write, wrap_ready, wrap_response_valid : std_logic := '0';
   signal wrap_busy, wrap_complete, wrap_fence, wrap_request : std_logic;
   signal wrap_token : std_logic_vector(31 downto 0);
   signal wrap_done : std_logic := '0';
begin
   clk <= not clk after 5 ns;
   dut: entity work.nds_h3d_gx_readback_owner port map (
      clk=>clk, reset=>reset, service_ready=>service_ready,
      cpu_read=>cpu_read, address=>address, geometry_write=>geometry_write,
      gx_write=>gx_write, gx_address=>gx_address, gx_data=>gx_data,
      test_result_bits=>test_bits,
      selected=>selected, busy=>busy, complete=>complete, read_data=>read_data,
      fence_valid=>fence_valid, request_valid=>request_valid,
      request_ready=>request_ready, request_id=>request_id,
      response_valid=>response_valid, response_id=>response_id,
      response_status=>response_status, cache_index=>cache_index, cache_data=>cache_data);

   wrap_dut: entity work.nds_h3d_gx_readback_owner
      generic map (INITIAL_REQUEST_SEQUENCE=>x"fffffffe")
      port map (
         clk=>clk, reset=>wrap_reset, service_ready=>'1',
         cpu_read=>wrap_cpu_read, address=>x"0000640", geometry_write=>wrap_geometry_write,
         selected=>open, busy=>wrap_busy, complete=>wrap_complete, read_data=>open,
         fence_valid=>wrap_fence, request_valid=>wrap_request,
         request_ready=>wrap_ready, request_id=>wrap_token,
         response_valid=>wrap_response_valid, response_id=>x"ffffffff",
         response_status=>x"00000002", cache_index=>open, cache_data=>x"00000002");

   process
      procedure tick is
      begin wait until rising_edge(clk); wait for 1 ns; end;
   begin
      tick; wrap_reset<='0'; tick;
      wrap_cpu_read<='1'; tick; wrap_cpu_read<='0';
      assert wrap_request='1' and wrap_token=x"ffffffff" severity failure;
      wrap_ready<='1'; wait for 1 ns;
      assert wrap_fence='1' severity failure;
      tick; wrap_ready<='0';
      assert wrap_busy='1' and wrap_request='0' severity failure;
      wrap_response_valid<='1'; tick; wrap_response_valid<='0'; tick; tick;
      assert wrap_complete='1' report "last nonzero request token did not complete" severity failure;
      wrap_geometry_write<='1'; tick; wrap_geometry_write<='0';
      wrap_cpu_read<='1'; tick; wrap_cpu_read<='0';
      wrap_response_valid<='1';
      for i in 1 to 8 loop
         tick;
         assert wrap_busy='1' and wrap_complete='0' and wrap_request='0' and wrap_fence='0'
            report "exhausted token accepted the previous request's reply" severity failure;
         assert wrap_token=x"ffffffff" report "exhaustion wrapped token to zero" severity failure;
      end loop;
      -- Reset cancels the blocked read but cannot replenish consumed IDs.
      wrap_reset<='1'; tick; wrap_reset<='0'; tick;
      wrap_cpu_read<='1'; tick; wrap_cpu_read<='0';
      for i in 1 to 8 loop
         tick;
         assert wrap_busy='1' and wrap_complete='0' and wrap_request='0' and wrap_fence='0'
            report "guest reset revived an exhausted token" severity failure;
      end loop;
      wrap_done<='1';
      report "stage maximum token completes once, exhaustion rejects stale replies across reset";
      wait;
   end process;

   process(clk)
   begin
      if rising_edge(clk) then
         cache_data <= std_logic_vector(bank_base + resize(unsigned(cache_index),32));
         assert fence_valid=(request_valid and request_ready)
            report "sentinel was not exactly concurrent with request acceptance" severity failure;
         if fence_valid='1' then fences<=fences+1; end if;
      end if;
   end process;

   process
      procedure tick is
      begin wait until rising_edge(clk); wait for 1 ns; end;
      procedure start_read(constant addr : natural) is
      begin
         address<=std_logic_vector(to_unsigned(addr,28)); cpu_read<='1';
         tick; cpu_read<='0';
         assert busy='1' and complete='0' report "CPU read was not held" severity failure;
      end;
      procedure accept_request(constant id : natural; constant delay : natural := 3) is
      begin
         for i in 1 to delay loop
            assert request_valid='1' and fence_valid='0' and busy='1' and complete='0'
               report "request did not remain held before readiness" severity failure;
            assert unsigned(request_id)=id report "request token changed/reused" severity failure;
            tick;
         end loop;
         request_ready<='1'; wait for 1 ns;
         assert fence_valid='1' report "missing accepted-request sentinel" severity failure;
         tick; request_ready<='0';
         assert request_valid='0' and fence_valid='0' and busy='1' and complete='0'
            report "posting acceptance retired the CPU read" severity failure;
      end;
      procedure reply(constant id : natural; constant status : std_logic_vector(31 downto 0);
                      constant expected : std_logic_vector(31 downto 0)) is
      begin
         response_id<=std_logic_vector(to_unsigned(id,32)); response_status<=status;
         response_valid<='1'; tick; response_valid<='0';
         assert complete='0' report "reply bypassed synchronous RAM latency" severity failure;
         tick;
         assert complete='0' report "reply cache was returned too early" severity failure;
         tick;
         assert complete='1' and busy='0' and read_data=expected
            report "matching reply data/latency mismatch: got " & to_hstring(read_data) &
                   " expected " & to_hstring(expected) severity failure;
         tick;
         assert complete='0' report "completion was not a single pulse" severity failure;
      end;
      procedure cached_read(constant addr : natural; constant expected : std_logic_vector(31 downto 0)) is
         variable before_fences : natural;
      begin
         before_fences:=fences;
         start_read(addr);
         assert request_valid='0' report "cache hit posted another query" severity failure;
         tick;
         assert complete='0' and request_valid='0' severity failure;
         tick;
         assert complete='1' and read_data=expected and fences=before_fences
            report "cache burst word mismatch or repeated fence at " & integer'image(addr)
            severity failure;
         tick;
      end;
      procedure write_gx(constant addr : natural; constant value : std_logic_vector(31 downto 0)) is
      begin
         gx_address<=std_logic_vector(to_unsigned(addr,28)); gx_data<=value;
         gx_write<='1'; tick; gx_write<='0';
      end;
      procedure local_status(constant bits : std_logic_vector(1 downto 0)) is
      begin
         address<=x"0000600"; wait for 1 ns;
         assert selected='0' and request_valid='0' and busy='0' and test_bits=bits
            report "ordinary GXSTAT poll must use cached bits locally" severity failure;
      end;
      procedure invalidate is
      begin geometry_write<='1'; tick; geometry_write<='0'; end;
      variable before_fences : natural;
   begin
      tick; tick; reset<='0'; service_ready<='1'; tick;
      address<=x"0000610"; wait for 1 ns;
      assert selected='0' report "unowned address intercepted" severity failure;

      start_read(16#640#); accept_request(1,6);
      -- A stale or wrong reply must not retire or unstall the CPU.
      response_valid<='1'; response_id<=x"00000009"; response_status<=x"ffffffff";
      for i in 1 to 5 loop
         tick; assert complete='0' and busy='1' and request_valid='0' severity failure;
      end loop;
      response_valid<='0';
      reply(1,x"f7fffffe",x"10000005");
      assert fences=1 severity failure;
      for i in 0 to 15 loop
         cached_read(16#640#+4*i,std_logic_vector(bank_base+to_unsigned(5+i,32)));
      end loop;
      for i in 0 to 8 loop
         cached_read(16#680#+4*i,std_logic_vector(bank_base+to_unsigned(21+i,32)));
      end loop;
      address<=x"0000600"; wait for 1 ns;
      assert selected='0' report "GXSTAT polling must remain local" severity failure;
      assert fences=1 report "matrix/status burst posted repeated fences" severity failure;
      report "stage delayed reply, 16 clip plus 9 vector words share one cache query; GXSTAT local";

      -- Writes invalidate the generation, while either geometry-busy or
      -- test-busy status requires another real snapshot on the next read.
      invalidate; start_read(16#640#); accept_request(2);
      reply(2,x"08000002",x"10000005");
      start_read(16#640#); accept_request(3);
      reply(3,x"00000001",x"10000005");
      start_read(16#640#); accept_request(4);
      bank_base<=x"20000000";
      reply(4,x"00000002",x"20000005");
      cached_read(16#67c#,x"20000014");
      report "stage invalidation and busy-result refresh";

      -- An intervening write invalidates an in-flight snapshot too. A later
      -- reply may complete that read but must not resurrect the old cache.
      invalidate; start_read(16#640#); accept_request(5);
      invalidate;
      reply(5,x"00000002",x"20000005");
      start_read(16#644#); accept_request(6);
      bank_base<=x"30000000";
      reply(6,x"00000002",x"30000006");
      report "stage outstanding generation invalidation";

      -- Guest reset cancels an unaccepted request; tokens nevertheless keep
      -- increasing, including across a reset while a reply is outstanding.
      invalidate; start_read(16#640#);
      assert request_id=x"00000007" severity failure;
      before_fences:=fences;
      reset<='1'; tick;
      assert busy='0' and request_valid='0' and complete='0' and fences=before_fences severity failure;
      reset<='0'; tick;
      start_read(16#640#); accept_request(8);
      reset<='1'; tick; reset<='0'; tick;
      response_id<=x"00000008"; response_valid<='1'; tick; response_valid<='0';
      assert complete='0' and busy='0' severity failure;
      start_read(16#640#); accept_request(9);
      response_id<=x"00000008"; response_valid<='1'; tick; response_valid<='0';
      assert complete='0' and busy='1' severity failure;
      reply(9,x"00000002",x"30000005");

      -- Service loss cancels ownership and invalidates the current cache.
      service_ready<='0'; tick;
      assert selected='0' and busy='0' and complete='0' severity failure;
      service_ready<='1'; tick;
      start_read(16#640#); accept_request(10);
      reply(10,x"0000bb02",x"30000005");

      -- A reset during the synchronous cache-return pipeline cancels the
      -- read too; the queued cache hit must not pulse complete afterward.
      start_read(16#640#);
      assert request_valid='0' severity failure;
      reset<='1'; tick; reset<='0'; tick; tick;
      assert complete='0' and busy='0' report "reset leaked a queued cache completion" severity failure;
      start_read(16#640#); accept_request(11);
      reply(11,x"00000002",x"30000005");
      local_status("00");
      -- Direct BOX: partial parameter sets must remain dirty while busy.
      write_gx(16#5c0#,x"00000000");
      start_read(16#600#); accept_request(12);
      reply(12,x"0e000001",x"00000001");
      assert selected='1' and test_bits="01" report "partial test cached as completed" severity failure;
      write_gx(16#5c0#,x"00001000"); write_gx(16#5c0#,x"10001000");
      start_read(16#600#); accept_request(13);
      reply(13,x"c6000002",x"00000002");
      local_status("10");
      -- An in-flight old result cannot consume a later test generation.
      write_gx(16#5c4#,x"00000000");
      start_read(16#600#); accept_request(14);
      write_gx(16#5c4#,x"00000000");
      reply(14,x"00000002",x"00000002");
      assert selected='1' report "later test write was lost" severity failure;
      start_read(16#600#); accept_request(15);
      reply(15,x"00000000",x"00000000"); local_status("00");
      -- Packed stream: zero-param commands before BOX and POS, with direct
      -- commands interleaved, must neither desynchronize nor dirty early.
      write_gx(16#400#,x"71701511"); local_status("00");
      write_gx(16#440#,x"00000002"); local_status("00");
      write_gx(16#400#,x"00000000");
      write_gx(16#400#,x"00001000"); write_gx(16#400#,x"10001000");
      start_read(16#600#); accept_request(16);
      reply(16,x"00000002",x"00000002"); local_status("10");
      write_gx(16#43c#,x"00000000"); write_gx(16#43c#,x"00000000");
      start_read(16#600#); accept_request(17);
      reply(17,x"00000002",x"00000002"); local_status("10");
      -- A 32-parameter shininess command precedes another BOX. Parameter
      -- values that resemble command bytes must not affect classification.
      write_gx(16#400#,x"00700034");
      for i in 1 to 32 loop write_gx(16#400#,x"70717071"); local_status("10"); end loop;
      write_gx(16#400#,x"00000000"); write_gx(16#400#,x"00000000");
      write_gx(16#400#,x"00000000");
      start_read(16#600#); accept_request(18);
      reply(18,x"00000000",x"00000000"); local_status("00");
      -- Reset removes partial packed-command and cached test state.
      write_gx(16#400#,x"00000070"); write_gx(16#400#,x"00000000");
      reset<='1'; tick; reset<='0'; tick; local_status("00");
      write_gx(16#400#,x"00000011"); local_status("00");
      report "stage selective BOX/POS GXSTAT, packed/direct parser, busy refresh and later generation";
      -- Vector-first queries use the same ordered fence and share their
      -- reply with later clip reads. Busy and invalidation rules also apply.
      start_read(16#680#); accept_request(19);
      reply(19,x"00000002",x"30000015");
      cached_read(16#6a0#,x"3000001d");
      cached_read(16#640#,x"30000005");
      address<=x"00006a4"; wait for 1 ns;
      assert selected='0' report "vector range overran its nine words" severity failure;
      invalidate; start_read(16#68c#); accept_request(20);
      reply(20,x"08000002",x"30000018");
      start_read(16#6a0#); accept_request(21);
      reply(21,x"00000002",x"3000001d");
      invalidate; start_read(16#684#); accept_request(22);
      invalidate; reply(22,x"00000002",x"30000016");
      start_read(16#684#); accept_request(23);
      reply(23,x"00000002",x"30000016");
      assert wrap_done='1' report "token exhaustion test did not finish" severity failure;
      report "PASS: GX readback owner delayed handshakes, matching replies, cache generation, busy refresh, reset token retention; fences=" & integer'image(fences);
      stop; wait;
   end process;

   process begin wait for 50 us; assert false report "owner test timeout" severity failure; end process;
end architecture;
