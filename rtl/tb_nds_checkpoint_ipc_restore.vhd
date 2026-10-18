-- SPDX-License-Identifier: GPL-3.0-or-later
-- Fresh-process IPC plus both real IRQ controllers. The reference is recorded
-- during ordinary execution, including both consumer sampling phases.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use work.pProc_bus_gba.all;
entity tb_nds_checkpoint_ipc_restore is
   generic(RESTORING : boolean := false; SCENARIO : natural range 0 to 6 := 0;
      WRITE_ORDER : natural range 0 to 2 := 0; SEED : positive := 1);
end;
architecture sim of tb_nds_checkpoint_ipc_restore is
   constant EMPTY_BUS : proc_bus_gb_type := ((others=>'0'),(others=>'0'),'1','0',ACCESS_32BIT,"1111",'0');
   type buses is array(0 to 1) of proc_bus_gb_type;
   type words is array(natural range <>) of std_logic_vector(31 downto 0);
   type irq_addresses is array(0 to 1) of unsigned(1 downto 0);
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal io : buses := (others=>EMPTY_BUS);
   signal ipc_data, irq_in, ime, ie, flags : words(0 to 1);
   signal ipc_done, irq, unhalt, irq_idle : std_logic_vector(0 to 1);
   signal pulse : std_logic_vector(5 downto 0);
   signal dbg : std_logic_vector(31 downto 0);
   signal ipc_idle : std_logic;
   signal restore : std_logic := '0';
   signal cp_address : unsigned(5 downto 0) := (others=>'0');
   signal cp_irq_address : irq_addresses := (others=>(others=>'0'));
   signal cp_write : std_logic_vector(0 to 2) := (others=>'0');
   signal cp_data, cp_write_data : words(0 to 2) := (others=>(others=>'0'));
   signal cp_valid, cp_ready, cp_error : std_logic_vector(0 to 2);
begin
   clk <= not clk after 5 ns;
   irq_in(0) <= (16=>pulse(0),17=>pulse(1),18=>pulse(2),others=>'0');
   irq_in(1) <= (16=>pulse(3),17=>pulse(4),18=>pulse(5),others=>'0');
   gi : for i in 0 to 1 generate
      ic : entity work.nds_irq generic map(EXPERIMENTAL_CHECKPOINT=>true)
         port map(clk=>clk,ce=>'1',reset=>reset,gb_bus=>io(i),wired_out=>open,wired_done=>open,
            irq_in=>irq_in(i),cpu_irq=>irq(i),cpu_unhalt=>unhalt(i),dbg_ime=>ime(i),dbg_ie=>ie(i),dbg_if=>flags(i),
            checkpoint_idle=>irq_idle(i),checkpoint_address=>cp_irq_address(i),checkpoint_data=>cp_data(i+1),
            checkpoint_valid=>cp_valid(i+1),checkpoint_restore=>restore,checkpoint_write=>cp_write(i+1),
            checkpoint_write_data=>cp_write_data(i+1),checkpoint_restore_ready=>cp_ready(i+1),checkpoint_restore_error=>cp_error(i+1));
   end generate;
   dut : entity work.nds_ipc generic map(EXPERIMENTAL_CHECKPOINT=>true)
      port map(clk=>clk,reset=>reset,bus7=>io(0),wired_out7=>ipc_data(0),wired_done7=>ipc_done(0),
         irq7_sync=>pulse(0),irq7_sendempty=>pulse(1),irq7_recv=>pulse(2),
         bus9=>io(1),wired_out9=>ipc_data(1),wired_done9=>ipc_done(1),
         irq9_sync=>pulse(3),irq9_sendempty=>pulse(4),irq9_recv=>pulse(5),dbg_ipc=>dbg,checkpoint_idle=>ipc_idle,
         checkpoint_address=>cp_address,checkpoint_data=>cp_data(0),checkpoint_valid=>cp_valid(0),
         checkpoint_restore=>restore,checkpoint_write=>cp_write(0),checkpoint_write_data=>cp_write_data(0),
         checkpoint_restore_ready=>cp_ready(0),checkpoint_restore_error=>cp_error(0));
   stimulus : process
      file state_file, trace_file : text;
      variable line_buffer : line;
      variable image : words(0 to 41);
      variable expected, actual : std_logic_vector(239 downto 0);
      variable random : unsigned(31 downto 0) := to_unsigned(SEED+SCENARIO*7919,32);
      variable observations : natural := 0;
      variable mutation : std_logic_vector(31 downto 0);
      procedure step(n : positive := 1) is
      begin
         for k in 1 to n loop
            wait until rising_edge(clk); wait for 1 ns;
            if restore = '1' and reset = '1' then
               assert pulse="000000" report "IPC emitted an interrupt during restore" severity failure;
            end if;
         end loop;
      end;
      procedure configure(side : natural; a : natural; value : std_logic_vector(31 downto 0); rd : std_logic := '0'; be : std_logic_vector(3 downto 0) := "1111") is
      begin
         io(side).Adr<=std_logic_vector(to_unsigned(a,28));io(side).Din<=value;
         io(side).rnw<=rd;io(side).bEna<=be;io(side).ena<='1';
      end;
      procedure guest_write(side : natural; a : natural; value : std_logic_vector(31 downto 0)) is
      begin configure(side,a,value);step;io(side).ena<='0';step;end;
      procedure send_pair(n : positive; base : natural) is
      begin
         for k in 0 to n-1 loop
            if SCENARIO=5 then configure(0,16#188#,x"00000000");configure(1,16#188#,x"00000000");
            else
               configure(0,16#188#,std_logic_vector(to_unsigned(base+k,32) or unsigned'(x"A7000000")));
               configure(1,16#188#,std_logic_vector(to_unsigned(base+k,32) or unsigned'(x"A9000000")));
            end if;
            step;io(0).ena<='0';io(1).ena<='0';step;
         end loop;
      end;
      procedure pop_pair(n : positive; priming : boolean := false) is
      begin
         for k in 0 to n-1 loop
            configure(0,16#100000#,x"00000000",'1');configure(1,16#100000#,x"00000000",'1');wait for 1 ns;
            if priming and SCENARIO/=5 then
               assert unsigned(ipc_data(0))=(unsigned'(x"A9000000") or to_unsigned(k,32)) report "ARM7 prime pop sampling wrong" severity failure;
            end if;
            step;
            if priming and SCENARIO/=5 then
               assert unsigned(ipc_data(1))=(unsigned'(x"A7000000") or to_unsigned(k,32)) report "ARM9 prime pop sampling wrong" severity failure;
            end if;
            io(0).ena<='0';io(1).ena<='0';step;
         end loop;
      end;
      procedure advance_random is
      begin
         random:=random xor shift_left(random,13);random:=random xor shift_right(random,17);random:=random xor shift_left(random,5);
      end;
      procedure random_inputs is
         variable operation : natural;
      begin
         for side in 0 to 1 loop
            advance_random;operation:=to_integer(random(3 downto 0));
            case operation is
               when 0|1 => configure(side,16#180#,std_logic_vector(random),'0',std_logic_vector(random(7 downto 4)));
               when 2|3 => configure(side,16#184#,std_logic_vector(random),'0',std_logic_vector(random(7 downto 4)));
               when 4|5|6|7 => configure(side,16#188#,std_logic_vector(random));
               when 8|9|10|11 => configure(side,16#100000#,x"00000000",'1');
               when 12 => configure(side,16#214#,std_logic_vector(random),'0',std_logic_vector(random(7 downto 4)));
               when 13 => configure(side,16#210#,std_logic_vector(random),'0',std_logic_vector(random(7 downto 4)));
               when 14 => configure(side,16#208#,std_logic_vector(random),'0',std_logic_vector(random(7 downto 4)));
               when others => configure(side,16#184#,x"00000000",'1');io(side).ena<='0';
            end case;
         end loop;
      end;
      procedure select_word(a : natural) is
      begin
         if a<36 then cp_address<=to_unsigned(a,6);
         else cp_irq_address((a-36)/3)<=to_unsigned((a-36) mod 3,2);end if;
      end;
      function owner(a : natural) return natural is
      begin if a<36 then return 0;else return 1+(a-36)/3;end if;end;
      procedure load_word(a : natural; value : std_logic_vector(31 downto 0)) is
      begin
         select_word(a);cp_write_data(owner(a))<=value;cp_write(owner(a))<='1';
         step;cp_write<=(others=>'0');step(2+a mod 3);
      end;
      procedure load_image is
         variable a : natural;
         variable seen : std_logic_vector(41 downto 0):=(others=>'0');
      begin
         for slot in 0 to 41 loop
            case WRITE_ORDER is when 0=>a:=slot;when 1=>a:=41-slot;when others=>a:=(slot*5) mod 42;end case;
            load_word(a,image(a));seen(a):='1';
            if seen(35 downto 0)/=(35 downto 0=>'1') then
               assert cp_ready(0)='0' report "incomplete IPC restore accepted" severity failure;
            end if;
            if seen(38 downto 36)/="111" then assert cp_ready(1)='0' report "incomplete IRQ7 restore accepted" severity failure;end if;
            if seen(41 downto 39)/="111" then assert cp_ready(2)='0' report "incomplete IRQ9 restore accepted" severity failure;end if;
         end loop;
         step(3);
         assert cp_ready="111" and cp_error="000" report "complete IPC/IRQ restore never became ready" severity failure;
      end;
      procedure read_image(compare : boolean) is
      begin
         for a in 0 to 41 loop
            select_word(a);wait for 1 ns;
            -- A different RAM address must not expose the preceding word.
            if a >= 5 and a <= 19 then
               assert cp_valid(0)='0' report "stale IPC RAM address was accepted" severity failure;
            end if;
            for settle_cycle in 0 to 3 loop
               exit when cp_valid(owner(a))='1';step;
            end loop;
            assert cp_valid(owner(a))='1' report "IPC/IRQ capture unavailable at fixed point" severity failure;
            if compare then assert cp_data(owner(a))=image(a) report "IPC/IRQ restored word differs at " & integer'image(a) severity failure;
            else image(a):=cp_data(owner(a));end if;
         end loop;
         for a in 36 to 63 loop
            cp_address<=to_unsigned(a,6);wait for 1 ns;
            assert cp_valid(0)='0' and cp_data(0)=x"00000000" report "undefined IPC address exposed state" severity failure;
         end loop;
      end;
      procedure observe is
      begin
         actual:=ipc_data(0)&ipc_data(1)&dbg&pulse&ipc_done&flags(0)&flags(1)&ie(0)&ie(1)&ime(0)(0)&ime(1)(0)&irq&unhalt&"00";
         if RESTORING then
            assert not endfile(trace_file) report "IPC reference trace truncated" severity failure;
            readline(trace_file,line_buffer);hread(line_buffer,expected);
            assert actual=expected report "IPC continuation mismatch at observation " & integer'image(observations) &
               " actual=" & to_hstring(actual) & " expected=" & to_hstring(expected) severity failure;
         else hwrite(line_buffer,actual);writeline(trace_file,line_buffer);end if;
         observations:=observations+1;
      end;
   begin
      step(4);
      if RESTORING then
         file_open(state_file,"ipc.state",read_mode);
         for a in 0 to 41 loop readline(state_file,line_buffer);hread(line_buffer,image(a));end loop;
         assert endfile(state_file) report "unexpected IPC/IRQ image length" severity failure;file_close(state_file);
         restore<='1';step;
         -- Live bus noise is ignored under reset; only validated image writes
         -- may alter the device. All three component ports share reset here.
         configure(0,16#180#,x"00006300");configure(1,16#188#,x"BADBAD00");
         load_image;read_image(true);
         for invalid_case in 0 to 6 loop
            cp_write(0)<='1';cp_address<=to_unsigned(1,6);mutation:=(others=>'0');
            case invalid_case is
               when 0=>cp_address<=to_unsigned(36,6);
               when 1=>cp_address<=to_unsigned(63,6);
               when 2=>cp_address<=to_unsigned(0,6);mutation(18):='1';
               when 3=>mutation(4 downto 0):="10001";
               when 4=>mutation(9 downto 5):="10001";
               when 5=>mutation(14):='1';
               when others=>mutation(26):='1';
            end case;
            cp_write_data(0)<=mutation;step;cp_write<=(others=>'0');step;
            assert cp_error(0)='1' and cp_ready(0)='0' and cp_valid(0)='0' and cp_data(0)=x"00000000"
               report "invalid IPC restore was not rejected" severity failure;
            load_word(0,image(0));
            assert cp_error(0)='1' and cp_ready(0)='0' report "invalid IPC attempt silently recovered" severity failure;
            restore<='0';step;restore<='1';step;
            assert cp_ready="000" report "fresh IPC attempt retained coverage" severity failure;
            load_image;read_image(true);
         end loop;
         io<=(others=>EMPTY_BUS);restore<='0';reset<='0';step(5);
         read_image(true);
         for a in 0 to 35 loop
            restore<='1';select_word(a);cp_write_data(0)<=(others=>'0');cp_write(0)<='1';
            step;cp_write<=(others=>'0');
            assert cp_error(0)='1' and cp_ready(0)='0' and cp_valid(0)='0' report "live IPC restore was not rejected" severity failure;
            restore<='0';step(4);read_image(true);
         end loop;
         file_open(trace_file,"ipc.trace",read_mode);
      else
         reset<='0';step;
         for side in 0 to 1 loop
            guest_write(side,16#210#,x"00070000");guest_write(side,16#208#,x"00000001");
            guest_write(side,16#184#,x"00008404");
         end loop;
         guest_write(0,16#180#,x"00004300");guest_write(1,16#180#,x"00006C00");
         -- Initialize every physical FIFO cell through normal guest traffic.
         -- Unoccupied cells matter to the existing same-edge empty send/pop.
         send_pair(16,0);pop_pair(16,true);
         case SCENARIO is
            when 0=>send_pair(16,16#100#);send_pair(1,16#BAD#); -- full, errors
            when 1=>send_pair(13,16#200#);pop_pair(9);send_pair(10,16#300#); -- wrap
            when 2=>guest_write(0,16#214#,x"FFFFFFFF");guest_write(1,16#214#,x"FFFFFFFF"); -- empty, retained cells, no pending IRQ
            when 3=>
               send_pair(16,16#400#);
               for k in 1 to 15 loop configure(1,16#100000#,x"00000000",'1');step;io(1).ena<='0';step;end loop;
               for k in 1 to 6 loop configure(0,16#100000#,x"00000000",'1');step;io(0).ena<='0';step;end loop;
               guest_write(0,16#184#,x"00000404");guest_write(1,16#208#,x"00000000");
            when 4=>send_pair(8,16#500#);guest_write(0,16#184#,x"0000840C");
            when 5=>reset<='1';io(0).rst<='1';io(1).rst<='1';step(3);reset<='0';
            when 6=>for k in 1 to 2000 loop random_inputs;step;end loop;
         end case;
         io<=(others=>EMPTY_BUS);step(5);
         assert ipc_idle='1' and irq_idle="11" report "IPC/IRQ fixture failed to settle" severity failure;
         read_image(false);
         if SCENARIO=0 then assert image(1)(9 downto 0)="1000010000" report "fixture lacks two full queues" severity failure;end if;
         if SCENARIO=1 then assert image(1)(17 downto 14)<image(1)(13 downto 10) report "fixture lacks wrapped queue" severity failure;end if;
         if SCENARIO=2 then
            assert image(1)(9 downto 0)="0000000000" and image(4)=x"A7000000" and image(2)=x"A900000F" and image(3)=x"A700000F"
               report "fixture lacks empty queue retained data" severity failure;
         end if;
         if SCENARIO=5 then for a in 0 to 41 loop assert image(a)=x"00000000" report "fixture lacks all-zero IPC/IRQ image at " & integer'image(a) severity failure;end loop;end if;
         file_open(state_file,"ipc.state",write_mode);
         for a in 0 to 41 loop hwrite(line_buffer,image(a));writeline(state_file,line_buffer);end loop;file_close(state_file);
         file_open(trace_file,"ipc.trace",write_mode);
      end if;
      random:=to_unsigned(SEED+SCENARIO*7919,32);
      for i in 0 to 2047 loop
         if i=0 and SCENARIO=2 then
            configure(0,16#188#,x"13572468");configure(1,16#100000#,x"00000000",'1');
         elsif i<32 then
            configure(0,16#100000#,x"00000000",'1');configure(1,16#100000#,x"00000000",'1');
         else random_inputs;end if;
         cp_address<=(others=>'0');wait for 1 ns;
         if io(0).ena='1' or io(1).ena='1' then
            assert cp_valid(0)='0' and cp_data(0)=x"00000000" report "IPC capture exposed live bus state" severity failure;
         end if;
         observe;step;observe;
         if i=0 and SCENARIO=2 then
            assert ipc_data(1)=x"A7000000" report "empty simultaneous send/pop lost retained FIFO cell" severity failure;
         end if;
      end loop;
      io<=(others=>EMPTY_BUS);
      for k in 1 to 5 loop wait for 1 ns;observe;step;observe;end loop;
      if RESTORING then assert endfile(trace_file) report "IPC reference has trailing data" severity failure;end if;file_close(trace_file);
      report "CHECKPOINT_IPC_RESTORE_PASS restoring=" & boolean'image(RESTORING) & " scenario=" & integer'image(SCENARIO) &
         " order=" & integer'image(WRITE_ORDER) & " seed=" & integer'image(SEED) & " observations=" & integer'image(observations);
      std.env.stop;wait;
   end process;
   process begin wait for 2 ms;assert false report "IPC restore watchdog" severity failure;end process;
end;
