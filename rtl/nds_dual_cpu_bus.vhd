library ieee;
use ieee.std_logic_1164.all;

entity nds_dual_cpu_bus is
   port (
      clk, reset : in std_logic;

      arm9_addr  : in  std_logic_vector(31 downto 0);
      arm9_rnw   : in  std_logic;
      arm9_ena   : in  std_logic;
      arm9_acc   : in  std_logic_vector(1 downto 0);
      arm9_wdata : in  std_logic_vector(31 downto 0);
      arm9_debug_pc : in std_logic_vector(31 downto 0);
      arm9_rdata : out std_logic_vector(31 downto 0);
      arm9_done  : out std_logic;

      arm7_addr  : in  std_logic_vector(31 downto 0);
      arm7_rnw   : in  std_logic;
      arm7_ena   : in  std_logic;
      arm7_acc   : in  std_logic_vector(1 downto 0);
      arm7_wdata : in  std_logic_vector(31 downto 0);
      arm7_debug_pc : in std_logic_vector(31 downto 0);
      arm7_rdata : out std_logic_vector(31 downto 0);
      arm7_done  : out std_logic;

      ext_addr   : out std_logic_vector(31 downto 0);
      ext_rnw    : out std_logic;
      ext_ena    : out std_logic;
      ext_acc    : out std_logic_vector(1 downto 0);
      ext_wdata  : out std_logic_vector(31 downto 0);
      ext_cpu_is_arm9 : out std_logic;
      ext_debug_pc : out std_logic_vector(31 downto 0);
      ext_rdata  : in  std_logic_vector(31 downto 0);
      ext_done   : in  std_logic
   );
end entity;

architecture rtl of nds_dual_cpu_bus is
   type grant_type is (idle, grant_arm9, grant_arm7);
   signal grant : grant_type := idle;
   signal last_grant_arm9 : std_logic := '0';
   signal request_addr  : std_logic_vector(31 downto 0) := (others => '0');
   signal request_rnw   : std_logic := '1';
   signal request_acc   : std_logic_vector(1 downto 0) := (others => '0');
   signal request_wdata : std_logic_vector(31 downto 0) := (others => '0');
   signal request_debug_pc : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal pending9, pending7 : std_logic := '0';
   signal pending9_addr, pending7_addr : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal pending9_rnw, pending7_rnw : std_logic := '1';
   signal pending9_acc, pending7_acc : std_logic_vector(1 downto 0) :=
      (others => '0');
   signal pending9_wdata, pending7_wdata : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal pending9_debug_pc, pending7_debug_pc :
      std_logic_vector(31 downto 0) := (others => '0');
   signal ipc9_read, ipc7_read : std_logic_vector(31 downto 0);
   signal ipc9_hit, ipc7_hit : std_logic;
   signal ipc9_we, ipc7_we : std_logic;
   signal ipc_boot_local : std_logic := '1';
   signal ipc_boot_seen_nonzero : std_logic := '0';
begin
   -- The firmware's initial 8..0 IPCSYNC countdown uses only the two
   -- handshake nibbles. Serve that bounded phase locally: forwarding every
   -- poll through HPS makes a few hundred native reads become tens of
   -- thousands of slow mailbox round trips. Once both sides return to zero,
   -- permanently hand IPCSYNC back to HPS so interrupt-enable/send/IF
   -- semantics remain authoritative there.
   ipc9_hit <= '1' when ipc_boot_local = '1' and arm9_ena = '1' and
                        arm9_addr = x"04000180" else '0';
   ipc7_hit <= '1' when ipc_boot_local = '1' and arm7_ena = '1' and
                        arm7_addr = x"04000180" else '0';
   ipc9_we <= ipc9_hit and not arm9_rnw;
   ipc7_we <= ipc7_hit and not arm7_rnw;

   ipc : entity work.nds_ipcsync
      port map (
         clk => clk, reset => reset,
         arm9_we => ipc9_we, arm9_wdata => arm9_wdata, arm9_rdata => ipc9_read,
         arm7_we => ipc7_we, arm7_wdata => arm7_wdata, arm7_rdata => ipc7_read
      );

   arm9_rdata <= ipc9_read when ipc9_hit = '1' else ext_rdata;
   arm7_rdata <= ipc7_read when ipc7_hit = '1' else ext_rdata;
   arm9_done <= '1' when ipc9_hit = '1' else
                ext_done when grant = grant_arm9 else '0';
   arm7_done <= '1' when ipc7_hit = '1' else
                ext_done when grant = grant_arm7 else '0';

   ext_addr  <= request_addr;
   ext_rnw   <= request_rnw;
   ext_acc   <= request_acc;
   ext_wdata <= request_wdata;
   ext_cpu_is_arm9 <= '1' when grant = grant_arm9 else '0';
   ext_debug_pc <= request_debug_pc;
   ext_ena   <= '1' when grant /= idle else '0';

   process(clk)
      procedure issue9 is
      begin
         request_addr <= pending9_addr; request_rnw <= pending9_rnw;
         request_acc <= pending9_acc; request_wdata <= pending9_wdata;
         request_debug_pc <= pending9_debug_pc;
      end procedure;
      procedure issue7 is
      begin
         request_addr <= pending7_addr; request_rnw <= pending7_rnw;
         request_acc <= pending7_acc; request_wdata <= pending7_wdata;
         request_debug_pc <= pending7_debug_pc;
      end procedure;
      variable next_ipc9, next_ipc7 : std_logic_vector(3 downto 0);
      variable next_seen_nonzero : std_logic;
   begin
      if rising_edge(clk) then
         if reset = '1' then
            grant <= idle;
            last_grant_arm9 <= '0';
            pending9 <= '0';
            pending7 <= '0';
            ipc_boot_local <= '1';
            ipc_boot_seen_nonzero <= '0';
         else
            if ipc_boot_local = '1' then
               next_ipc9 := ipc9_read(11 downto 8);
               next_ipc7 := ipc7_read(11 downto 8);
               if ipc9_we = '1' then
                  next_ipc9 := arm9_wdata(11 downto 8);
               end if;
               if ipc7_we = '1' then
                  next_ipc7 := arm7_wdata(11 downto 8);
               end if;
               next_seen_nonzero := ipc_boot_seen_nonzero;
               if next_ipc9 /= "0000" or next_ipc7 /= "0000" then
                  next_seen_nonzero := '1';
               end if;
               ipc_boot_seen_nonzero <= next_seen_nonzero;
               if next_seen_nonzero = '1' and next_ipc9 = "0000" and
                  next_ipc7 = "0000" then
                  ipc_boot_local <= '0';
               end if;
            end if;
            -- gba_cpu pulses ena when it launches a transfer, then removes ena
            -- while waiting for done. Capture those pulses even while the
            -- other CPU owns the shared external port.
            -- A gba_cpu may launch its next transfer on the same edge that
            -- done completes the current one. Capture that pulse as pending;
            -- otherwise a branch/return boundary can lose the next fetch and
            -- leave the CPU permanently waiting.
            if arm9_ena = '1' and ipc9_hit = '0' and
               (grant /= grant_arm9 or ext_done = '1') and
               pending9 = '0' then
               pending9 <= '1';
               pending9_addr <= arm9_addr;
               pending9_rnw <= arm9_rnw;
               pending9_acc <= arm9_acc;
               pending9_wdata <= arm9_wdata;
               pending9_debug_pc <= arm9_debug_pc;
            end if;
            if arm7_ena = '1' and ipc7_hit = '0' and
               (grant /= grant_arm7 or ext_done = '1') and
               pending7 = '0' then
               pending7 <= '1';
               pending7_addr <= arm7_addr;
               pending7_rnw <= arm7_rnw;
               pending7_acc <= arm7_acc;
               pending7_wdata <= arm7_wdata;
               pending7_debug_pc <= arm7_debug_pc;
            end if;

            case grant is
               when idle =>
                  if pending9 = '1' and pending7 = '1' then
                     if last_grant_arm9 = '1' then
                        issue7; pending7 <= '0'; grant <= grant_arm7;
                     else
                        issue9; pending9 <= '0'; grant <= grant_arm9;
                     end if;
                  elsif pending9 = '1' then
                     issue9; pending9 <= '0'; grant <= grant_arm9;
                  elsif pending7 = '1' then
                     issue7; pending7 <= '0'; grant <= grant_arm7;
                  end if;
               when grant_arm9 =>
                  if ext_done = '1' then
                     grant <= idle; last_grant_arm9 <= '1';
                  end if;
               when grant_arm7 =>
                  if ext_done = '1' then
                     grant <= idle; last_grant_arm9 <= '0';
                  end if;
            end case;
         end if;
      end if;
   end process;
end architecture;
