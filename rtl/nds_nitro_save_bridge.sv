// SPDX-License-Identifier: GPL-3.0-or-later
// Host-backed cartridge-save cache for the Nitro console island.
//
// The DS backup chip and MiSTer's mounted .sav channel share one 512-byte,
// mixed-width M10K cache. Cache misses stall AUXSPI through cache_ready while
// this bridge reads or writes one sector. This supports save devices through
// 1 MiB without placing the whole image in FPGA RAM: compared with the former
// 64 KiB backing store it frees 63 M10Ks while retaining standard MiSTer .sav
// persistence.
module nds_nitro_save_bridge #(
    parameter integer QUIET_COUNTER_BITS = 24
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        cart_download,

    input  logic        img_mounted,
    input  logic        img_readonly,
    input  logic [63:0] img_size,

    input  logic [3:0]  backup_save_type,
    input  logic        backup_profile_valid,
    input  logic [19:0] backup_linear_addr,
    input  logic        backup_access_active,
    input  logic        backup_write_toggle,
    output logic        save_ready,
    output logic        save_run_ready,
    output logic        backup_cache_ready,

    output logic [31:0] sd_lba,
    output logic        sd_rd,
    output logic        sd_wr,
    input  logic        sd_ack,
    input  logic [12:0] sd_buff_addr,
    input  logic [15:0] sd_buff_dout,
    output logic [15:0] sd_buff_din,
    input  logic        sd_buff_wr,

    output logic [7:0]  backup_host_addr,
    output logic [15:0] backup_host_write_data,
    output logic        backup_host_write_enable,
    input  logic [15:0] backup_host_read_data
);
    typedef enum logic [3:0] {
        ST_WAIT_MOUNT,
        ST_WAIT_PROFILE,
        ST_CACHE_CLEAR,
        ST_INIT_WRITE_REQUEST,
        ST_INIT_WRITE_WAIT,
        ST_READY,
        ST_LOAD_REQUEST,
        ST_LOAD_WAIT,
        ST_LOAD_COMMIT,
        ST_FLUSH_REQUEST,
        ST_FLUSH_WAIT
    } state_t;

    state_t state = ST_WAIT_MOUNT;

    logic cart_download_d;
    logic cart_epoch_started;
    logic mount_pending;
    logic [63:0] mounted_size;
    logic mounted_readonly;
    logic mounted_valid_size;
    logic mounted_has_data;
    logic [11:0] mounted_sector_count;
    logic [11:0] active_sector_count;
    logic [3:0] active_save_type;

    logic [10:0] cache_lba;
    logic [10:0] target_lba;
    logic cache_valid;
    logic cache_dirty;
    logic dirty_during_flush;
    logic post_flush_load;
    logic replacement_pending;

    logic [7:0] clear_addr;
    logic clear_for_init;
    logic [10:0] init_sector;
    logic [10:0] init_last_sector;
    logic [8:0] load_word_count;
    logic [QUIET_COUNTER_BITS-1:0] quiet_counter;
    logic profile_fresh_armed;

    (* async_reg = "true" *) logic [19:0] backup_addr_meta;
    (* async_reg = "true" *) logic [19:0] backup_addr_sync;
    (* async_reg = "true" *) logic access_meta;
    (* async_reg = "true" *) logic access_sync;
    (* async_reg = "true" *) logic backup_toggle_meta;
    (* async_reg = "true" *) logic backup_toggle_sync;
    logic backup_toggle_d;

    wire cart_download_start = cart_download && !cart_download_d;
    wire backup_write_event = backup_toggle_sync != backup_toggle_d;
    wire [10:0] requested_lba = backup_addr_sync[19:9];
    wire mounted_write_allowed = mounted_valid_size && !mounted_readonly;

    function automatic logic [11:0] sectors_for_type(input logic [3:0] t);
        case (t)
            4'd1: sectors_for_type = 12'd1;    // 512-byte tiny EEPROM
            4'd2: sectors_for_type = 12'd16;   // 8 KiB EEPROM
            4'd3: sectors_for_type = 12'd128;  // 64 KiB EEPROM/FRAM
            4'd4: sectors_for_type = 12'd256;  // 128 KiB EEPROM/FRAM
            4'd5: sectors_for_type = 12'd512;  // 256 KiB flash
            4'd6: sectors_for_type = 12'd1024; // 512 KiB flash
            4'd7: sectors_for_type = 12'd2048; // 1 MiB flash
            default: sectors_for_type = 12'd0;
        endcase
    endfunction

    always_comb begin
        backup_host_addr = sd_buff_addr[7:0];
        backup_host_write_data = sd_buff_dout;
        backup_host_write_enable = 1'b0;
        sd_buff_din = backup_host_read_data;

        if (state == ST_CACHE_CLEAR) begin
            backup_host_addr = clear_addr;
            backup_host_write_data = 16'hffff;
            backup_host_write_enable = 1'b1;
        end else if ((state == ST_LOAD_REQUEST || state == ST_LOAD_WAIT) &&
                     sd_buff_wr && !load_word_count[8]) begin
            // hps_io's sector-buffer address is shared state.  A delayed MGL
            // load was observed beginning at word 19, rotating an otherwise
            // correct 512-byte save sector by 38 bytes.  Sector payload order
            // is still sequential, so index the private cache from the request
            // boundary instead of trusting that shared absolute address.
            backup_host_addr = load_word_count[7:0];
            backup_host_write_enable = 1'b1;
        end
    end

    always_comb begin
        backup_cache_ready = 1'b0;
        if (state == ST_READY && save_run_ready && active_save_type != 0 &&
            access_sync && cache_valid && cache_lba == requested_lba)
            backup_cache_ready = 1'b1;
    end

    // A MiSTer save mount pulse can overlap the ROM download edge, or arrive
    // while the outgoing cache sector is still being flushed.  img_mounted is
    // only a pulse, so the replacement reset must retain a mount already seen;
    // otherwise ST_WAIT_MOUNT can wait forever and keep the console in reset.
    task automatic reset_for_new_cart(input logic preserve_mount);
        begin
            state <= ST_WAIT_MOUNT;
            if (!preserve_mount) begin
                mount_pending <= 1'b0;
                mounted_size <= 64'd0;
                mounted_readonly <= 1'b0;
            end
            mounted_valid_size <= 1'b0;
            mounted_has_data <= 1'b0;
            mounted_sector_count <= 12'd0;
            active_sector_count <= 12'd0;
            active_save_type <= 4'd0;
            cache_valid <= 1'b0;
            cache_dirty <= 1'b0;
            dirty_during_flush <= 1'b0;
            post_flush_load <= 1'b0;
            replacement_pending <= 1'b0;
            profile_fresh_armed <= 1'b0;
            quiet_counter <= '0;
            save_ready <= 1'b0;
            save_run_ready <= 1'b0;
            sd_lba <= 32'd0;
            sd_rd <= 1'b0;
            sd_wr <= 1'b0;
            load_word_count <= 9'd0;
        end
    endtask

    always_ff @(posedge clk) begin : bridge_fsm
        logic [11:0] expected_sectors;
        logic [63:0] expected_bytes;
        logic exact_size;
        logic chrono_short_migration;

        if (reset) begin
            cart_download_d <= 1'b0;
            cart_epoch_started <= 1'b0;
            backup_addr_meta <= '0;
            backup_addr_sync <= '0;
            access_meta <= 1'b0;
            access_sync <= 1'b0;
            backup_toggle_meta <= 1'b0;
            backup_toggle_sync <= 1'b0;
            backup_toggle_d <= 1'b0;
            clear_addr <= '0;
            clear_for_init <= 1'b0;
            init_sector <= '0;
            init_last_sector <= '0;
            cache_lba <= '0;
            target_lba <= '0;
            reset_for_new_cart(1'b0);
        end else begin
            cart_download_d <= cart_download;
            backup_addr_meta <= backup_linear_addr;
            backup_addr_sync <= backup_addr_meta;
            access_meta <= backup_access_active;
            access_sync <= access_meta;
            backup_toggle_meta <= backup_write_toggle;
            backup_toggle_sync <= backup_toggle_meta;
            backup_toggle_d <= backup_toggle_sync;

            if ((state == ST_LOAD_REQUEST || state == ST_LOAD_WAIT) &&
                sd_buff_wr && !load_word_count[8])
                load_word_count <= load_word_count + 1'b1;

            if (img_mounted) begin
                mount_pending <= 1'b1;
                mounted_size <= img_size;
                mounted_readonly <= img_readonly;
            end

            if (backup_write_event) begin
                cache_dirty <= 1'b1;
                quiet_counter <= '0;
                if (state == ST_FLUSH_REQUEST || state == ST_FLUSH_WAIT)
                    dirty_during_flush <= 1'b1;
            end

            if (cart_download_start) begin
                cart_epoch_started <= 1'b1;
                save_ready <= 1'b0;
                save_run_ready <= 1'b0;
                replacement_pending <= 1'b1;
                quiet_counter <= '0;
                if (cache_dirty && mounted_write_allowed && state == ST_READY) begin
                    sd_lba <= {21'd0, cache_lba};
                    sd_wr <= 1'b1;
                    dirty_during_flush <= 1'b0;
                    post_flush_load <= 1'b0;
                    state <= ST_FLUSH_REQUEST;
                end else if (state != ST_FLUSH_REQUEST && state != ST_FLUSH_WAIT) begin
                    reset_for_new_cart(mount_pending | img_mounted);
                end
            end else begin
                case (state)
                    ST_WAIT_MOUNT: begin
                        // MiSTer may announce the save image before it starts
                        // downloading the ROM.  Keep that mount unconsumed
                        // until the cartridge epoch begins; otherwise the
                        // later cart_download_start reset discards the only
                        // mount notification and the first load hangs here.
                        if (cart_epoch_started && mount_pending) begin
                            mount_pending <= 1'b0;
                            save_ready <= 1'b1;
                            save_run_ready <= 1'b0;
                            state <= ST_WAIT_PROFILE;
                        end
                    end

                    ST_WAIT_PROFILE: begin
                        // backup_profile_valid crosses from the console clock
                        // and can remain high briefly with the outgoing
                        // cartridge's type after a replacement starts.  Arm
                        // only after observing the reset/lookup low phase, so
                        // this epoch can consume only its own fresh result.
                        if (!backup_profile_valid) begin
                            profile_fresh_armed <= 1'b1;
                        end else if (profile_fresh_armed) begin
                            profile_fresh_armed <= 1'b0;
                            expected_sectors = sectors_for_type(backup_save_type);
                            expected_bytes = {41'd0, expected_sectors, 9'd0};
                            exact_size = mounted_size == expected_bytes;
                            chrono_short_migration = backup_save_type == 4'd3 &&
                                                     mounted_size == 64'd8192;
                            active_save_type <= backup_save_type;
                            active_sector_count <= expected_sectors;
                            mounted_valid_size <= (mounted_size == 0) || exact_size ||
                                                  chrono_short_migration;
                            mounted_has_data <= exact_size || chrono_short_migration;
                            if (exact_size)
                                mounted_sector_count <= expected_sectors;
                            else if (chrono_short_migration)
                                mounted_sector_count <= 12'd16;
                            else
                                mounted_sector_count <= 12'd0;
                            cache_valid <= 1'b0;
                            cache_dirty <= 1'b0;

                            if (backup_save_type == 0 ||
                                (mounted_size != 0 && !exact_size &&
                                 !chrono_short_migration)) begin
                                // Unsupported/no-save or a wrong-size sidecar:
                                // boot with a blank, nonpersistent chip without
                                // reading or overwriting the user's file.
                                save_run_ready <= 1'b1;
                                state <= ST_READY;
                            end else if (!mounted_readonly &&
                                         (mounted_size == 0 ||
                                          chrono_short_migration)) begin
                                // Materialize every missing sector as FF. The
                                // result is an exact-size standard sidecar, not
                                // a sparse file whose holes read back as zero.
                                init_sector <= chrono_short_migration ? 11'd16 : 11'd0;
                                init_last_sector <= expected_sectors[10:0] - 1'b1;
                                clear_addr <= '0;
                                clear_for_init <= 1'b1;
                                state <= ST_CACHE_CLEAR;
                            end else begin
                                save_run_ready <= 1'b1;
                                state <= ST_READY;
                            end
                        end
                    end

                    ST_CACHE_CLEAR: begin
                        if (&clear_addr) begin
                            clear_addr <= '0;
                            if (clear_for_init) begin
                                sd_lba <= {21'd0, init_sector};
                                sd_wr <= 1'b1;
                                state <= ST_INIT_WRITE_REQUEST;
                            end else begin
                                cache_lba <= target_lba;
                                cache_valid <= 1'b1;
                                cache_dirty <= 1'b0;
                                state <= ST_READY;
                            end
                        end else begin
                            clear_addr <= clear_addr + 1'b1;
                        end
                    end

                    ST_INIT_WRITE_REQUEST: begin
                        if (sd_ack) begin
                            sd_wr <= 1'b0;
                            state <= ST_INIT_WRITE_WAIT;
                        end
                    end

                    ST_INIT_WRITE_WAIT: begin
                        if (!sd_ack) begin
                            if (init_sector == init_last_sector) begin
                                mounted_sector_count <= active_sector_count;
                                mounted_has_data <= 1'b1;
                                save_run_ready <= 1'b1;
                                cache_valid <= 1'b0;
                                clear_for_init <= 1'b0;
                                sd_lba <= 32'd0;
                                state <= ST_READY;
                            end else begin
                                init_sector <= init_sector + 1'b1;
                                sd_lba <= {21'd0, init_sector + 1'b1};
                                sd_wr <= 1'b1;
                                state <= ST_INIT_WRITE_REQUEST;
                            end
                        end
                    end

                    ST_READY: begin
                        if (access_sync && active_save_type != 0 &&
                            (!cache_valid || cache_lba != requested_lba)) begin
                            target_lba <= requested_lba;
                            quiet_counter <= '0;
                            if (cache_dirty && mounted_write_allowed) begin
                                sd_lba <= {21'd0, cache_lba};
                                sd_wr <= 1'b1;
                                dirty_during_flush <= 1'b0;
                                post_flush_load <= 1'b1;
                                state <= ST_FLUSH_REQUEST;
                            end else if (mounted_has_data && mounted_valid_size &&
                                         {1'b0, requested_lba} < mounted_sector_count) begin
                                sd_lba <= {21'd0, requested_lba};
                                sd_rd <= 1'b1;
                                load_word_count <= 9'd0;
                                state <= ST_LOAD_REQUEST;
                            end else begin
                                clear_addr <= '0;
                                clear_for_init <= 1'b0;
                                state <= ST_CACHE_CLEAR;
                            end
                        end else if (cache_dirty && mounted_write_allowed &&
                                     !access_sync) begin
                            if (&quiet_counter) begin
                                sd_lba <= {21'd0, cache_lba};
                                sd_wr <= 1'b1;
                                dirty_during_flush <= 1'b0;
                                post_flush_load <= 1'b0;
                                state <= ST_FLUSH_REQUEST;
                            end else if (!backup_write_event) begin
                                quiet_counter <= quiet_counter + 1'b1;
                            end
                        end
                    end

                    ST_LOAD_REQUEST: begin
                        if (sd_ack) begin
                            sd_rd <= 1'b0;
                            state <= ST_LOAD_WAIT;
                        end
                    end

                    ST_LOAD_WAIT: begin
                        if (!sd_ack) begin
                            // Give the mixed-width M10K one full cache clock to
                            // commit its last registered host-port write before
                            // publishing the sector to the cartridge side.
                            state <= ST_LOAD_COMMIT;
                        end
                    end

                    ST_LOAD_COMMIT: begin
                        if (load_word_count == 9'd256) begin
                            cache_lba <= target_lba;
                            cache_valid <= 1'b1;
                            cache_dirty <= 1'b0;
                            state <= ST_READY;
                        end else begin
                            // A truncated transfer must never become a valid
                            // save sector. Retry the same LBA from word zero.
                            load_word_count <= 9'd0;
                            sd_rd <= 1'b1;
                            state <= ST_LOAD_REQUEST;
                        end
                    end

                    ST_FLUSH_REQUEST: begin
                        if (sd_ack) begin
                            sd_wr <= 1'b0;
                            state <= ST_FLUSH_WAIT;
                        end
                    end

                    ST_FLUSH_WAIT: begin
                        if (!sd_ack) begin
                            cache_dirty <= dirty_during_flush | backup_write_event;
                            quiet_counter <= '0;
                            if (replacement_pending) begin
                                reset_for_new_cart(mount_pending | img_mounted);
                            end else if (post_flush_load) begin
                                post_flush_load <= 1'b0;
                                if (mounted_has_data && mounted_valid_size &&
                                    {1'b0, target_lba} < mounted_sector_count) begin
                                    sd_lba <= {21'd0, target_lba};
                                    sd_rd <= 1'b1;
                                    load_word_count <= 9'd0;
                                    state <= ST_LOAD_REQUEST;
                                end else begin
                                    clear_addr <= '0;
                                    clear_for_init <= 1'b0;
                                    state <= ST_CACHE_CLEAR;
                                end
                            end else begin
                                state <= ST_READY;
                            end
                        end
                    end

                    default: reset_for_new_cart(1'b0);
                endcase
            end
        end
    end
endmodule
