-- SPDX-License-Identifier: GPL-3.0-or-later
-- Engine B C/D mapping oracle: melonDS GPU::MapVRAM_CD maps eight 16 KiB
-- slots; ReadVRAM_BBG/BOBJ repeats that table throughout its 2 MiB aperture.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pnds_vram_map.all;

entity tb_nds_vram_cd_mirrors is end;
architecture test of tb_nds_vram_cd_mirrors is
 signal vramcnt : std_logic_vector(71 downto 0) := (others => '0');
 signal addr : unsigned(23 downto 0) := (others => '0');
 signal is_arm7 : std_logic := '0';
 signal hit : std_logic_vector(8 downto 0);
 signal offs : t_vram_offs;
 type integers is array(natural range <>) of integer;
 constant lanes : integers := (0,1,2,3,16#FFFE#,16#FFFF#,
                              16#10000#,16#1FFFC#,16#1FFFE#,16#1FFFF#);
 constant h_slots : std_logic_vector(7 downto 0) := "00110011";
 constant i_slots : std_logic_vector(7 downto 0) := "11001100";
begin
 dut : entity work.nds_vram_map port map(vramcnt,addr,is_arm7,hit,offs);
 process
  variable cfg : std_logic_vector(71 downto 0);
  variable a, aperture, checks : integer := 0;
  variable expected : boolean;
  type bank_words is array(0 to 65535) of integer range 0 to 65535;
  variable ram : bank_words := (others => 0);
  variable word : integer;
  procedure expect_address(address : integer; bank : integer; present : boolean) is
  begin
   addr <= to_unsigned(address,24); wait for 1 ns;
   assert (hit(bank)='1')=present
     report "C/D mapping mismatch bank=" & integer'image(bank) &
       " address=" & to_hstring(to_unsigned(address,24)) &
       " config=" & to_hstring(vramcnt) & " arm7=" & std_logic'image(is_arm7)
     severity failure;
   if present then
    assert to_integer(offs(bank))=address mod 131072
      report "C/D physical byte offset changed" severity failure;
   end if;
  end procedure;
 begin
  for bank in BANK_C to BANK_D loop
   if bank=BANK_C then aperture:=1; else aperture:=3; end if;
   for enabled in 0 to 1 loop
    for unused_ofs in 0 to 3 loop
     cfg := (others=>'0');
     cfg(bank*8+7 downto bank*8) :=
       std_logic_vector(to_unsigned(enabled*128+unused_ofs*8+4,8));
     vramcnt<=cfg;
     for cpu in 0 to 1 loop
      if cpu=0 then is_arm7<='0'; else is_arm7<='1'; end if;
      for region in 0 to 7 loop
       for mirror in 0 to 15 loop
        for lane in lanes'range loop
         a:=region*16#200000#+mirror*16#20000#+lanes(lane);
         expected:=enabled=1 and cpu=0 and region=aperture;
         expect_address(a,bank,expected);
         assert (hit and not std_logic_vector(to_unsigned(2**bank,9)))="000000000"
           report "disabled bank unexpectedly mapped" severity failure;
         checks:=checks+1;
        end loop;
       end loop;
      end loop;
     end loop;
    end loop;
   end loop;
   -- Texture and unmapped modes must still reject these CPU apertures.
   for mode in 3 to 7 loop
    if mode/=4 then
     cfg:=(others=>'0');
     cfg(bank*8+7 downto bank*8):=std_logic_vector(to_unsigned(128+mode,8));
     vramcnt<=cfg; is_arm7<='0';
     for mirror in 0 to 15 loop
      expect_address(aperture*16#200000#+mirror*16#20000#,bank,false);
     end loop;
    end if;
   end loop;
  end loop;

  -- Preserve overlapping bank hit vectors, including high mirrored addresses.
  cfg:=(others=>'0'); cfg(23 downto 16):=x"84";
  cfg(63 downto 56):=x"81"; cfg(71 downto 64):=x"81";
  vramcnt<=cfg; is_arm7<='0';
  for block16 in 0 to 127 loop
   expect_address(16#200000#+block16*16#4000#,BANK_C,true);
   assert hit(BANK_H)=h_slots(block16 mod 8) and hit(BANK_I)=i_slots(block16 mod 8)
     report "C/H/I overlap lost" severity failure;
  end loop;
  cfg:=(others=>'0'); cfg(31 downto 24):=x"84"; cfg(71 downto 64):=x"82";
  vramcnt<=cfg;
  for block16 in 0 to 127 loop
   expect_address(16#600000#+block16*16#4000#,BANK_D,true);
   assert hit(BANK_I)='1' report "D/I overlap lost" severity failure;
  end loop;

  -- Fire Emblem decompresses to 0x0623xxxx: halfword writes and history
  -- reads must share physical storage with 0x0621xxxx and every other alias.
  cfg:=(others=>'0'); cfg(23 downto 16):=x"84"; vramcnt<=cfg;
  for n in 0 to 31 loop
   expect_address(16#230000#+n*2,BANK_C,true);
   ram(to_integer(offs(BANK_C))/2):=n*997+1;
  end loop;
  for n in 0 to 31 loop
   expect_address(16#230000#+n*2,BANK_C,true);
   word:=ram(to_integer(offs(BANK_C))/2);
   expect_address(16#230040#+n*2,BANK_C,true);
   ram(to_integer(offs(BANK_C))/2):=word;
  end loop;
  for mirror in 0 to 15 loop
   for n in 0 to 31 loop
    expect_address(16#210040#+mirror*16#20000#+n*2,BANK_C,true);
    assert ram(to_integer(offs(BANK_C))/2)=n*997+1
      report "mirrored decompression backreference lost data" severity failure;
   end loop;
  end loop;
  report "PASS: C/D Engine B mirrors, enable/OFS/ARM7 exclusion, boundaries, " &
         "overlap, decompression backreferences; " & integer'image(checks) &
         " aperture checks" severity note;
  stop; wait;
 end process;
end;
