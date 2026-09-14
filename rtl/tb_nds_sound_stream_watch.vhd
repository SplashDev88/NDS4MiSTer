library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_nds_sound_stream_watch is end entity;
architecture test of tb_nds_sound_stream_watch is
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal permit9, permit7 : std_logic := '1';
   signal req9, done9, req7, done7 : std_logic := '0';
   signal rnw9, rnw7 : std_logic := '0';
   signal addr9, addr7 : std_logic_vector(21 downto 2) := (others => '0');
   signal be9, be7 : std_logic_vector(3 downto 0) := "1111";
   signal diagnostic : std_logic_vector(63 downto 0);
begin
   clk <= not clk after 5 ns;
   dut : entity work.nds_sound_stream_watch
      generic map (WINDOW0_FIRST_WORD=>100, WINDOW0_WORDS=>4,
                   WINDOW1_FIRST_WORD=>200, WINDOW1_WORDS=>2)
      port map (clk,reset,permit9,req9,rnw9,done9,addr9,be9,
                permit7,req7,rnw7,done7,addr7,be7,diagnostic);
   process
      procedure cycle is begin wait until rising_edge(clk);wait for 1 ns;end;
      procedure check(n9,n7:natural) is
      begin
         assert diagnostic(63 downto 60)=x"E" and diagnostic(31 downto 28)=x"F"
            report "wrong stream counter tags" severity failure;
         assert unsigned(diagnostic(59 downto 32))=n9 and unsigned(diagnostic(27 downto 0))=n7
            report "completed-byte count mismatch" severity failure;
      end;
   begin
      cycle;reset<='0';cycle;check(0,0);
      addr9<=std_logic_vector(to_unsigned(100,20));req9<='1';cycle;req9<='0';
      -- Change every live request attribute before completion. Only the
      -- original accepted four-byte write is allowed to count.
      addr9<=std_logic_vector(to_unsigned(999,20));be9<="0000";rnw9<='1';permit9<='0';
      cycle;cycle;check(0,0);done9<='1';cycle;done9<='0';check(4,0);
      done9<='1';cycle;done9<='0';check(4,0); -- duplicate completion cannot count

      permit9<='1';rnw9<='0';be9<="1010";
      addr9<=std_logic_vector(to_unsigned(103,20));req9<='1';cycle;req9<='0';
      done9<='1';cycle;done9<='0';check(6,0); -- last word inside first window
      addr9<=std_logic_vector(to_unsigned(104,20));req9<='1';cycle;req9<='0';
      done9<='1';cycle;done9<='0';check(6,0); -- exclusive end
      addr9<=std_logic_vector(to_unsigned(99,20));req9<='1';cycle;req9<='0';
      done9<='1';cycle;done9<='0';check(6,0); -- before start

      addr7<=std_logic_vector(to_unsigned(200,20));rnw7<='1';req7<='1';cycle;req7<='0';
      done7<='1';cycle;done7<='0';check(6,0); -- reads are not writes
      rnw7<='0';permit7<='0';req7<='1';cycle;req7<='0';permit7<='1';
      done7<='1';cycle;done7<='0';check(6,0); -- permission captured at request

      addr9<=std_logic_vector(to_unsigned(200,20));be9<="1111";
      addr7<=std_logic_vector(to_unsigned(201,20));be7<="0100";
      req9<='1';req7<='1';cycle;req9<='0';req7<='0';
      done9<='1';done7<='1';cycle;done9<='0';done7<='0';check(10,1);

      -- Retire one operation while accepting another on the same edge.
      addr9<=std_logic_vector(to_unsigned(100,20));be9<="0001";req9<='1';cycle;req9<='0';
      addr9<=std_logic_vector(to_unsigned(201,20));be9<="1110";req9<='1';done9<='1';
      cycle;req9<='0';done9<='0';check(11,1);
      cycle;done9<='1';cycle;done9<='0';check(14,1);

      req9<='1';req7<='1';cycle;req9<='0';req7<='0';reset<='1';cycle;
      reset<='0';done9<='1';done7<='1';cycle;done9<='0';done7<='0';check(0,0);
      report "PASS: completed writes, byte enables, window boundaries, captured metadata, dual ports, exclusion, reset and duplicate completion";
      std.env.stop;
      wait;
   end process;
end architecture;
