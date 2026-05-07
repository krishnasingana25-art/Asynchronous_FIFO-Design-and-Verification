
//==============================================================================
// File        : fifo_if.sv
// Description : SystemVerilog Interface for Async FIFO DUT
//==============================================================================
interface fifo_if #(parameter DSIZE = 8, parameter ASIZE = 4) (
    input logic wclk,
    input logic rclk
);
    logic [DSIZE-1:0] wdata;
    logic [DSIZE-1:0] rdata;
    logic             winc;
    logic             rinc;
    logic             wrst_n;
    logic             rrst_n;
    logic             wfull;
    logic             rempty;

    // Write-side clocking block
    clocking wdrv @(posedge wclk);
        default input #1 output #1;
        output wdata, winc, wrst_n;
        input  wfull;
    endclocking

    // Read-side clocking block
    clocking rdrv @(posedge rclk);
        default input #1 output #1;
        output rinc, rrst_n;
        input  rdata, rempty;
    endclocking

    // Write-side monitor
    clocking wmon @(posedge wclk);
        default input #1;
        input wdata, winc, wrst_n, wfull;
    endclocking

    // Read-side monitor
    clocking rmon @(posedge rclk);
        default input #1;
        input rdata, rinc, rrst_n, rempty;
    endclocking

endinterface
