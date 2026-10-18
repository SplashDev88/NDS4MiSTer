-- SPDX-License-Identifier: GPL-3.0-or-later
-- Read-only CPU checkpoint mailbox. No device writes or restore path.
-- Common reset must span at least three edges of BOTH continuously running
-- clocks. Addresses and replies are bundled data held through a four-phase
-- request/ack handshake. CDC timing constraints still belong to integration.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity nds_checkpoint_read_port is
  generic (TIMEOUT_CYCLES : positive := 1024;
           RAM_READ_LATENCY : natural range 0 to 1 := 0;
           WORD_COUNT : positive range 1 to 256 := 256);
  port (
    clk, cpu_clk, reset : in std_logic;
    permit : in std_logic;
    epoch : in unsigned(31 downto 0);
    read_request : in std_logic;
    read_address : in std_logic_vector(7 downto 0);
    read_epoch : in unsigned(31 downto 0);
    ready, done, error : out std_logic;
    data : out std_logic_vector(31 downto 0);
    result_epoch : out unsigned(31 downto 0);
    cpu_paused : in std_logic;
    cpu_address : out std_logic_vector(7 downto 0);
    cpu_data : in std_logic_vector(31 downto 0);
    cpu_valid : in std_logic
  );
end;

architecture rtl of nds_checkpoint_read_port is
  type phase_type is (DRAIN, IDLE, WAIT_REPLY, CANCEL_REPLY, WAIT_LOW);
  type cpu_phase_type is (CPU_IDLE, CPU_RAM_WAIT, CPU_SAMPLE, CPU_REPLY);
  signal phase : phase_type := DRAIN;
  signal cpu_phase : cpu_phase_type := CPU_IDLE;
  signal request_i, req_meta, req_sync, ack, ack_meta, ack_sync : std_logic := '0';
  signal address_hold : std_logic_vector(7 downto 0) := (others => '0');
  signal reply_hold, data_i : std_logic_vector(31 downto 0) := (others => '0');
  signal reply_error, error_i : std_logic := '1';
  signal epoch_hold : unsigned(31 downto 0) := (others => '0');
  signal elapsed : natural range 0 to TIMEOUT_CYCLES - 1 := 0;
  attribute async_reg : string;
  attribute async_reg of req_meta, req_sync, ack_meta, ack_sync : signal is "true";
begin
  ready <= '1' when phase = IDLE else '0';
  result_epoch <= epoch_hold;
  -- A concurrent cancellation/lease expiry invalidates even a reply that
  -- reached the control domain on that same edge.
  error <= error_i or not permit when epoch = epoch_hold else '1';
  data <= data_i when error_i = '0' and permit = '1' and epoch = epoch_hold
          else (others => '0');

  process(clk)
  begin
    if rising_edge(clk) then
      ack_meta <= ack;
      ack_sync <= ack_meta;
      done <= '0';
      if reset = '1' then
        phase <= DRAIN;
        request_i <= '0';
        ack_meta <= '0'; ack_sync <= '0';
        elapsed <= 0;
        error_i <= '1'; data_i <= (others => '0');
        address_hold <= (others => '0'); epoch_hold <= (others => '0');
      else
        case phase is
          when DRAIN =>
            if ack_sync = '0' then
              if read_request = '0' then phase <= IDLE; else phase <= WAIT_LOW; end if;
            end if;
          when IDLE =>
            if read_request = '1' then
              address_hold <= read_address;
              epoch_hold <= read_epoch;
              elapsed <= 0;
              error_i <= '1'; data_i <= (others => '0');
              if permit = '1' and epoch = read_epoch and unsigned(read_address) < WORD_COUNT then
                request_i <= '1'; phase <= WAIT_REPLY;
              else
                done <= '1'; phase <= WAIT_LOW;
              end if;
            end if;
          when WAIT_REPLY =>
            if permit = '0' or epoch /= epoch_hold then
              done <= '1'; error_i <= '1'; phase <= CANCEL_REPLY;
            elsif ack_sync = '1' then
              data_i <= reply_hold; error_i <= reply_error;
              done <= '1'; request_i <= '0'; phase <= DRAIN;
            elsif elapsed = TIMEOUT_CYCLES - 1 then
              done <= '1'; error_i <= '1'; phase <= CANCEL_REPLY;
            else
              elapsed <= elapsed + 1;
            end if;
          when CANCEL_REPLY =>
            -- A timed-out/stopped clock can return late. Finish the high
            -- phase before lowering request; never reuse its acknowledgement.
            if ack_sync = '1' then request_i <= '0'; phase <= DRAIN; end if;
          when WAIT_LOW =>
            if read_request = '0' then phase <= IDLE; end if;
        end case;
      end if;
    end if;
  end process;

  process(cpu_clk)
  begin
    if rising_edge(cpu_clk) then
      req_meta <= request_i;
      req_sync <= req_meta;
      if reset = '1' then
        req_meta <= '0'; req_sync <= '0'; ack <= '0';
        cpu_phase <= CPU_IDLE; cpu_address <= (others => '0');
        reply_hold <= (others => '0'); reply_error <= '1';
      else
        case cpu_phase is
          when CPU_IDLE =>
            if req_sync = '1' then
              cpu_address <= address_hold;
              if RAM_READ_LATENCY = 1 then cpu_phase <= CPU_RAM_WAIT;
              else cpu_phase <= CPU_SAMPLE; end if;
            end if;
          when CPU_RAM_WAIT =>
            -- Address was registered at the previous edge. Let a synchronous
            -- RAM update its output before the reply samples that output.
            cpu_phase <= CPU_SAMPLE;
          when CPU_SAMPLE =>
            -- Address was registered on the preceding CPU edge. The CPU's
            -- checkpoint mux is combinational; state is stable while held.
            reply_hold <= cpu_data;
            reply_error <= '1';
            if unsigned(cpu_address) < WORD_COUNT then reply_error <= not (cpu_paused and cpu_valid); end if;
            ack <= '1'; cpu_phase <= CPU_REPLY;
          when CPU_REPLY =>
            if req_sync = '0' then ack <= '0'; cpu_phase <= CPU_IDLE; end if;
        end case;
      end if;
    end if;
  end process;
end;
