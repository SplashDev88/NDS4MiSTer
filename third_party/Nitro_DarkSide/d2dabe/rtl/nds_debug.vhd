-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- On-FPGA debug unit, modelled on the IS-NITRO-DEBUGGER feature set: halt/run,
-- cycle stepping, PC breakpoints, full register read-back and memory peek for
-- both CPUs. Commands arrive through a DDR3 mailbox (ddram ch4, otherwise
-- unused) so the HPS side is just devmem - no JTAG, no Quartus on the host.
--
-- Why this exists: the previous diagnostic channel was six 18-bit lanes sampled
-- once per frame, which cost ten Quartus builds and still produced a wrong
-- conclusion. A halt + breakpoint + peek lets one build answer an unbounded
-- number of questions, including reading SDRAM main RAM (invisible to the HPS)
-- and walking NitroSDK's thread queue to name a blocked wait.
--
-- Halting reuses each core's existing WFI/HALTCNT machinery rather than adding
-- a pipeline stall: `new_halt` sets the internal decode_halt latch and has
-- priority over `unhalt`, so holding it high is a level halt the game cannot
-- escape (nds_cpu9.vhd:921, gba_cpu.vhd equivalents). Peripherals keep running
-- - this is a debugger halt, not a whole-machine freeze, because clk1x also
-- clocks DDRAM and cannot be gated.
--
-- Command word (from the mailbox): op(7 downto 0) + arg(31 downto 0).
--   op(7)     CPU select: '0' = ARM9, '1' = ARM7
--   op(6..0)  command:
--     0x01 HALT     hold the CPU
--     0x02 RUN      release it
--     0x03 RUNCYC   release for arg clk1x cycles, then hold again
--     0x04 BRKSET   arm a PC breakpoint at arg (halts on match)
--     0x05 BRKCLR   disarm it
--     0x06 RDREG    read register arg(4 downto 0): 0..15 = r0..r15 in the
--                   CPU's current mode, 16 = CPSR. Both cores carry the mux
--                   (nds_cpu9/gba_cpu dbg_regsel/dbg_regval). Room for it came
--                   from dropping ascal via MISTER_DISABLE_ADAPTIVE - 2178 ALMs
--                   of video scaler that a diagnostic image does not use.
--     0x07 PEEK     read the memory word at arg through the CPU's bus
--     0x08 STATUS   {.., bp_hit7, bp_hit9, held7, held9}
-- Every command answers with exactly one rsp_stb pulse so the mailbox can pair
-- request and response by sequence number.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity nds_debug is
   generic
   (
      -- '1': both cores leave reset ALREADY HELD, so a debugger can arm
      -- breakpoints before the first instruction ever retires. Without this the
      -- boot FSM's B_RUN drops resetCpu and the game is millions of
      -- instructions in before a host can attach, which makes a from-reset
      -- differential against the sim impossible. Diagnostic images only: with
      -- this set the core does nothing at all until a RUN command arrives.
      BOOT_HOLD : std_logic := '0'
   );
   port
   (
      clk       : in  std_logic;
      reset     : in  std_logic;

      -- mailbox command/response (ddram ch4 pager lives in NDS.sv)
      cmd_stb   : in  std_logic;                       -- one cycle per command
      cmd_op    : in  std_logic_vector(7 downto 0);
      cmd_arg   : in  std_logic_vector(31 downto 0);
      rsp_data  : out std_logic_vector(31 downto 0) := (others => '0');
      rsp_stb   : out std_logic := '0';

      -- CPU hold/release, OR'd into each core's new_halt/unhalt in nds_top
      hold9     : out std_logic := '0';
      rel9      : out std_logic := '0';
      hold7     : out std_logic := '0';
      rel7      : out std_logic := '0';

      -- one-cycle pulse: restart nds_top's boot FSM (loader included) without
      -- reloading the core or the cart, so repeated from-reset probes need no
      -- OSD interaction
      boot_rst  : out std_logic := '0';

      -- register read-back (regsel drives both cores' debug mux)
      regsel    : out unsigned(4 downto 0) := (others => '0');
      regval9   : in  std_logic_vector(31 downto 0);
      regval7   : in  std_logic_vector(31 downto 0);

      -- live architectural PCs, used for breakpoint compare
      pc9       : in  std_logic_vector(31 downto 0);
      pc7       : in  std_logic_vector(31 downto 0);

      -- live snapshot of the ARM9 memory path's internal FSMs, returned by
      -- op 0x0A. A CPU that has stopped retiring instructions is either
      -- waiting on one of these or is not waiting on memory at all, and that
      -- distinction is not otherwise observable on hardware.
      probe     : in  std_logic_vector(31 downto 0) := (others => '0');
      -- op 0x0D: nds_card's FSM. Nothing else in this unit can see the card, so
      -- a hang waiting on a card transfer looks identical to a healthy core.
      cardstat  : in  std_logic_vector(31 downto 0) := (others => '0');
      -- op 0x0E: IPC sync + FIFO depths, invisible to peek (IO space)
      ipcstat   : in  std_logic_vector(31 downto 0) := (others => '0');

      -- op 0x0F: nds_perf's vblank snapshot, arg = 0..7 selects the counter.
      -- perf_index is driven straight off cmd_arg rather than latched, so the
      -- counter block's read mux settles while the command is still being
      -- decoded and `answer` samples a stable word - the same trick op 0x0C
      -- uses for the six interrupt registers, just muxed on the far side.
      perfstat  : in  std_logic_vector(31 downto 0) := (others => '0');
      perf_index : out std_logic_vector(2 downto 0) := (others => '0');

      -- interrupt controller state for both CPUs, returned by op 0x0C with
      -- arg = 0..5. PEEK cannot read these: it borrows the ARM9 main-RAM
      -- channel, so an 0x040001xx address aliases into RAM and returns garbage.
      irq9_ime  : in  std_logic_vector(31 downto 0) := (others => '0');
      irq9_ie   : in  std_logic_vector(31 downto 0) := (others => '0');
      irq9_if   : in  std_logic_vector(31 downto 0) := (others => '0');
      irq7_ime  : in  std_logic_vector(31 downto 0) := (others => '0');
      irq7_ie   : in  std_logic_vector(31 downto 0) := (others => '0');
      irq7_if   : in  std_logic_vector(31 downto 0) := (others => '0');

      -- memory peek, muxed onto the ARM9 main-RAM channel in nds_top
      pk_ena    : out std_logic := '0';
      pk_addr   : out std_logic_vector(31 downto 0) := (others => '0');
      pk_done   : in  std_logic;
      pk_data   : in  std_logic_vector(31 downto 0)
   );
end entity;

architecture arch of nds_debug is

   type t_state is (IDLE, REG_WAIT, PEEK_REQ, PEEK_WAIT, RESPOND);
   signal state : t_state := IDLE;

   -- power-up value matters as much as the reset value: the cores must already
   -- be held the first time the boot FSM releases resetCpu
   signal held9, held7   : std_logic := BOOT_HOLD;
   signal bp9_en, bp7_en : std_logic := '0';
   signal bp9, bp7       : std_logic_vector(31 downto 0) := (others => '0');
   signal hit9, hit7     : std_logic := '0';

   -- RUNCYC countdown, per CPU
   signal run9_cnt, run7_cnt : unsigned(23 downto 0) := (others => '0');
   signal run9_act, run7_act : std_logic := '0';

   signal sel_cpu : std_logic := '0';
   signal answer  : std_logic_vector(31 downto 0) := (others => '0');

   -- A PEEK at an address the ARM9 bus never answers for would otherwise park
   -- this unit in PEEK_WAIT forever, taking every later command with it. Give
   -- up and report a sentinel instead; the mailbox in NDS.sv carries its own
   -- outer timeout for the same reason.
   signal pk_timer : unsigned(15 downto 0) := (others => '0');

begin

   -- Hold is a level: while asserted nds_top drives the core's new_halt, which
   -- outranks unhalt, so an IRQ cannot resume a debugger-halted CPU.
   hold9 <= held9;
   hold7 <= held7;

   -- combinational, so nds_perf's mux has settled by the time the op handler
   -- samples perfstat into `answer`
   perf_index <= cmd_arg(2 downto 0);

   process (clk)
      variable op : std_logic_vector(6 downto 0);
   begin
      if rising_edge(clk) then

         rsp_stb  <= '0';
         rel9     <= '0';
         rel7     <= '0';
         pk_ena   <= '0';
         boot_rst <= '0';

         if (reset = '1') then
            state    <= IDLE;
            held9    <= BOOT_HOLD;
            held7    <= BOOT_HOLD;
            bp9_en   <= '0';
            bp7_en   <= '0';
            hit9     <= '0';
            hit7     <= '0';
            run9_act <= '0';
            run7_act <= '0';
         else

            -- ---------------- breakpoints ----------------
            -- Compared against the architectural PC the cores already export.
            -- A hit latches and holds; it is cleared by the next RUN.
            if (bp9_en = '1' and held9 = '0' and pc9 = bp9) then
               held9    <= '1';
               hit9     <= '1';
               run9_act <= '0';
            end if;
            if (bp7_en = '1' and held7 = '0' and pc7 = bp7) then
               held7    <= '1';
               hit7     <= '1';
               run7_act <= '0';
            end if;

            -- ---------------- RUNCYC countdown ----------------
            if (run9_act = '1') then
               if (run9_cnt = 0) then
                  run9_act <= '0';
                  held9    <= '1';
               else
                  run9_cnt <= run9_cnt - 1;
               end if;
            end if;
            if (run7_act = '1') then
               if (run7_cnt = 0) then
                  run7_act <= '0';
                  held7    <= '1';
               else
                  run7_cnt <= run7_cnt - 1;
               end if;
            end if;

            -- ---------------- command dispatch ----------------
            case state is

               when IDLE =>
                  if (cmd_stb = '1') then
                     op      := cmd_op(6 downto 0);
                     sel_cpu <= cmd_op(7);
                     answer  <= (others => '0');

                     case op is
                        when "0000001" =>            -- HALT
                           if (cmd_op(7) = '0') then
                              held9 <= '1'; run9_act <= '0';
                           else
                              held7 <= '1'; run7_act <= '0';
                           end if;
                           state <= RESPOND;

                        when "0000010" =>            -- RUN
                           if (cmd_op(7) = '0') then
                              held9 <= '0'; hit9 <= '0'; rel9 <= '1';
                           else
                              held7 <= '0'; hit7 <= '0'; rel7 <= '1';
                           end if;
                           state <= RESPOND;

                        when "0000011" =>            -- RUNCYC
                           if (cmd_op(7) = '0') then
                              held9    <= '0';
                              hit9     <= '0';
                              rel9     <= '1';
                              run9_cnt <= unsigned(cmd_arg(23 downto 0));
                              run9_act <= '1';
                           else
                              held7    <= '0';
                              hit7     <= '0';
                              rel7     <= '1';
                              run7_cnt <= unsigned(cmd_arg(23 downto 0));
                              run7_act <= '1';
                           end if;
                           state <= RESPOND;

                        when "0000100" =>            -- BRKSET
                           if (cmd_op(7) = '0') then
                              bp9 <= cmd_arg; bp9_en <= '1'; hit9 <= '0';
                           else
                              bp7 <= cmd_arg; bp7_en <= '1'; hit7 <= '0';
                           end if;
                           state <= RESPOND;

                        when "0000101" =>            -- BRKCLR
                           if (cmd_op(7) = '0') then bp9_en <= '0';
                           else                      bp7_en <= '0'; end if;
                           state <= RESPOND;

                        when "0000110" =>            -- RDREG
                           regsel <= unsigned(cmd_arg(4 downto 0));
                           state  <= REG_WAIT;       -- one cycle for the mux

                        when "0000111" =>            -- PEEK
                           pk_addr <= cmd_arg;
                           state   <= PEEK_REQ;

                        when "0001001" =>            -- SOFTRESET
                           -- Restart the boot FSM and come back up with both
                           -- cores held. The cart image stays in DDR3, so the
                           -- loader re-stages main RAM and every probe starts
                           -- from an identical t=0 with no OSD interaction.
                           boot_rst <= '1';
                           held9    <= '1'; held7    <= '1';
                           hit9     <= '0'; hit7     <= '0';
                           run9_act <= '0'; run7_act <= '0';
                           state    <= RESPOND;

                        when "0001010" =>            -- PROBE (memory-path FSMs)
                           answer <= probe;
                           state  <= RESPOND;

                        when "0001101" =>            -- CARDSTAT (op 0x0D)
                           answer <= cardstat;
                           state  <= RESPOND;

                        when "0001110" =>            -- IPCSTAT (op 0x0E)
                           answer <= ipcstat;
                           state  <= RESPOND;

                        when "0001111" =>            -- PERFSTAT (op 0x0F)
                           answer <= perfstat;
                           state  <= RESPOND;

                        when "0001100" =>            -- IRQSTAT, arg selects
                           case cmd_arg(2 downto 0) is
                              when "000"  => answer <= irq9_ime;
                              when "001"  => answer <= irq9_ie;
                              when "010"  => answer <= irq9_if;
                              when "011"  => answer <= irq7_ime;
                              when "100"  => answer <= irq7_ie;
                              when others => answer <= irq7_if;
                           end case;
                           state <= RESPOND;

                        when others =>               -- 0x08 STATUS + unknown
                           answer <= x"0000000" &
                                     hit7 & hit9 & held7 & held9;
                           state  <= RESPOND;
                     end case;
                  end if;

               when REG_WAIT =>
                  if (sel_cpu = '0') then answer <= regval9;
                  else                    answer <= regval7; end if;
                  state <= RESPOND;

               when PEEK_REQ =>
                  pk_ena   <= '1';
                  pk_timer <= (others => '0');
                  state    <= PEEK_WAIT;

               when PEEK_WAIT =>
                  pk_timer <= pk_timer + 1;
                  if (pk_done = '1') then
                     answer <= pk_data;
                     state  <= RESPOND;
                  elsif (pk_timer = x"FFFF") then
                     answer <= x"BADACCE5";
                     state  <= RESPOND;
                  end if;

               when RESPOND =>
                  rsp_data <= answer;
                  rsp_stb  <= '1';
                  state    <= IDLE;

            end case;
         end if;
      end if;
   end process;

end architecture;
