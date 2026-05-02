//==============================================================================
// File        : tb_async_fifo.sv
// Description : Comprehensive SystemVerilog Testbench — Async FIFO
//               - Interface-driven, scoreboard-based self-checking
//               - 10 directed test cases + 2-seed randomized stress
//               - Concurrent SVA assertions via bind to fifo_assertions
//               - Covers: normal op, simultaneous R/W, back-to-back burst,
//                 full/empty edge cases, reset-in-flight, pointer wrap-around,
//                 CDC gray code integrity, underflow guard
// Tool        : Xcelium (xrun)
// Run         : bash sim/run_sim.sh
//==============================================================================

`timescale 1ns/1ps

//------------------------------------------------------------------------------
// BIND — attach fifo_assertions to the DUT transparently
//------------------------------------------------------------------------------
bind FIFO fifo_assertions #(
    .DSIZE(DSIZE),
    .ASIZE(ASIZE)
) u_fifo_assert (
    .wclk      (wclk),
    .rclk      (rclk),
    .wrst_n    (wrst_n),
    .rrst_n    (rrst_n),
    .winc      (winc),
    .rinc      (rinc),
    .wfull     (wfull),
    .rempty    (rempty),
    .wptr      (wptr_full.wptr),
    .rptr      (rptr_empty.rptr),
    .wq2_rptr  (wq2_rptr),
    .rq2_wptr  (rq2_wptr),
    .waddr     (waddr),
    .raddr     (raddr),
    .wdata     (wdata),
    .rdata     (rdata)
);

//==============================================================================
// TESTBENCH TOP
//==============================================================================
module tb_async_fifo;

    localparam int DSIZE = 8;
    localparam int ASIZE = 4;
    localparam int DEPTH = 1 << ASIZE;

    // Asymmetric clocks — exercises CDC path
    localparam int WCLK_HALF = 5;   // 100 MHz
    localparam int RCLK_HALF = 8;   // 62.5 MHz

    // -----------------------------------------------------------------------
    // Clocks
    // -----------------------------------------------------------------------
    logic wclk = 0;
    logic rclk = 0;
    always #(WCLK_HALF) wclk = ~wclk;
    always #(RCLK_HALF) rclk = ~rclk;

    // -----------------------------------------------------------------------
    // Interface & DUT
    // -----------------------------------------------------------------------
    fifo_if #(.DSIZE(DSIZE), .ASIZE(ASIZE)) vif (.wclk(wclk), .rclk(rclk));

    FIFO #(.DSIZE(DSIZE), .ASIZE(ASIZE)) dut (
        .rdata  (vif.rdata),
        .wfull  (vif.wfull),
        .rempty (vif.rempty),
        .wdata  (vif.wdata),
        .winc   (vif.winc),
        .wclk   (wclk),
        .wrst_n (vif.wrst_n),
        .rinc   (vif.rinc),
        .rclk   (rclk),
        .rrst_n (vif.rrst_n)
    );

    // -----------------------------------------------------------------------
    // Scoreboard
    // -----------------------------------------------------------------------
    logic [DSIZE-1:0] ref_q[$];
    int unsigned total_writes = 0;
    int unsigned total_reads  = 0;
    int unsigned pass_count   = 0;
    int unsigned fail_count   = 0;

    // -----------------------------------------------------------------------
    // TASKS
    // -----------------------------------------------------------------------

    task automatic apply_reset(input int cycles = 6);
        vif.wrst_n = 0; vif.rrst_n = 0;
        vif.winc = 0;   vif.rinc = 0;
        vif.wdata = '0;
        repeat(cycles) @(posedge wclk);
        repeat(cycles) @(posedge rclk);
        @(posedge wclk); vif.wrst_n = 1;
        @(posedge rclk); vif.rrst_n = 1;
        repeat(4) @(posedge wclk);
        repeat(4) @(posedge rclk);
        ref_q.delete();
        $display("[%0t] [RST] Reset released", $time);
    endtask

    task automatic fifo_write(input logic [DSIZE-1:0] data);
        @(posedge wclk); #1;
        if (!vif.wfull) begin
            vif.wdata = data;
            vif.winc  = 1;
            @(posedge wclk); #1;
            vif.winc = 0;
            ref_q.push_back(data);
            total_writes++;
            $display("[%0t] [WR]  0x%02h  depth=%0d", $time, data, ref_q.size());
        end else begin
            vif.winc = 0;
            $display("[%0t] [WR]  SKIP (full)", $time);
        end
    endtask

    task automatic fifo_read();
        @(posedge rclk); #1;
        if (!vif.rempty) begin
            // Sample rdata BEFORE asserting rinc — async read mem drives rdata
            // combinationally from raddr, which is valid while rempty is low.
            if (ref_q.size() > 0) begin
                automatic logic [DSIZE-1:0] exp = ref_q.pop_front();
                total_reads++;
                if (vif.rdata === exp) begin
                    pass_count++;
                    $display("[%0t] [RD]  0x%02h == exp 0x%02h  PASS", $time, vif.rdata, exp);
                end else begin
                    fail_count++;
                    $display("[%0t] [RD]  0x%02h != exp 0x%02h  *** FAIL ***", $time, vif.rdata, exp);
                end
            end
            // Advance raddr for next read
            vif.rinc = 1;
            @(posedge rclk); #1;
            vif.rinc = 0;
        end else begin
            vif.rinc = 0;
            $display("[%0t] [RD]  SKIP (empty)", $time);
        end
    endtask

    task automatic drain_all();
        int guard = 0;
        while (ref_q.size() > 0 && guard < DEPTH*4) begin
            if (!vif.rempty) fifo_read();
            else begin
                repeat(4) @(posedge rclk);  // wait for CDC propagation
                guard++;
            end
        end
    endtask

    task automatic check_wfull(input string ctx);
        repeat(4) @(posedge wclk);
        if (vif.wfull)
            $display("[%0t] [CHK] wfull ASSERTED — PASS (%s)", $time, ctx);
        else begin
            fail_count++;
            $display("[%0t] [CHK] wfull NOT ASSERTED — FAIL (%s)", $time, ctx);
        end
    endtask

    task automatic check_rempty(input string ctx);
        repeat(6) @(posedge rclk);
        if (vif.rempty)
            $display("[%0t] [CHK] rempty ASSERTED — PASS (%s)", $time, ctx);
        else begin
            fail_count++;
            $display("[%0t] [CHK] rempty NOT ASSERTED — FAIL (%s)", $time, ctx);
        end
    endtask

    // -----------------------------------------------------------------------
    // TEST 1: Basic Sequential Write → Read
    // -----------------------------------------------------------------------
    task automatic test_01_basic_sequential();
        $display("\n// TEST 01: Basic Sequential Write -> Read");
        apply_reset();
        for (int i = 0; i < 8; i++) fifo_write(8'(i*3+1));
        for (int i = 0; i < 8; i++) fifo_read();
        check_rempty("T01");
    endtask

    // -----------------------------------------------------------------------
    // TEST 2: Fill to Full + Overflow Attempt
    // -----------------------------------------------------------------------
    task automatic test_02_fill_and_full();
        $display("\n// TEST 02: Fill to Full + Overflow Attempt");
        apply_reset();
        for (int i = 0; i < DEPTH; i++) fifo_write(8'(8'hA0 + i));
        check_wfull("T02 fill");
        // Attempt overflow write — must be suppressed
        @(posedge wclk); #1;
        vif.wdata = 8'hFF; vif.winc = 1;
        @(posedge wclk); #1; vif.winc = 0;
        $display("[%0t] [T02] Overflow write attempted (expect drop)", $time);
        drain_all();
        check_rempty("T02 drain");
    endtask

    // -----------------------------------------------------------------------
    // TEST 3: Simultaneous Read & Write (forked threads)
    // -----------------------------------------------------------------------
    task automatic test_03_simultaneous_rw();
        $display("\n// TEST 03: Simultaneous Read & Write");
        apply_reset();
        for (int i = 0; i < DEPTH/2; i++) fifo_write(8'(8'h20 + i));

        fork
            begin : wr_thread
                for (int i = 0; i < 12; i++) begin
                    @(posedge wclk); #1;
                    if (!vif.wfull) begin
                        automatic logic [7:0] d = 8'(8'h60 + i);
                        vif.wdata = d; vif.winc = 1;
                        @(posedge wclk); #1; vif.winc = 0;
                        ref_q.push_back(d); total_writes++;
                    end
                end
            end
            begin : rd_thread
                for (int i = 0; i < 12; i++) begin
                    @(posedge rclk); #1;
                    if (!vif.rempty) begin
                        if (ref_q.size() > 0) begin
                            automatic logic [7:0] exp = ref_q.pop_front();
                            total_reads++;
                            if (vif.rdata === exp) pass_count++;
                            else begin
                                fail_count++;
                                $display("[%0t] [T03 FAIL] got=0x%02h exp=0x%02h", $time, vif.rdata, exp);
                            end
                        end
                        vif.rinc = 1;
                        @(posedge rclk); #1; vif.rinc = 0;
                    end
                end
            end
        join

        drain_all();
        $display("[%0t] [T03] Simultaneous R/W complete", $time);
    endtask

    // -----------------------------------------------------------------------
    // TEST 4: Back-to-Back Burst Write then Burst Read
    // -----------------------------------------------------------------------
    task automatic test_04_burst();
        $display("\n// TEST 04: Back-to-Back Burst Write -> Burst Read");
        apply_reset();

        // Burst write — winc held high every cycle
        @(posedge wclk); #1;
        for (int i = 0; i < DEPTH; i++) begin
            if (!vif.wfull) begin
                vif.wdata = 8'(8'hC0 + i);
                vif.winc  = 1;
                ref_q.push_back(8'(8'hC0 + i));
                total_writes++;
            end
            @(posedge wclk); #1;
        end
        vif.winc = 0;
        check_wfull("T04 burst-wr");

        // Burst read
        @(posedge rclk); #1;
        for (int i = 0; i < DEPTH; i++) begin
            if (!vif.rempty) begin
                if (ref_q.size() > 0) begin
                    automatic logic [7:0] exp = ref_q.pop_front();
                    total_reads++;
                    if (vif.rdata === exp) pass_count++;
                    else begin
                        fail_count++;
                        $display("[%0t] [T04 FAIL] got=0x%02h exp=0x%02h", $time, vif.rdata, exp);
                    end
                end
                vif.rinc = 1;
                @(posedge rclk); #1; vif.rinc = 0;
            end else @(posedge rclk);
        end
        vif.rinc = 0;
        check_rempty("T04 burst-rd");
    endtask

    // -----------------------------------------------------------------------
    // TEST 5: Reset During Active Operation
    // -----------------------------------------------------------------------
    task automatic test_05_reset_in_flight();
        $display("\n// TEST 05: Reset During Active Operation");
        apply_reset();
        for (int i = 0; i < 6; i++) fifo_write(8'(8'hB0 + i));
        vif.wrst_n = 0; vif.rrst_n = 0;
        repeat(5) @(posedge wclk);
        repeat(5) @(posedge rclk);
        vif.wrst_n = 1; vif.rrst_n = 1;
        ref_q.delete();
        repeat(8) @(posedge rclk);
        check_rempty("T05 after reset");
        // Verify FIFO still works post-reset
        fifo_write(8'hDE); fifo_write(8'hAD);
        fifo_read(); fifo_read();
        $display("[%0t] [T05] Post-reset operation OK", $time);
    endtask

    // -----------------------------------------------------------------------
    // TEST 6: Ping-Pong — Write-1 / Read-1 x32
    // -----------------------------------------------------------------------
    task automatic test_06_pingpong();
        $display("\n// TEST 06: Ping-Pong Write-1/Read-1 x32");
        apply_reset();
        for (int i = 0; i < 32; i++) begin
            fifo_write(8'(8'h40 + i));
            fifo_read();
        end
        check_rempty("T06");
    endtask

    // -----------------------------------------------------------------------
    // TEST 7: Pointer Wrap-Around (3 × DEPTH)
    // -----------------------------------------------------------------------
    task automatic test_07_pointer_wrap();
        $display("\n// TEST 07: Gray-Code Pointer Wrap-Around (3 x DEPTH)");
        apply_reset();
        for (int i = 0; i < DEPTH*3; i++) begin
            fifo_write(8'(i & 8'hFF));
            if (i % 3 != 0) fifo_read();
        end
        drain_all();
        check_rempty("T07");
    endtask

    // -----------------------------------------------------------------------
    // TEST 8: Underflow Guard — Read on Empty FIFO
    // -----------------------------------------------------------------------
    task automatic test_08_underflow_guard();
        $display("\n// TEST 08: Underflow Guard");
        apply_reset();
        for (int i = 0; i < 3; i++) begin
            @(posedge rclk); #1;
            vif.rinc = 1;
            @(posedge rclk); #1;
            vif.rinc = 0;
        end
        repeat(4) @(posedge rclk);
        if (vif.rempty)
            $display("[%0t] [T08] Underflow guard PASS", $time);
        else begin
            fail_count++;
            $display("[%0t] [T08] Underflow guard FAIL", $time);
        end
    endtask

    // -----------------------------------------------------------------------
    // TEST 9: Multiple Full-Drain Cycles x4
    // -----------------------------------------------------------------------
    task automatic test_09_full_drain_cycles();
        $display("\n// TEST 09: Full-Drain Cycles x4");
        apply_reset();
        for (int cycle = 0; cycle < 4; cycle++) begin
            for (int i = 0; i < DEPTH; i++)
                fifo_write(8'(cycle*16 + i));
            check_wfull($sformatf("T09 cycle%0d fill", cycle+1));
            drain_all();
            check_rempty($sformatf("T09 cycle%0d drain", cycle+1));
        end
    endtask

    // -----------------------------------------------------------------------
    // TEST 10: Randomized Stress (2 seeds)
    // -----------------------------------------------------------------------
    task automatic test_10_random(input int seed = 42, input int ops = 400);
        logic [DSIZE-1:0] rnd;
        int op;
        $display("\n// TEST 10: Random Stress seed=%0d ops=%0d", seed, ops);
        apply_reset();
        void'($urandom(seed));
        for (int i = 0; i < ops; i++) begin
            op  = $urandom_range(0, 2);
            rnd = $urandom_range(0, 255);
            case (op)
                0: if (!vif.wfull)  fifo_write(rnd);
                1: if (!vif.rempty) fifo_read();
                2: begin @(posedge wclk); @(posedge rclk); end
            endcase
        end
        drain_all();
        check_rempty($sformatf("T10 seed%0d", seed));
    endtask

    // -----------------------------------------------------------------------
    // MAIN STIMULUS
    // -----------------------------------------------------------------------
    initial begin
        $display("\n%0s", {"*"*60});
        $display("  Async FIFO Testbench  |  Xcelium");
        $display("  DSIZE=%0d ASIZE=%0d DEPTH=%0d", DSIZE, ASIZE, DEPTH);
        $display("  wclk=%0dns  rclk=%0dns", WCLK_HALF*2, RCLK_HALF*2);
        $display("%0s\n", {"*"*60});

        vif.winc = 0; vif.rinc = 0;
        vif.wdata = '0;
        vif.wrst_n = 0; vif.rrst_n = 0;
        repeat(10) @(posedge wclk);

        test_01_basic_sequential();
        test_02_fill_and_full();
        test_03_simultaneous_rw();
        test_04_burst();
        test_05_reset_in_flight();
        test_06_pingpong();
        test_07_pointer_wrap();
        test_08_underflow_guard();
        test_09_full_drain_cycles();
        test_10_random(.seed(42),  .ops(400));
        test_10_random(.seed(777), .ops(400));

        $display("\n%0s", {"="*60});
        $display("  SIMULATION COMPLETE");
        $display("  Writes : %0d  |  Reads : %0d", total_writes, total_reads);
        $display("  PASS   : %0d  |  FAIL  : %0d", pass_count, fail_count);
        $display("  %0s", fail_count == 0 ? "*** ALL TESTS PASSED ***" :
                           $sformatf("*** %0d FAILURE(S) ***", fail_count));
        $display("%0s\n", {"="*60});
        $finish;
    end

    // Watchdog
    initial begin
        #10_000_000;
        $display("[TIMEOUT] Forcing exit after 10ms");
        $finish;
    end

    // Waveform
    initial begin
        $dumpfile("sim/tb_async_fifo.vcd");
        $dumpvars(0, tb_async_fifo);
    end

endmodule
