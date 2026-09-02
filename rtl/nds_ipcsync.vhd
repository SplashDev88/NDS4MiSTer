library ieee;
use ieee.std_logic_1164.all;

entity nds_ipcsync is
   port (
      clk        : in  std_logic;
      reset      : in  std_logic;
      arm9_we    : in  std_logic;
      arm9_wdata : in  std_logic_vector(31 downto 0);
      arm9_rdata : out std_logic_vector(31 downto 0);
      arm7_we    : in  std_logic;
      arm7_wdata : in  std_logic_vector(31 downto 0);
      arm7_rdata : out std_logic_vector(31 downto 0)
   );
end entity;

architecture rtl of nds_ipcsync is
   signal arm9_out : std_logic_vector(3 downto 0) := (others => '0');
   signal arm7_out : std_logic_vector(3 downto 0) := (others => '0');
begin
   process(clk)
   begin
      if rising_edge(clk) then
         if reset = '1' then
            arm9_out <= (others => '0');
            arm7_out <= (others => '0');
         else
            if arm9_we = '1' then
               arm9_out <= arm9_wdata(11 downto 8);
            end if;
            if arm7_we = '1' then
               arm7_out <= arm7_wdata(11 downto 8);
            end if;
         end if;
      end if;
   end process;

   -- Explicit list keeps this synthesizable source compatible with the
   -- VHDL-1993 frontend in Quartus 17.
   process(arm9_out, arm7_out)
      variable value9 : std_logic_vector(31 downto 0);
      variable value7 : std_logic_vector(31 downto 0);
   begin
      value9 := (others => '0');
      value7 := (others => '0');
      value9(11 downto 8) := arm9_out;
      value9(3 downto 0)  := arm7_out;
      value7(11 downto 8) := arm7_out;
      value7(3 downto 0)  := arm9_out;
      arm9_rdata <= value9;
      arm7_rdata <= value7;
   end process;
end architecture;
