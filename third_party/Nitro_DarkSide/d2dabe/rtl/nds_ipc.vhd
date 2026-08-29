-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- NDS IPC: IPCSYNC (0x180) + IPC FIFO (0x184 CNT, 0x188 SEND, 0x100000 RECV)
-- for both CPUs. Register bit meanings per NitroSDK ioreg_PXI.h / GBATEK:
--   IPCSYNC:    [3:0] data-in (other side's out), [11:8] data-out,
--               [13] send-IRQ-to-other (write-only strobe), [14] IRQ enable
--   IPCFIFOCNT: [0] send empty, [1] send full, [2] send-empty IRQ enable,
--               [3] send clear (strobe), [8] recv empty, [9] recv full,
--               [10] recv-not-empty IRQ enable, [14] error (write 1 to ack),
--               [15] FIFO enable
-- Reading RECV when empty sets the error flag and returns the last value read
-- (hardware keeps the last popped word on the bus). Sends when disabled or
-- full are dropped with the error flag set.
--
-- IRQ outputs are one-cycle pulses on the rising edge of their conditions.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity nds_ipc is
   port
   (
      clk             : in  std_logic;
      reset           : in  std_logic;

      bus7            : in  proc_bus_gb_type;
      wired_out7      : out std_logic_vector(31 downto 0);
      wired_done7     : out std_logic;
      irq7_sync       : out std_logic := '0';
      irq7_sendempty  : out std_logic := '0';
      irq7_recv       : out std_logic := '0';

      bus9            : in  proc_bus_gb_type;
      wired_out9      : out std_logic_vector(31 downto 0);
      wired_done9     : out std_logic;
      irq9_sync       : out std_logic := '0';
      irq9_sendempty  : out std_logic := '0';

      -- Debug tap (nds_debug op 0x0E). Both CPUs idling with IPC IRQs enabled
      -- and neither IF pending is a missed-wakeup deadlock, and NOTHING else
      -- can see it: peek cannot read IO, so IPCSYNC/IPCFIFOCNT are invisible.
      dbg_ipc         : out std_logic_vector(31 downto 0) := (others => '0');
      irq9_recv       : out std_logic := '0'
   );
end entity;

architecture arch of nds_ipc is

   constant ADR_SYNC : std_logic_vector(27 downto 0) := x"0000180";
   constant ADR_CNT  : std_logic_vector(27 downto 0) := x"0000184";
   constant ADR_SEND : std_logic_vector(27 downto 0) := x"0000188";
   constant ADR_RECV : std_logic_vector(27 downto 0) := x"0100000";

   type t_fifo is array (0 to 15) of std_logic_vector(31 downto 0);

   -- fifo79: ARM7 -> ARM9 (7's send, 9's recv); fifo97 the reverse
   signal fifo79, fifo97       : t_fifo;
   signal cnt79, cnt97         : integer range 0 to 16 := 0;
   signal rd79, wr79           : integer range 0 to 15 := 0;
   signal rd97, wr97           : integer range 0 to 15 := 0;

   signal sync7_out, sync9_out : std_logic_vector(3 downto 0) := (others => '0');
   signal sync7_ien, sync9_ien : std_logic := '0';

   signal en7, en9             : std_logic := '0';
   signal sirq7, sirq9         : std_logic := '0';   -- send-empty irq enable
   signal rirq7, rirq9         : std_logic := '0';   -- recv irq enable
   signal err7, err9           : std_logic := '0';
   signal last7, last9         : std_logic_vector(31 downto 0) := (others => '0');

   signal sync7_rd, sync9_rd   : std_logic_vector(31 downto 0);
   signal cnt7_rd, cnt9_rd     : std_logic_vector(31 downto 0);

   -- irq edge tracking
   signal p7_sendemp, p9_sendemp : std_logic := '0';
   signal p7_recvpend, p9_recvpend : std_logic := '0';

begin

   -- ================= combinational read data =================
   sync7_rd <= x"0000" & '0' & sync7_ien & '0' & '0' & sync7_out & x"0" & sync9_out;
   sync9_rd <= x"0000" & '0' & sync9_ien & '0' & '0' & sync9_out & x"0" & sync7_out;

   cnt7_rd(31 downto 16) <= (others => '0');
   cnt7_rd(15) <= en7;   cnt7_rd(14) <= err7;  cnt7_rd(13 downto 11) <= (others => '0');
   cnt7_rd(10) <= rirq7; cnt7_rd(9)  <= '1' when cnt97 = 16 else '0';
   cnt7_rd(8)  <= '1' when cnt97 = 0 else '0';
   cnt7_rd(7 downto 3) <= (others => '0');
   cnt7_rd(2)  <= sirq7; cnt7_rd(1)  <= '1' when cnt79 = 16 else '0';
   cnt7_rd(0)  <= '1' when cnt79 = 0 else '0';

   cnt9_rd(31 downto 16) <= (others => '0');
   cnt9_rd(15) <= en9;   cnt9_rd(14) <= err9;  cnt9_rd(13 downto 11) <= (others => '0');
   cnt9_rd(10) <= rirq9; cnt9_rd(9)  <= '1' when cnt79 = 16 else '0';
   cnt9_rd(8)  <= '1' when cnt79 = 0 else '0';
   cnt9_rd(7 downto 3) <= (others => '0');
   -- [31:28] sync9_out  [27:24] sync7_out  [23] sync9_ien [22] sync7_ien
   -- [21] en9 [20] en7 [19] err9 [18] err7 [17] rirq9 [16] rirq7
   -- [15] sirq9 [14] sirq7  [12:8] cnt97 (7->9 depth)  [4:0] cnt79 (9->7 depth)
   dbg_ipc <= sync9_out & sync7_out
              & sync9_ien & sync7_ien & en9 & en7 & err9 & err7
              & rirq9 & rirq7 & sirq9 & sirq7
              & '0' & std_logic_vector(to_unsigned(cnt97, 5))
              & "000" & std_logic_vector(to_unsigned(cnt79, 5));

   cnt9_rd(2)  <= sirq9; cnt9_rd(1)  <= '1' when cnt97 = 16 else '0';
   cnt9_rd(0)  <= '1' when cnt97 = 0 else '0';

   wired_out7 <= sync7_rd when (bus7.Adr = ADR_SYNC) else
                 cnt7_rd  when (bus7.Adr = ADR_CNT)  else
                 fifo97(rd97) when (bus7.Adr = ADR_RECV and cnt97 /= 0) else
                 last7        when (bus7.Adr = ADR_RECV) else
                 (others => '0');
   wired_done7 <= '1' when (bus7.Adr = ADR_SYNC or bus7.Adr = ADR_CNT or bus7.Adr = ADR_RECV) else '0';

   -- RECV reads present last9, NOT fifo79(rd79), and the asymmetry with the ARM7
   -- path above is deliberate.
   --
   -- The pop happens at the edge ending the cycle in which bus9.ena is high:
   -- `last9 <= fifo79(rd79)` captures the popped word and rd79 then advances. So
   -- fifo79(rd79) is only correct for a consumer that samples in the SAME cycle.
   -- The ARM7 is such a consumer - membus7 raises io_bus.ena and latches
   -- io_wired_out in the same FINISH cycle - which is why the ARM7 mux above is
   -- right as written. **The ARM9 is not.** nds_top's IO completion toggles
   -- cdc_io_cpl on the io9_ena cycle and the island latches io_wired_out9 one
   -- clk1x LATER (see the block comment at nds_top's cdc_io_cpl), i.e. after the
   -- pop edge - so it used to read the entry AFTER the one it popped.
   --
   -- Queue 11 22 33 44 and the ARM9 read back 22 33 44 44. It was invisible with
   -- a single queued word, because cnt79 is then 0 and the old mux fell through
   -- to last9, which holds the correct value - so every one-word test passed.
   -- NitroSDK's PXI handler drains multi-word messages in a loop, so every burst
   -- silently lost a word. Caught by bootreq subtests 22 and 25.
   --
   -- last9 is also the correct answer for a read of an EMPTY fifo: hardware
   -- returns the last value read (and err9 is set below), which is exactly what
   -- last9 holds. So this is unconditional rather than a cnt79 test.
   --
   -- This does depend on the ARM9 sampling after the pop edge. If that ever
   -- changes, this line has to change with it.
   wired_out9 <= sync9_rd when (bus9.Adr = ADR_SYNC) else
                 cnt9_rd  when (bus9.Adr = ADR_CNT)  else
                 last9    when (bus9.Adr = ADR_RECV) else
                 (others => '0');
   wired_done9 <= '1' when (bus9.Adr = ADR_SYNC or bus9.Adr = ADR_CNT or bus9.Adr = ADR_RECV) else '0';

   -- ================= state =================
   process (clk)
      variable v_cnt79, v_cnt97 : integer range 0 to 16;
      variable sendemp7, sendemp9, recvpend7, recvpend9 : std_logic;
   begin
      if rising_edge(clk) then

         irq7_sync      <= '0';
         irq9_sync      <= '0';
         irq7_sendempty <= '0';
         irq9_sendempty <= '0';
         irq7_recv      <= '0';
         irq9_recv      <= '0';

         if (reset = '1') then
            cnt79 <= 0; cnt97 <= 0; rd79 <= 0; wr79 <= 0; rd97 <= 0; wr97 <= 0;
            sync7_out <= (others => '0'); sync9_out <= (others => '0');
            sync7_ien <= '0'; sync9_ien <= '0';
            en7 <= '0'; en9 <= '0'; sirq7 <= '0'; sirq9 <= '0';
            rirq7 <= '0'; rirq9 <= '0'; err7 <= '0'; err9 <= '0';
            p7_sendemp <= '0'; p9_sendemp <= '0';
            p7_recvpend <= '0'; p9_recvpend <= '0';
         else
            v_cnt79 := cnt79;
            v_cnt97 := cnt97;

            -- ========== side 7 ==========
            if (bus7.ena = '1' and bus7.rnw = '0') then
               if (bus7.Adr = ADR_SYNC and bus7.bEna(1) = '1') then
                  sync7_out <= bus7.Din(11 downto 8);
                  sync7_ien <= bus7.Din(14);
                  if (bus7.Din(13) = '1' and sync9_ien = '1') then
                     irq9_sync <= '1';
                  end if;
               elsif (bus7.Adr = ADR_CNT) then
                  if (bus7.bEna(0) = '1') then
                     sirq7 <= bus7.Din(2);
                     if (bus7.Din(3) = '1') then
                        v_cnt79 := 0; rd79 <= 0; wr79 <= 0;
                     end if;
                  end if;
                  if (bus7.bEna(1) = '1') then
                     rirq7 <= bus7.Din(10);
                     en7   <= bus7.Din(15);
                     if (bus7.Din(14) = '1') then
                        err7 <= '0';
                     end if;
                  end if;
               elsif (bus7.Adr = ADR_SEND) then
                  if (en7 = '1' and v_cnt79 < 16) then
                     fifo79(wr79) <= bus7.Din;
                     wr79    <= (wr79 + 1) mod 16;
                     v_cnt79 := v_cnt79 + 1;
                  else
                     err7 <= '1';
                  end if;
               end if;
            end if;
            if (bus7.ena = '1' and bus7.rnw = '1' and bus7.Adr = ADR_RECV) then
               if (en7 = '1' and v_cnt97 /= 0) then
                  last7   <= fifo97(rd97);
                  rd97    <= (rd97 + 1) mod 16;
                  v_cnt97 := v_cnt97 - 1;
               elsif (en7 = '1') then
                  err7 <= '1';
               end if;
            end if;

            -- ========== side 9 ==========
            if (bus9.ena = '1' and bus9.rnw = '0') then
               if (bus9.Adr = ADR_SYNC and bus9.bEna(1) = '1') then
                  sync9_out <= bus9.Din(11 downto 8);
                  sync9_ien <= bus9.Din(14);
                  if (bus9.Din(13) = '1' and sync7_ien = '1') then
                     irq7_sync <= '1';
                  end if;
               elsif (bus9.Adr = ADR_CNT) then
                  if (bus9.bEna(0) = '1') then
                     sirq9 <= bus9.Din(2);
                     if (bus9.Din(3) = '1') then
                        v_cnt97 := 0; rd97 <= 0; wr97 <= 0;
                     end if;
                  end if;
                  if (bus9.bEna(1) = '1') then
                     rirq9 <= bus9.Din(10);
                     en9   <= bus9.Din(15);
                     if (bus9.Din(14) = '1') then
                        err9 <= '0';
                     end if;
                  end if;
               elsif (bus9.Adr = ADR_SEND) then
                  if (en9 = '1' and v_cnt97 < 16) then
                     fifo97(wr97) <= bus9.Din;
                     wr97    <= (wr97 + 1) mod 16;
                     v_cnt97 := v_cnt97 + 1;
                  else
                     err9 <= '1';
                  end if;
               end if;
            end if;
            if (bus9.ena = '1' and bus9.rnw = '1' and bus9.Adr = ADR_RECV) then
               if (en9 = '1' and v_cnt79 /= 0) then
                  last9   <= fifo79(rd79);
                  rd79    <= (rd79 + 1) mod 16;
                  v_cnt79 := v_cnt79 - 1;
               elsif (en9 = '1') then
                  err9 <= '1';
               end if;
            end if;

            cnt79 <= v_cnt79;
            cnt97 <= v_cnt97;

            -- ========== IRQ edges ==========
            sendemp7 := '0'; sendemp9 := '0'; recvpend7 := '0'; recvpend9 := '0';
            if (v_cnt79 = 0 and sirq7 = '1') then sendemp7 := '1'; end if;
            if (v_cnt97 = 0 and sirq9 = '1') then sendemp9 := '1'; end if;
            if (v_cnt97 /= 0 and rirq7 = '1') then recvpend7 := '1'; end if;
            if (v_cnt79 /= 0 and rirq9 = '1') then recvpend9 := '1'; end if;

            if (sendemp7 = '1' and p7_sendemp = '0') then irq7_sendempty <= '1'; end if;
            if (sendemp9 = '1' and p9_sendemp = '0') then irq9_sendempty <= '1'; end if;
            if (recvpend7 = '1' and p7_recvpend = '0') then irq7_recv <= '1'; end if;
            if (recvpend9 = '1' and p9_recvpend = '0') then irq9_recv <= '1'; end if;
            p7_sendemp  <= sendemp7;
            p9_sendemp  <= sendemp9;
            p7_recvpend <= recvpend7;
            p9_recvpend <= recvpend9;

         end if;
      end if;
   end process;

end architecture;
