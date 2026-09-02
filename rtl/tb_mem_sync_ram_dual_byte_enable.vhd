-- Simulation-only portable stand-in for the vendor-backed MEM primitive.
-- It is intentionally absent from files.qip and exists only so nvc can analyze
-- product VHDL without an Altera simulation-library installation.
library ieee;
use ieee.std_logic_1164.all;

entity SyncRamDualByteEnable is
   generic
   (
      is_simu     : std_logic;
      is_cyclone5 : std_logic := '0';
      BYTE_WIDTH  : natural := 8;
      ADDR_WIDTH  : natural := 6;
      BYTES       : natural := 4
   );
   port
   (
      clk        : in std_logic;
      ce_a       : in std_logic;
      addr_a     : in natural range 0 to 2**ADDR_WIDTH - 1;
      datain_a0  : in std_logic_vector(BYTE_WIDTH-1 downto 0);
      datain_a1  : in std_logic_vector(BYTE_WIDTH-1 downto 0);
      datain_a2  : in std_logic_vector(BYTE_WIDTH-1 downto 0);
      datain_a3  : in std_logic_vector(BYTE_WIDTH-1 downto 0);
      dataout_a  : out std_logic_vector(BYTES*BYTE_WIDTH-1 downto 0);
      we_a       : in std_logic := '1';
      be_a       : in std_logic_vector(BYTES-1 downto 0);
      ce_b       : in std_logic;
      addr_b     : in natural range 0 to 2**ADDR_WIDTH - 1;
      datain_b0  : in std_logic_vector(BYTE_WIDTH-1 downto 0);
      datain_b1  : in std_logic_vector(BYTE_WIDTH-1 downto 0);
      datain_b2  : in std_logic_vector(BYTE_WIDTH-1 downto 0);
      datain_b3  : in std_logic_vector(BYTE_WIDTH-1 downto 0);
      dataout_b  : out std_logic_vector(BYTES*BYTE_WIDTH-1 downto 0);
      we_b       : in std_logic := '1';
      be_b       : in std_logic_vector(BYTES-1 downto 0)
   );
end entity;

architecture simulation of SyncRamDualByteEnable is
   type t_ram is array (0 to 2**ADDR_WIDTH - 1) of
      std_logic_vector(BYTES*BYTE_WIDTH-1 downto 0);
   signal ram : t_ram := (others => (others => '0'));
begin
   process (clk)
      variable data_a : std_logic_vector(BYTES*BYTE_WIDTH-1 downto 0);
      variable data_b : std_logic_vector(BYTES*BYTE_WIDTH-1 downto 0);
   begin
      if rising_edge(clk) then
         data_a := datain_a3 & datain_a2 & datain_a1 & datain_a0;
         data_b := datain_b3 & datain_b2 & datain_b1 & datain_b0;
         if ce_a = '1' then
            dataout_a <= ram(addr_a);
            if we_a = '1' then
               for lane in 0 to BYTES-1 loop
                  if be_a(lane) = '1' then
                     ram(addr_a)((lane+1)*BYTE_WIDTH-1 downto lane*BYTE_WIDTH) <=
                        data_a((lane+1)*BYTE_WIDTH-1 downto lane*BYTE_WIDTH);
                  end if;
               end loop;
            end if;
         end if;
         if ce_b = '1' then
            dataout_b <= ram(addr_b);
            if we_b = '1' then
               for lane in 0 to BYTES-1 loop
                  if be_b(lane) = '1' then
                     ram(addr_b)((lane+1)*BYTE_WIDTH-1 downto lane*BYTE_WIDTH) <=
                        data_b((lane+1)*BYTE_WIDTH-1 downto lane*BYTE_WIDTH);
                  end if;
               end loop;
            end if;
         end if;
      end if;
   end process;
end architecture;
