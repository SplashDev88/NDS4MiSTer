-- SPDX-License-Identifier: GPL-3.0-or-later
-- Independent slot-table oracle from melonDS GPU::MapVRAM_H/MapVRAM_I and
-- ReadVRAM_BBG/ReadVRAM_BOBJ. Check all 2 MB aperture aliases, rejected regions,
-- mode/enable/ARM7 exclusion, byte lanes, and a decompression-style backreference.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pnds_vram_map.all;

entity tb_nds_vram_hi_mirrors is end;
architecture test of tb_nds_vram_hi_mirrors is
 signal vramcnt : std_logic_vector(71 downto 0) := (others => '0');
 signal addr : unsigned(23 downto 0) := (others => '0');
 signal is_arm7 : std_logic := '0';
 signal hit : std_logic_vector(8 downto 0);
 signal offs : t_vram_offs;
 type integers is array(natural range <>) of integer;
 constant lanes : integers := (0,1,2,3,16#3FFC#,16#3FFD#,16#3FFE#,16#3FFF#);
 constant h_bbg_slots : std_logic_vector(7 downto 0) := "00110011";
 constant i_bbg_slots : std_logic_vector(7 downto 0) := "11001100";
begin
 dut : entity work.nds_vram_map port map(vramcnt,addr,is_arm7,hit,offs);
 process
  variable cfg : std_logic_vector(71 downto 0);
  variable a, slot, expected_offset, checks : integer := 0;
  variable expected : boolean;
  type bank_bytes is array(0 to 32767) of integer range 0 to 255;
  variable ram : bank_bytes := (others => 0);
  procedure expect_address(address : integer; bank : integer; present : boolean;
                           offset : integer) is
  begin
   addr <= to_unsigned(address,24); wait for 1 ns;
   assert (hit(bank)='1')=present
     report "H/I mapping mismatch bank=" & integer'image(bank) &
       " address=" & to_hstring(to_unsigned(address,24)) &
       " config=" & to_hstring(vramcnt) & " arm7=" & std_logic'image(is_arm7)
     severity failure;
   if present then
    assert to_integer(offs(bank))=offset
      report "physical byte offset changed" severity failure;
   end if;
  end procedure;
 begin
  for bank in BANK_H to BANK_I loop
   for enabled in 0 to 1 loop
    for mode in 0 to 3 loop
     cfg := (others=>'0');
     -- Reserved OFS and MST bit 2 must not change H/I behavior.
     cfg(bank*8+7 downto bank*8) := std_logic_vector(to_unsigned(enabled*128+16#7C#+mode,8));
     vramcnt <= cfg;
     for cpu in 0 to 1 loop
      if cpu=0 then is_arm7<='0'; else is_arm7<='1'; end if;
      for region in 0 to 7 loop
       for block16 in 0 to 127 loop
        slot := block16 mod 8;
        for lane in lanes'range loop
         a := region*16#200000#+block16*16#4000#+lanes(lane);
         expected := false;
         if enabled=1 and cpu=0 then
          if bank=BANK_H then
           if mode=0 then expected := a>=16#898000# and a<16#8A0000#;
           elsif mode=1 then expected := region=1 and h_bbg_slots(slot)='1'; end if;
           expected_offset := a mod 32768;
          else
           if mode=0 then expected := a>=16#8A0000# and a<16#8A4000#;
           elsif mode=1 then expected := region=1 and i_bbg_slots(slot)='1';
           elsif mode=2 then expected := region=3; end if;
           expected_offset := a mod 16384;
          end if;
         end if;
         expect_address(a,bank,expected,expected_offset);
         assert (hit and not std_logic_vector(to_unsigned(2**bank,9)))="000000000"
           report "disabled bank unexpectedly mapped" severity failure;
         checks := checks+1;
        end loop;
       end loop;
      end loop;
     end loop;
    end loop;
   end loop;
  end loop;

  -- Simultaneously mapped banks keep OR-read/fanout-write hit information.
  cfg := (others=>'0'); cfg(23 downto 16):=x"84";
  cfg(63 downto 56):=x"81"; cfg(71 downto 64):=x"81";
  vramcnt<=cfg; is_arm7<='0';
  for block16 in 0 to 7 loop
   for lane in lanes'range loop
    a:=16#200000#+block16*16#4000#+lanes(lane);
    expect_address(a,BANK_C,true,a mod 131072);
    assert hit(BANK_H)=h_bbg_slots(block16) and hit(BANK_I)=i_bbg_slots(block16)
      report "H/I mirroring changed overlapping C-bank selection" severity failure;
   end loop;
  end loop;

  -- NSMB's 0x06210000 character destination aliases H's canonical 0x06200000.
  -- Model writes and LZ-style history reads using the actual decoder outputs.
  cfg := (others=>'0'); cfg(63 downto 56):=x"81";
  vramcnt<=cfg; is_arm7<='0';
  for byte_index in 0 to 31 loop
   expect_address(16#210000#+byte_index,BANK_H,true,byte_index);
   ram(to_integer(offs(BANK_H))) := (byte_index*17+3) mod 256;
  end loop;
  for byte_index in 0 to 31 loop
   expect_address(16#200000#+byte_index,BANK_H,true,byte_index);
   assert ram(to_integer(offs(BANK_H)))=(byte_index*17+3) mod 256
     report "canonical/mirrored data differ" severity failure;
  end loop;
  for byte_index in 0 to 31 loop
   expect_address(16#210000#+byte_index,BANK_H,true,byte_index);
   a := ram(to_integer(offs(BANK_H)));
   expect_address(16#210040#+byte_index,BANK_H,true,16#40#+byte_index);
   ram(to_integer(offs(BANK_H))) := a;
  end loop;
  for byte_index in 0 to 31 loop
   expect_address(16#200040#+byte_index,BANK_H,true,16#40#+byte_index);
   assert ram(to_integer(offs(BANK_H)))=(byte_index*17+3) mod 256
     report "mirrored backreference produced wrong bytes" severity failure;
  end loop;
  report "PASS: H/I mirrors, modes, ARM7 exclusion, byte/halfword lanes, backreference; " &
         integer'image(checks) & " decoder checks" severity note;
  stop; wait;
 end process;
end;
