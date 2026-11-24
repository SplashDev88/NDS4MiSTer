-- SPDX-License-Identifier: GPL-3.0-or-later
-- Receive a held event from the slower, related clock. Both sides of the
-- edge detector are receiving-clock registers: never combine a raw source
-- event with its delayed copy. Two capture stages also let the accompanying
-- held payload settle before the consumer observes the completion.
-- Pulses must be high/low for at least one source cycle; toggles must be
-- separated by at least two receiving cycles. Payload remains held until
-- retirement (or the next streamed RAM beat). This is not an async FIFO.
library ieee;
use ieee.std_logic_1164.all;
entity nds_related_clock_event is
   generic (WIDTH : positive := 1; TOGGLE_EVENT : boolean := false);
   port (clk, reset : in std_logic;
         event_in : in std_logic_vector(WIDTH-1 downto 0);
         pulse_out : out std_logic_vector(WIDTH-1 downto 0));
end entity;
architecture rtl of nds_related_clock_event is
   signal capture, settled, history : std_logic_vector(WIDTH-1 downto 0) := (others=>'0');
begin
   process(clk)
   begin
      if rising_edge(clk) then
         if reset='1' then
            -- Absorb the current level, including a retained completion toggle,
            -- so reset/reload does not manufacture a transaction.
            capture<=event_in; settled<=event_in; history<=event_in;
         else
            capture<=event_in; settled<=capture; history<=settled;
         end if;
      end if;
   end process;
   pulse_out <= (others=>'0') when reset='1' else
                settled xor history when TOGGLE_EVENT else
                settled and not history;
end architecture;
