-- SPDX-License-Identifier: GPL-3.0-or-later
-- Generated wrappers contain the actual accepted/candidate readback processes.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pProc_bus_gba.all;
entity tb_nds_sound_readback_equivalence is end entity;
architecture test of tb_nds_sound_readback_equivalence is
   signal bus7 : proc_bus_gb_type := ((others=>'0'),(others=>'0'),'1','0',"10","0000",'0');
   signal image : std_logic_vector(639 downto 0) := (others=>'0');
   signal old_data,new_data : std_logic_vector(31 downto 0);
   signal old_done,new_done : std_logic;
   type meta_values is array(natural range <>) of std_logic;
   constant meta : meta_values := ('U','X','Z','W','L','H','-');
   function advance(v : unsigned(31 downto 0)) return unsigned is
      variable x : unsigned(31 downto 0):=v;
   begin
      x:=x xor shift_left(x,13); x:=x xor shift_right(x,17);
      return x xor shift_left(x,5);
   end function;
begin
   ref_dut: entity work.sound_readback_reference port map(bus7,image,old_data,old_done);
   dut: entity work.sound_readback_candidate port map(bus7,image,new_data,new_done);
   stimulus: process
      variable checks : natural:=0;
      variable value : std_logic_vector(639 downto 0);
      variable address : std_logic_vector(27 downto 0);
      variable rng : unsigned(31 downto 0):=x"59b49287";
      procedure check(constant a : std_logic_vector(27 downto 0)) is
      begin
         bus7.Adr<=a;
         rng:=advance(rng);
         bus7.ena<=rng(0); bus7.rnw<=rng(1); bus7.acc<=std_logic_vector(rng(3 downto 2));
         bus7.bEna<=std_logic_vector(rng(7 downto 4));bus7.rst<=rng(8);
         bus7.Din<=std_logic_vector(rng);
         wait for 1 ns;
         assert old_data=new_data and old_done=new_done
            report "readback equivalence mismatch at check " & integer'image(checks) &
                   " address=" & to_hstring(a) & " old=" & to_hstring(old_data) & " new=" & to_hstring(new_data)
            severity failure;
         checks:=checks+1;
      end procedure;
   begin
      -- Every injected source bit, both one-hot and one-cold, through every
      -- byte offset in the complete claimed window. Padding bits are included.
      for bit_index in 0 to 639 loop
         for polarity in 0 to 1 loop
            if polarity=0 then value:=(others=>'0');value(bit_index):='1';
            else value:=(others=>'1');value(bit_index):='0';end if;
            image<=value;
            for offset in 0 to 511 loop
               check(std_logic_vector(to_unsigned(16#400#+offset,28)));
            end loop;
         end loop;
      end loop;
      -- Constant and mixed images, adjacent windows, every upper decode bit.
      for pattern in 0 to 9 loop
         for chunk in 0 to 19 loop
            rng:=advance(rng);
            if pattern=0 then value(chunk*32+31 downto chunk*32):=(others=>'0');
            elsif pattern=1 then value(chunk*32+31 downto chunk*32):=(others=>'1');
            else value(chunk*32+31 downto chunk*32):=std_logic_vector(rng);end if;
         end loop;
         image<=value;
         for offset in 0 to 511 loop
            check(std_logic_vector(to_unsigned(16#200#+offset,28)));
            check(std_logic_vector(to_unsigned(16#400#+offset,28)));
            check(std_logic_vector(to_unsigned(16#600#+offset,28)));
            for high_bit in 9 to 27 loop
               address:=std_logic_vector(to_unsigned(16#400#+offset,28));
               address(high_bit):=not address(high_bit);check(address);
            end loop;
         end loop;
      end loop;
      -- Keep the original numeric_std index/default behavior for nonbinary
      -- address values. Stored state remains binary, as on physical registers.
      for bit_index in 0 to 27 loop
         for m in meta'range loop
            for offset in 0 to 511 loop
               address:=std_logic_vector(to_unsigned(16#400#+offset,28));
               address(bit_index):=meta(m);check(address);
            end loop;
         end loop;
      end loop;
      for iteration in 1 to 20000 loop
         for chunk in 0 to 19 loop
            rng:=advance(rng); value(chunk*32+31 downto chunk*32):=std_logic_vector(rng);
         end loop;
         image<=value;rng:=advance(rng);
         if iteration mod 4=0 then address:=std_logic_vector(rng(27 downto 0));
         else address:=std_logic_vector(to_unsigned(16#400#,28) or resize(rng(8 downto 0),28));end if;
         check(address);
      end loop;
      report "PASS: actual-process readback equivalence checks=" & integer'image(checks) severity note;
      std.env.stop;wait;
   end process;
end architecture;
