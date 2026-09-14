-- SPDX-License-Identifier: GPL-3.0-or-later
-- Actual accepted/candidate sound instances, with passive register probes.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pProc_bus_gba.all;
entity tb_nds_sound_unit_equivalence is
   generic(TABLE_MODE : integer := 1);
end entity;
architecture test of tb_nds_sound_unit_equivalence is
   signal clk : std_logic:='0';
   signal reset : std_logic:='1';
   signal ce : std_logic:='1';
   signal bus7 : proc_bus_gb_type := ((others=>'0'),(others=>'0'),'1','0',"10","0000",'0');
   signal grant, mb_done : std_logic:='0';
   signal mb_din : std_logic_vector(31 downto 0):=(others=>'0');
   type words is array(0 to 1) of std_logic_vector(31 downto 0);
   type halves is array(0 to 1) of std_logic_vector(15 downto 0);
   type probes is array(0 to 1) of std_logic_vector(639 downto 0);
   signal read_data,mb_adr : words;
   signal left_sample,right_sample,active : halves;
   signal read_done,req,own,ena,valid,enabled : std_logic_vector(0 to 1);
   signal audit : probes;
   signal checks,samples,varied,fetches,stalled,grant_stalls,write_edges : natural:=0;
   signal active_seen : std_logic_vector(15 downto 0):=(others=>'0');
   function advance(v : unsigned(31 downto 0)) return unsigned is
      variable x : unsigned(31 downto 0):=v;
   begin
      x:=x xor shift_left(x,13);x:=x xor shift_right(x,17);return x xor shift_left(x,5);
   end function;
   function contents(a : std_logic_vector(31 downto 0)) return std_logic_vector is
      variable x : unsigned(31 downto 0);
   begin
      -- Valid ADPCM header on each channel's first word; subsequent words
      -- provide varied PCM and ADPCM data without host or hardware access.
      if a(9 downto 0)="0000000000" then return x"00000040";end if;
      x:=advance(unsigned(a) xor x"92dbea17");return std_logic_vector(x);
   end function;
begin
   clk<=not clk after 5 ns;
   ref_dut: entity work.sound_unit_reference generic map(is_simu=>'1',ADPCM_TABLE_RAM=>TABLE_MODE)
   port map(clk,ce,reset,bus7,read_data(0),read_done(0),req(0),grant,own(0),ena(0),mb_adr(0),mb_din,mb_done,
            left_sample(0),right_sample(0),valid(0),enabled(0),active(0),audit(0));
   dut: entity work.sound_unit_candidate generic map(is_simu=>'1',ADPCM_TABLE_RAM=>TABLE_MODE)
   port map(clk,ce,reset,bus7,read_data(1),read_done(1),req(1),grant,own(1),ena(1),mb_adr(1),mb_din,mb_done,
            left_sample(1),right_sample(1),valid(1),enabled(1),active(1),audit(1));
   monitor: process
      variable previous : std_logic_vector(31 downto 0):=(others=>'0');
   begin
      wait on clk;wait for 1 ns;
      assert read_data(0)=read_data(1) and read_done(0)=read_done(1) and
             req(0)=req(1) and own(0)=own(1) and ena(0)=ena(1) and mb_adr(0)=mb_adr(1) and
             left_sample(0)=left_sample(1) and right_sample(0)=right_sample(1) and
             valid(0)=valid(1) and enabled(0)=enabled(1) and active(0)=active(1) and audit(0)=audit(1)
         report "full sound equivalence mismatch; TABLE_MODE=" & integer'image(TABLE_MODE) &
                " check=" & integer'image(checks) severity failure;
      checks<=checks+1;
      if clk='1' and reset='0' then
         active_seen<=active_seen or active(0);
         if ce='0' then stalled<=stalled+1;end if;
         if req(0)='1' and grant='0' then grant_stalls<=grant_stalls+1;end if;
         if ce='1' and bus7.ena='1' and bus7.rnw='0' then write_edges<=write_edges+1;end if;
         if valid(0)='1' then
            samples<=samples+1;
            if previous/=(left_sample(0)&right_sample(0)) then varied<=varied+1;end if;
            previous:=left_sample(0)&right_sample(0);
         end if;
      end if;
   end process;
   memory: process(clk)
      variable delay : natural:=0;
      variable seen : boolean:=false;
      variable pending_address : std_logic_vector(31 downto 0);
      variable cycles : natural:=0;
   begin
      if rising_edge(clk) then
         cycles:=cycles+1;
         if cycles mod 97<19 then grant<='0';else grant<='1';end if;
         if reset='1' then delay:=0;seen:=false;mb_done<='0';
         else
            if mb_done='1' and ce='1' then mb_done<='0';end if;
            if delay>0 then
               delay:=delay-1;
               if delay=0 then mb_done<='1';mb_din<=contents(pending_address);end if;
            end if;
            if ena(0)='0' then seen:=false;end if;
            if ena(0)='1' and not seen then
               assert delay=0 and mb_done='0' report "fixture overlapping sound requests" severity failure;
               seen:=true;pending_address:=mb_adr(0);
               delay:=1+(cycles mod 23);fetches<=fetches+1;
            end if;
         end if;
      end if;
   end process;
   stimulus: process
      variable rng : unsigned(31 downto 0):=x"84625719";
      variable value : std_logic_vector(31 downto 0);
      procedure step(constant count : positive:=1) is
      begin
         for i in 1 to count loop wait until falling_edge(clk);end loop;
      end procedure;
      procedure write_reg(constant a : natural;constant v : std_logic_vector(31 downto 0);
                          constant lanes : std_logic_vector(3 downto 0):="1111";
                          constant hold_cycles : positive:=1) is
      begin
         step;ce<='1';bus7.Adr<=std_logic_vector(to_unsigned(a,28));bus7.Din<=v;
         bus7.ena<='1';bus7.rnw<='0';bus7.bEna<=lanes;step(hold_cycles);
         bus7.ena<='0';bus7.rnw<='1';step;
      end procedure;
      procedure start_channels is
         variable control : unsigned(31 downto 0);
         variable format_value : natural;
      begin
         write_reg(16#500#,x"0000807f");
         for channel in 0 to 15 loop
            write_reg(16#404#+16*channel,std_logic_vector(to_unsigned(16#2020000#+1024*channel,32)));
            write_reg(16#408#+16*channel,x"0001fe00");
            write_reg(16#40c#+16*channel,x"00000020");
            if channel<2 then format_value:=0;elsif channel<4 then format_value:=1;
            elsif channel<8 then format_value:=2;else format_value:=3;end if;
            control:=x"88000007" or shift_left(to_unsigned(format_value,32),29) or
                     shift_left(to_unsigned((channel*7) mod 128,32),16) or
                     shift_left(to_unsigned(channel mod 7,32),24);
            write_reg(16#400#+16*channel,std_logic_vector(control));
         end loop;
      end procedure;
   begin
      step(4);reset<='0';step(200);start_channels;
      -- Run every channel format while all register aliases are read, including
      -- address-only responses with ena low, arbitrary access widths and lanes.
      for epoch in 0 to 15 loop
         for offset in 0 to 511 loop
            bus7.Adr<=std_logic_vector(to_unsigned(16#400#+offset,28));
            bus7.ena<=std_logic(to_unsigned(offset,9)(0));bus7.rnw<='1';
            bus7.acc<=std_logic_vector(to_unsigned(offset mod 4,2));step;
         end loop;
         write_reg(16#504#+32*(epoch mod 8),std_logic_vector(to_unsigned(384+epoch*7,32)),"0011");
         write_reg(16#508#,std_logic_vector(to_unsigned(epoch*257,32)),"0011");
         write_reg(16#510#,std_logic_vector(to_unsigned(16#123400#+epoch,32)));
         write_reg(16#514#,std_logic_vector(to_unsigned(17+epoch,32)),"0001");
         write_reg(16#518#,std_logic_vector(to_unsigned(16#765400#+epoch,32)));
         write_reg(16#51c#,std_logic_vector(to_unsigned(256+epoch,32)),"0010");
      end loop;
      for iteration in 1 to 50000 loop
         rng:=advance(rng);bus7.ena<='0';bus7.rnw<='1';
         bus7.Adr<=std_logic_vector(to_unsigned(16#400#,28) or resize(rng(8 downto 0),28));
         ce<='1';if iteration mod 79<7 then ce<='0';end if;
         if iteration mod 257=0 then
            -- Partial channel-control writes avoid changing sample format;
            -- all state, bus traffic and stereo samples must still match.
            value:=std_logic_vector(rng);
            write_reg(16#400#+16*(iteration mod 16),value,"0111",2);
         elsif iteration mod 509=0 then
            write_reg(16#500#,x"0000807f","0011",2);
         elsif iteration mod 991=0 then
            -- Writes outside the sound window must not change its state.
            write_reg(16#600#+iteration mod 512,std_logic_vector(rng));
         end if;
         step;
      end loop;
      -- Cold/reset epoch while operations are active, then reinitialize and
      -- verify continuation through a second set of channel starts.
      ce<='0';reset<='1';step(3);reset<='0';ce<='1';step(200);start_channels;
      bus7.ena<='0';bus7.rnw<='1';step(12000);
      assert samples>50 and varied>10 and fetches>100 and stalled>100 and grant_stalls>0 and
             write_edges>300 and active_seen=x"ffff"
         report "missing required full sound fixture coverage" severity failure;
      report "PASS: full sound equivalence TABLE_MODE=" & integer'image(TABLE_MODE) &
             " half-edge checks=" & integer'image(checks) & " samples=" & integer'image(samples) &
             " varied=" & integer'image(varied) & " fetches=" & integer'image(fetches) &
             " ce_stalls=" & integer'image(stalled) & " grant_stalls=" & integer'image(grant_stalls) &
             " writes=" & integer'image(write_edges) severity note;
      std.env.stop;wait;
   end process;
   watchdog: process begin wait for 3 ms;assert false report "full sound test timeout" severity failure;end process;
end architecture;
