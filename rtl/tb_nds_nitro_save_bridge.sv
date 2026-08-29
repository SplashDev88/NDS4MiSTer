`timescale 1ns/1ps
module tb_nds_nitro_save_bridge;
    logic clk = 0;
    logic reset = 1;
    logic cart_download = 0;
    logic img_mounted = 0;
    logic img_readonly = 0;
    logic [63:0] img_size = 0;
    logic [3:0] backup_save_type = 0;
    logic backup_profile_valid = 0;
    logic [19:0] backup_linear_addr = 0;
    logic backup_access_active = 0;
    logic backup_write_toggle = 0;
    logic save_ready, save_run_ready, backup_cache_ready;
    logic [27:0] debug_status;
    logic [31:0] sd_lba;
    logic sd_rd, sd_wr, sd_ack = 0;
    logic [12:0] sd_buff_addr;
    logic [15:0] sd_buff_dout;
    logic [15:0] sd_buff_din;
    logic sd_buff_wr;
    logic [7:0] backup_host_addr;
    logic [15:0] backup_host_write_data;
    logic backup_host_write_enable;
    logic [15:0] backup_host_read_data;

    logic [15:0] cache [0:255];
    logic [15:0] disk_8k_word = 16'hffff;
    logic [15:0] disk_64k_word = 16'hffff;
    logic [15:0] disk_prefix_word = 16'hffff;
    logic [15:0] disk_migration_last = 16'hffff;
    logic [15:0] disk_flash_last = 16'hffff;
    logic [15:0] disk_flash_target = 16'hffff;
    logic [15:0] disk_flash_1m_last = 16'hffff;
    integer io_word = 0;
    integer io_lba = 0;
    integer io_reads = 0;
    integer io_writes = 0;
    integer max_write_lba = -1;
    logic io_read = 0;
    logic io_write = 0;

    always #5 clk = ~clk;
    assign backup_host_read_data = cache[backup_host_addr];
    function automatic logic [15:0] disk_read(input integer lba, input integer widx);
        begin
            disk_read = 16'hffff;
            if (lba == 3 && widx == 9'h12) disk_read = disk_8k_word;
            if (lba == 100 && widx == 5) disk_read = disk_64k_word;
            if (lba == 0 && widx == 0) disk_read = disk_prefix_word;
            if (lba == 127 && widx == 255) disk_read = disk_migration_last;
            if (lba == 511 && widx == 255) disk_read = disk_flash_last;
            if (lba == (20'h3a123 >> 9) &&
                widx == ((20'h3a123 & 20'h001ff) >> 1))
                disk_read = disk_flash_target;
            if (lba == 2047 && widx == 255)
                disk_read = disk_flash_1m_last;
        end
    endfunction

    task automatic disk_write(input integer lba, input integer widx,
                              input logic [15:0] value);
        begin
            if (lba == 3 && widx == 9'h12) disk_8k_word <= value;
            if (lba == 100 && widx == 5) disk_64k_word <= value;
            if (lba == 0 && widx == 0) disk_prefix_word <= value;
            if (lba == 127 && widx == 255) disk_migration_last <= value;
            if (lba == 511 && widx == 255) disk_flash_last <= value;
            if (lba == (20'h3a123 >> 9) &&
                widx == ((20'h3a123 & 20'h001ff) >> 1))
                disk_flash_target <= value;
            if (lba == 2047 && widx == 255)
                disk_flash_1m_last <= value;
        end
    endtask

    always_comb begin
        sd_buff_addr = io_word[12:0];
        sd_buff_dout = disk_read(io_lba, io_word);
        sd_buff_wr = sd_ack && io_read;
    end

    nds_nitro_save_bridge #(.QUIET_COUNTER_BITS(3)) dut (.*);

    always_ff @(posedge clk) begin
        if (backup_host_write_enable)
            cache[backup_host_addr] <= backup_host_write_data;

        if (!sd_ack && (sd_rd || sd_wr)) begin
            sd_ack <= 1;
            io_word <= 0;
            io_lba <= sd_lba;
            io_read <= sd_rd;
            io_write <= sd_wr;
            if (sd_rd) io_reads <= io_reads + 1;
            if (sd_wr) begin
                io_writes <= io_writes + 1;
                if (max_write_lba < 0 || sd_lba > max_write_lba)
                    max_write_lba <= sd_lba;
            end
        end else if (sd_ack) begin
            if (io_write)
                disk_write(io_lba, io_word, sd_buff_din);
            if (io_word == 255) begin
                sd_ack <= 0;
                io_read <= 0;
                io_write <= 0;
                io_word <= 0;
            end else begin
                io_word <= io_word + 1;
            end
        end
    end

    task automatic clear_disk;
        begin
            disk_8k_word = 16'hffff;
            disk_64k_word = 16'hffff;
            disk_prefix_word = 16'hffff;
            disk_migration_last = 16'hffff;
            disk_flash_last = 16'hffff;
            disk_flash_target = 16'hffff;
            disk_flash_1m_last = 16'hffff;
            io_reads = 0;
            io_writes = 0;
            max_write_lba = -1;
        end
    endtask

    task automatic power_reset;
        begin
            reset <= 1;
            // The console-side profile lookup is reset with the cartridge
            // loader, so its valid level returns low for a fresh epoch.
            backup_profile_valid <= 0;
            repeat (5) @(posedge clk);
            reset <= 0;
            repeat (3) @(posedge clk);
        end
    endtask

    task automatic pulse_cart_download;
        begin
            // Cartridge download resets the console-side lookup before its
            // replacement result is generated.
            backup_profile_valid <= 0;
            cart_download <= 1;
            @(posedge clk);
            cart_download <= 0;
        end
    endtask

    task automatic expect_run_ready(input integer case_id);
        integer cycles;
        begin
            cycles = 0;
            while (!save_run_ready && cycles < 20000) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (!save_run_ready)
                $fatal(1, "ordering case %0d lost the one-cycle save mount event",
                       case_id);
        end
    endtask

    task automatic mount_profile(
        input logic [63:0] size,
        input logic ro,
        input logic [3:0] kind
    );
        begin
            img_size <= size;
            img_readonly <= ro;
            img_mounted <= 1;
            @(posedge clk);
            img_mounted <= 0;
            wait (save_ready);
            // The real loader/profile ROM produces a fresh result only after
            // console reset has released and the game code has been read.
            repeat (2) @(posedge clk);
            backup_save_type <= kind;
            backup_profile_valid <= 1;
            wait (save_run_ready);
            @(posedge clk);
        end
    endtask

    task automatic card_select(input logic [19:0] addr);
        begin
            backup_linear_addr <= addr;
            backup_access_active <= 1;
            wait (backup_cache_ready);
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic card_release;
        begin
            backup_access_active <= 0;
            repeat (3) @(posedge clk);
        end
    endtask

    task automatic card_write_byte(
        input logic [19:0] addr,
        input logic [7:0] value
    );
        logic [15:0] word;
        begin
            card_select(addr);
            word = cache[addr[8:1]];
            if (addr[0]) word[15:8] = value;
            else word[7:0] = value;
            cache[addr[8:1]] = word;
            backup_write_toggle <= ~backup_write_toggle;
            @(posedge clk);
            card_release();
        end
    endtask

    function automatic logic [7:0] cache_byte(input logic [19:0] addr);
        logic [15:0] word;
        begin
            word = cache[addr[8:1]];
            cache_byte = addr[0] ? word[15:8] : word[7:0];
        end
    endfunction

    task automatic wait_flush;
        integer prior_count;
        begin
            prior_count = io_writes;
            wait (io_writes > prior_count);
            wait (!sd_ack && !sd_wr);
            repeat (3) @(posedge clk);
        end
    endtask

    integer writes_before;
    initial begin
        clear_disk();
        power_reset();

        // Real MiSTer ordering regression: the one-cycle save mount notice can
        // coincide with the first ROM-download cycle.  Losing it leaves the
        // bridge in ST_WAIT_MOUNT and holds both CPUs in reset indefinitely.
        backup_save_type <= 4'd2;
        backup_profile_valid <= 0;
        img_size <= 64'd8192;
        img_readonly <= 0;
        img_mounted <= 1;
        cart_download <= 1;
        @(posedge clk);
        img_mounted <= 0;
        cart_download <= 0;
        repeat (2) @(posedge clk);
        backup_profile_valid <= 1;
        expect_run_ready(1);

        // A cartridge replacement starts while the prior profile's valid
        // level is still crossing from the console clock.  The bridge must
        // not accept that stale type as the new cartridge's answer: this is
        // the board ordering that made a first NSMB load use Mario Kart
        // Demo's fallback type, while selecting NSMB a second time worked.
        power_reset();
        pulse_cart_download();
        mount_profile(64'd512, 0, 4'd1);
        img_size <= 64'd8192;
        img_readonly <= 0;
        img_mounted <= 1;
        cart_download <= 1;
        @(posedge clk);
        img_mounted <= 0;
        cart_download <= 0;
        repeat (3) @(posedge clk);
        backup_profile_valid <= 0;
        repeat (3) @(posedge clk);
        backup_save_type <= 4'd2;
        backup_profile_valid <= 1;
        expect_run_ready(3);
        if (dut.active_save_type != 4'd2)
            $fatal(1, "replacement accepted stale save profile type %0d",
                   dut.active_save_type);

        // The normal download-then-mount ordering remains supported too.
        power_reset();
        pulse_cart_download();
        mount_profile(64'd8192, 0, 4'd2);

        // Existing 8 KiB EEPROM: sector cache load, dirty flush and persistence.
        disk_8k_word = 16'hbbaa;
        card_select(20'h00624);
        if (cache_byte(20'h00624) != 8'haa)
            $fatal(1, "8K cache load mismatch");
        card_release();
        card_write_byte(20'h00624, 8'h5a);
        wait_flush();
        if (disk_8k_word[7:0] != 8'h5a)
            $fatal(1, "8K dirty flush mismatch");

        // A replacement mount can also arrive while the outgoing dirty cache
        // sector is still completing its host write.  Preserve that pulse when
        // the flush returns to ST_WAIT_MOUNT.
        card_write_byte(20'h00624, 8'ha6);
        pulse_cart_download();
        wait (sd_ack);
        img_size <= 64'd65536;
        img_readonly <= 0;
        img_mounted <= 1;
        backup_save_type <= 4'd3;
        @(posedge clk);
        img_mounted <= 0;
        // The replacement loader cannot publish a profile until save_ready
        // releases its console reset after the outgoing dirty flush.
        wait (save_ready);
        repeat (2) @(posedge clk);
        backup_profile_valid <= 1;
        expect_run_ready(2);

        // Existing 64 KiB EEPROM uses high sectors and survives a power reset.
        power_reset();
        disk_64k_word = 16'h7c3d;
        mount_profile(64'd65536, 0, 4'd3);
        card_select((20'd100 << 9) + 20'd10);
        if (cache_byte((20'd100 << 9) + 20'd10) != 8'h3d)
            $fatal(1, "64K high-sector read mismatch");
        card_release();
        card_write_byte((20'd100 << 9) + 20'd10, 8'he1);
        wait_flush();
        power_reset();
        mount_profile(64'd65536, 0, 4'd3);
        card_select((20'd100 << 9) + 20'd10);
        if (cache_byte((20'd100 << 9) + 20'd10) != 8'he1)
            $fatal(1, "64K reset persistence mismatch");
        card_release();

        // A prior 8K YQUE sidecar is expanded with FF without touching its prefix.
        power_reset();
        disk_prefix_word = 16'h1234;
        writes_before = io_writes;
        mount_profile(64'd8192, 0, 4'd3);
        if (io_writes - writes_before != 112 || max_write_lba < 127)
            $fatal(1, "YQUE migration writes=%0d max_lba=%0d",
                   io_writes - writes_before, max_write_lba);
        if (disk_prefix_word != 16'h1234 || disk_migration_last != 16'hffff)
            $fatal(1, "YQUE migration damaged prefix or failed FF tail");

        // New 256 KiB flash sidecar is exact-size FF, then high-sector data persists.
        power_reset();
        writes_before = io_writes;
        mount_profile(64'd0, 0, 4'd5);
        if (io_writes - writes_before != 512 || max_write_lba < 511)
            $fatal(1, "256K flash sidecar was not fully initialized");
        if (disk_flash_last != 16'hffff)
            $fatal(1, "flash initialization was not FF");
        card_write_byte(20'h3a123, 8'h66);
        wait_flush();
        if (disk_flash_target[15:8] != 8'h66)
            $fatal(1, "flash high-address dirty flush mismatch");

        // Existing 1 MiB flash reaches the final sector through the same small
        // cache; this guards the 2048-sector count and complete 20-bit address.
        power_reset();
        disk_flash_1m_last = 16'h8d4c;
        mount_profile(64'd1048576, 0, 4'd7);
        card_select(20'hffffe);
        if (cache_byte(20'hffffe) != 8'h4c || io_lba != 2047)
            $fatal(1, "1M flash final-sector read mismatch lba=%0d", io_lba);
        card_release();
        card_write_byte(20'hffffe, 8'ha7);
        wait_flush();
        if (disk_flash_1m_last[7:0] != 8'ha7)
            $fatal(1, "1M flash final-sector dirty flush mismatch");

        // Read-only and wrong-size sidecars are never overwritten.
        power_reset();
        writes_before = io_writes;
        mount_profile(64'd262144, 1, 4'd5);
        card_write_byte(20'h00120, 8'h99);
        repeat (40) @(posedge clk);
        if (io_writes != writes_before)
            $fatal(1, "read-only flash sidecar was written");

        power_reset();
        writes_before = io_writes;
        mount_profile(64'd12345, 0, 4'd5);
        card_select(20'h00220);
        if (cache_byte(20'h00220) != 8'hff)
            $fatal(1, "wrong-size sidecar did not present blank chip");
        card_release();
        card_write_byte(20'h00220, 8'h77);
        repeat (40) @(posedge clk);
        if (io_writes != writes_before)
            $fatal(1, "wrong-size sidecar was overwritten");

        $display("PASS: host-backed 8K/64K EEPROM and 256K/1M flash persistence");
        $finish;
    end
endmodule
