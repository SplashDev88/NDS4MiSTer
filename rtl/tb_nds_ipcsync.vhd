library ieee;
use ieee.std_logic_1164.all;
use std.env.all;

entity tb_nds_ipcsync is
end entity;

architecture sim of tb_nds_ipcsync is
   signal clk        : std_logic := '0';
   signal reset      : std_logic := '1';
   signal arm9_we    : std_logic := '0';
   signal arm9_wdata : std_logic_vector(31 downto 0) := (others => '0');
   signal arm9_rdata : std_logic_vector(31 downto 0);
   signal arm7_we    : std_logic := '0';
   signal arm7_wdata : std_logic_vector(31 downto 0) := (others => '0');
   signal arm7_rdata : std_logic_vector(31 downto 0);
begin
   clk <= not clk after 5 ns;

   dut : entity work.nds_ipcsync
      port map (
         clk => clk, reset => reset,
         arm9_we => arm9_we, arm9_wdata => arm9_wdata, arm9_rdata => arm9_rdata,
         arm7_we => arm7_we, arm7_wdata => arm7_wdata, arm7_rdata => arm7_rdata
      );

   process
      procedure write9(constant value : std_logic_vector(31 downto 0)) is
      begin
         arm9_wdata <= value; arm9_we <= '1';
         wait until rising_edge(clk); wait for 1 ns;
         arm9_we <= '0';
      end procedure;
      procedure write7(constant value : std_logic_vector(31 downto 0)) is
      begin
         arm7_wdata <= value; arm7_we <= '1';
         wait until rising_edge(clk); wait for 1 ns;
         arm7_we <= '0';
      end procedure;
      procedure expect(
         constant value9 : std_logic_vector(31 downto 0);
         constant value7 : std_logic_vector(31 downto 0)) is
      begin
         assert arm9_rdata = value9
            report "ARM9 IPCSYNC read mismatch" severity failure;
         assert arm7_rdata = value7
            report "ARM7 IPCSYNC read mismatch" severity failure;
      end procedure;
   begin
      wait until rising_edge(clk); wait until rising_edge(clk);
      reset <= '0'; wait for 1 ns;
      expect(x"00000000", x"00000000");

      write7(x"00000900"); expect(x"00000009", x"00000900");
      write9(x"00000A00"); expect(x"00000A09", x"0000090A");
      write7(x"00000B00"); expect(x"00000A0B", x"00000B0A");
      write9(x"00000C00"); expect(x"00000C0B", x"00000B0C");
      write7(x"00000D00"); expect(x"00000C0D", x"00000D0C");
      write9(x"00000000"); expect(x"0000000D", x"00000D00");

      report "PASS: ARM9/ARM7 IPCSYNC handshake matches melonDS trace" severity note;
      stop;
      wait;
   end process;
end architecture;
