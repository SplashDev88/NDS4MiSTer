library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pProc_bus_gba.all;

-- Writes melonDS direct-boot state into both reused GBA CPU savestate ports,
-- then releases the CPUs together. The buses are reset first so repeated menu
-- toggles cannot inherit stale banked registers from a previous run.
entity nds_cpu_boot_sequencer is
   port (
      clk, reset, descriptor_valid : in std_logic;
      arm9_entry, arm7_entry : in std_logic_vector(31 downto 0);
      arm9_current_sp, arm9_irq_sp, arm9_saved_sp : in std_logic_vector(31 downto 0);
      arm7_current_sp, arm7_irq_sp, arm7_saved_sp : in std_logic_vector(31 downto 0);
      initial_cpsr : in std_logic_vector(31 downto 0);
      cpu_reset : out std_logic;
      boot_ready : out std_logic;
      save9, save7 : inout proc_bus_gb_type
   );
end entity;

architecture rtl of nds_cpu_boot_sequencer is
   type state_t is (CLEAR_STATE, WRITE_STATE, LOAD_STATE, RUNNING);
   type address_array_t is array (0 to 8) of natural range 0 to 46;
   constant WRITE_ADDRESS : address_array_t :=
      (0, 13, 14, 15, 16, 17, 24, 34, 46);
   signal state : state_t := CLEAR_STATE;
   signal write_index : natural range 0 to 8 := 0;

   function write_value(
      index : natural;
      entry, current_sp, irq_sp, saved_sp, cpsr : std_logic_vector(31 downto 0))
      return std_logic_vector is
   begin
      case index is
         when 0 | 1 | 3 => return entry;
         when 2 => return current_sp;
         when 4 => return std_logic_vector(unsigned(entry) + 8);
         when 5 => return cpsr;
         when 6 => return saved_sp;
         when 7 => return irq_sp;
         when others => return x"00000CC0";
      end case;
   end function;
begin
   save9.Dout <= (others => 'Z');
   save9.done <= 'Z';
   save9.acc <= "ZZ";
   save7.Dout <= (others => 'Z');
   save7.done <= 'Z';
   save7.acc <= "ZZ";

   save9.Adr <= std_logic_vector(to_unsigned(WRITE_ADDRESS(write_index), save9.Adr'length))
      when state = WRITE_STATE else (others => 'Z');
   save7.Adr <= std_logic_vector(to_unsigned(WRITE_ADDRESS(write_index), save7.Adr'length))
      when state = WRITE_STATE else (others => 'Z');
   save9.Din <= write_value(write_index, arm9_entry, arm9_current_sp,
                            arm9_irq_sp, arm9_saved_sp, initial_cpsr)
      when state = WRITE_STATE else (others => 'Z');
   save7.Din <= write_value(write_index, arm7_entry, arm7_current_sp,
                            arm7_irq_sp, arm7_saved_sp, initial_cpsr)
      when state = WRITE_STATE else (others => 'Z');
   save9.rnw <= '0' when state = WRITE_STATE else 'Z';
   save7.rnw <= '0' when state = WRITE_STATE else 'Z';
   save9.ena <= '1' when state = WRITE_STATE else 'Z';
   save7.ena <= '1' when state = WRITE_STATE else 'Z';
   save9.bEna <= "1111" when state = WRITE_STATE else "ZZZZ";
   save7.bEna <= "1111" when state = WRITE_STATE else "ZZZZ";
   save9.rst <= '1' when state = CLEAR_STATE else '0';
   save7.rst <= '1' when state = CLEAR_STATE else '0';

   cpu_reset <= '0' when state = RUNNING else '1';
   boot_ready <= '1' when state = RUNNING else '0';

   process(clk)
   begin
      if rising_edge(clk) then
         if reset = '1' or descriptor_valid = '0' then
            state <= CLEAR_STATE;
            write_index <= 0;
         else
            case state is
               when CLEAR_STATE =>
                  -- eProcReg_gba clears every backing register on this edge.
                  state <= WRITE_STATE;
                  write_index <= 0;
               when WRITE_STATE =>
                  if write_index = WRITE_ADDRESS'high then
                     state <= LOAD_STATE;
                  else
                     write_index <= write_index + 1;
                  end if;
               when LOAD_STATE =>
                  -- gba_cpu samples the completed backing registers while its
                  -- synchronous reset is still asserted on this edge.
                  state <= RUNNING;
               when RUNNING =>
                  null;
            end case;
         end if;
      end if;
   end process;
end architecture;
