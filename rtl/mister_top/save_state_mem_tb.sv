// Testbench for save_state_mem: exercises the exact DDR-port semantics of
// savestates.sv (single-cycle we around the request toggle, data port bytes
// mutating right after, addr-8 double read, DMA-paced streaming reads) plus
// the data_loader/data_unloader style staging and readback streams, against
// a behavioral model of the sdram.sv port sitting behind the SNES.sv mux.
//
// The model reproduces the two sdram.sv properties the op-scoped port
// borrowing depends on: rd/wr are edge-detected with we latched at the edge
// but addr/din resampled one cycle later (STATE_START), and a read whose
// address matches the previous access degenerates into an auto refresh. A
// free-running console ROM strobe contends for the port through the mux the
// way a fetching SA-1 does.
//
// The SNES.sv ROM_Q hold is replicated as well: a console frozen for a
// pause phase with a fetch pending (the parked SA-1 holds its read strobe
// asserted) must find its own word on ROM_Q at resume, not blob traffic.

`timescale 1ns / 1ps

module synch_3 #(
    parameter WIDTH = 1
) (
    input wire [WIDTH-1:0] i,
    output reg [WIDTH-1:0] o,
    input wire clk,
    output wire rise,
    output wire fall
);
  reg [WIDTH-1:0] s1, s2;
  always @(posedge clk) begin
    s1 <= i;
    s2 <= s1;
    o  <= s2;
  end
  assign rise = 0;
  assign fall = 0;
endmodule

module sdram_model (
    input wire clk,
    input wire [24:0] addr,
    input wire rd,
    input wire wr,
    input wire word,
    input wire [15:0] din,
    output reg [15:0] dout,
    output reg busy = 0,
    input wire rfsh
);
  // 1 MB window indexed by addr[19:1]: covers the blob offsets at SSBASE and
  // the low console fetch addresses used here without collisions (blob
  // offsets stay below 0x1000, console fetches start at 0x1000)
  reg [15:0] mem[0:524287];
  integer refresh_count = 0;  // rfsh input refreshes (arbiter-issued)
  integer auto_ref_count = 0;  // same-address reads turned into refresh
  integer retargets = 0;  // accesses whose addr changed between edge and START
  integer retarget_writes = 0;  // ...of which writes (must stay 0)

  reg old_rd = 0, old_wr = 0, old_rf = 0;
  integer cnt = 0;
  reg [24:0] a_edge;
  reg [24:0] a_lat;
  reg [24:0] a_prev = 25'h1ffffff;
  reg [15:0] d_lat;
  reg we_lat;
  reg start_pending = 0;
  reg auto_ref = 0;

  localparam ACCESS_CYCLES = 6;

  always @(posedge clk) begin
    old_rd <= old_rd & rd;
    old_wr <= old_wr & wr;
    old_rf <= old_rf & rfsh;

    if (!busy) begin
      if ((~old_rd & rd) | (~old_wr & wr)) begin
        old_rd <= rd;
        old_wr <= wr;
        we_lat <= wr;
        a_edge <= addr;
        busy <= 1;
        start_pending <= 1;
        cnt <= ACCESS_CYCLES;
      end else if (~old_rf & rfsh) begin
        old_rf <= rfsh;
        we_lat <= 0;
        a_lat <= 25'h1ffffff;  // no data access
        start_pending <= 0;
        auto_ref <= 0;
        busy <= 1;
        cnt <= ACCESS_CYCLES;
        refresh_count <= refresh_count + 1;
      end
    end else begin
      if (start_pending) begin
        // sdram.sv STATE_START: addr/din sampled one cycle after the edge,
        // so a port mux flip in that cycle retargets the access
        start_pending <= 0;
        a_lat <= addr;
        d_lat <= din;
        if (addr != a_edge) begin
          retargets <= retargets + 1;
          if (we_lat) retarget_writes <= retarget_writes + 1;
        end
        if (~we_lat && addr[24:1] == a_prev[24:1]) begin
          auto_ref <= 1;
          auto_ref_count <= auto_ref_count + 1;
        end else begin
          auto_ref <= 0;
        end
      end
      cnt <= cnt - 1;
      if (cnt == 1) begin
        busy <= 0;
        if (a_lat != 25'h1ffffff && !auto_ref) begin
          if (we_lat) begin
            mem[a_lat[19:1]] <= d_lat;
            a_prev <= 25'h1ffffff;  // a write forces the next read to be real
          end else begin
            dout   <= mem[a_lat[19:1]];
            a_prev <= a_lat;
          end
        end
      end
    end
  end
endmodule

module tb_ss_mem;
  reg clk_sys = 0;
  reg clk_mem = 0;

  always #23.28 clk_sys = ~clk_sys;  // 21.48 MHz
  always #5.82 clk_mem = ~clk_mem;  // 85.9 MHz

  // engine side
  reg [63:0] ss_ddr_do = 0;
  reg [21:3] ss_ddr_addr = 0;
  reg [7:0] ss_ddr_be = 8'hFF;
  reg ss_ddr_we = 0;
  reg ss_ddr_req = 0;
  wire [63:0] ss_ddr_di;
  wire ss_ddr_ack;

  reg ss_busy = 0;
  reg ss_pause = 0;

  reg stage_wr = 0;
  reg [19:0] stage_addr = 0;
  reg [15:0] stage_data = 0;

  reg blob_rd = 0;
  reg [19:0] blob_addr = 0;
  wire [15:0] blob_q;

  wire ss_mem_active;
  wire ss_pause_mem;
  wire [24:0] sd_addr;
  wire [15:0] sd_din;
  wire sd_rd, sd_wr, sd_rfsh;
  wire [15:0] sd_dout;
  wire sd_busy;

  save_state_mem dut (
      .clk_sys(clk_sys),
      .clk_mem(clk_mem),
      .ss_ddr_do(ss_ddr_do),
      .ss_ddr_addr(ss_ddr_addr),
      .ss_ddr_be(ss_ddr_be),
      .ss_ddr_we(ss_ddr_we),
      .ss_ddr_req(ss_ddr_req),
      .ss_ddr_di(ss_ddr_di),
      .ss_ddr_ack(ss_ddr_ack),
      .ss_busy(ss_busy),
      .ss_pause(ss_pause),
      .ss_pause_mem(ss_pause_mem),
      .blocked(1'b0),
      .ctrl_idle(1'b1),
      .stage_lost(),
      .stage_wr(stage_wr),
      .stage_addr(stage_addr),
      .stage_data(stage_data),
      .blob_rd(blob_rd),
      .blob_addr(blob_addr),
      .blob_q(blob_q),
      .ss_mem_active(ss_mem_active),
      .sd_addr(sd_addr),
      .sd_din(sd_din),
      .sd_rd(sd_rd),
      .sd_wr(sd_wr),
      .sd_rfsh(sd_rfsh),
      .sd_dout(sd_dout),
      .sd_busy(sd_busy)
  );

  // Free-running mapper ROM strobe (SA-1 pattern: one read edge per 8
  // clk_mem). console_walk selects a fetching SA-1 (address advances) or the
  // idle/DMA pattern (unchanged address, which the controller must turn into
  // auto refresh).
  reg console_on = 0;
  reg console_walk = 0;
  reg console_sweep = 0;
  // A parked SA-1 (clock enable frozen low) holds its read strobe asserted
  // on a frozen address; the handback edge-detect then re-reads it
  reg console_freeze = 0;
  integer console_period = 8;
  reg [23:0] rom_addr = 24'h001000;
  reg rom_rd_lvl = 0;
  integer con_ph = 0;
  always @(posedge clk_mem) begin
    if (console_freeze) begin
      rom_rd_lvl <= 1;
    end else if (console_on) begin
      con_ph <= (con_ph >= console_period - 1) ? 0 : con_ph + 1;
      rom_rd_lvl <= (con_ph < 4);
      if (con_ph == 0) begin
        if (console_walk) rom_addr <= rom_addr + 24'd2;
        // rotate the period so the strobe phase sweeps every residue of the
        // clk_sys-locked op-start grid
        if (console_sweep)
          console_period <= (console_period == 9) ? 7 : (console_period == 7) ? 10 : 9;
      end
    end else begin
      rom_rd_lvl <= 0;
      con_ph <= 0;
    end
  end

  // SNES.sv SDRAM port mux (cart_download = 0, RESET_N = 1, ROM_WE_N = 1 on
  // every save state capable mapper, so the console side never writes)
  wire [24:0] mem_addr = ss_mem_active ? sd_addr : {1'b0, rom_addr};
  wire [15:0] mem_din = ss_mem_active ? sd_din : 16'h0000;
  wire mem_rd = ss_mem_active ? sd_rd : rom_rd_lvl;
  wire mem_wr = ss_mem_active ? sd_wr : 1'b0;

  sdram_model sdram (
      .clk(clk_mem),
      .addr(mem_addr),
      .rd(mem_rd),
      .wr(mem_wr),
      .word(1'b1),
      .din(mem_din),
      .dout(sd_dout),
      .busy(sd_busy),
      .rfsh(sd_rfsh)
  );

  // SNES.sv ROM_Q hold replica (boot1 overlay not modeled): hold the last
  // pre-pause word until the first console owned access after the pause
  // completes
  reg [15:0] rom_q_hold = 0;
  reg hold_rom_q = 0;
  reg sd_busy_d = 0;
  always @(posedge clk_mem) begin
    sd_busy_d <= sd_busy;
    if (ss_pause_mem) hold_rom_q <= 1;
    else if (~ss_mem_active && sd_busy_d && ~sd_busy) hold_rom_q <= 0;
    if (~hold_rom_q) rom_q_hold <= sd_dout;
  end
  wire [15:0] ROM_Q = hold_rom_q ? rom_q_hold : sd_dout;

  // Continuous ROM_Q watcher for the frozen console window
  reg rom_q_watch = 0;
  reg [15:0] golden = 0;
  integer rom_q_err = 0;
  always @(posedge clk_mem) begin
    if (rom_q_watch && ROM_Q !== golden) rom_q_err = rom_q_err + 1;
  end

  integer errors = 0;

  // Monitors: DUT-issued SDRAM strobes, port steal events, and the op-scoped
  // invariant (the port may only be held during pause phases or while the
  // arbiter runs an operation)
  integer dut_ops = 0;
  integer steal_events = 0;
  integer walk_idle_steal = 0;
  reg prev_dut_req = 0;
  reg prev_active = 0;
  always @(posedge clk_mem) begin
    prev_dut_req <= sd_rd | sd_wr | sd_rfsh;
    if (~prev_dut_req & (sd_rd | sd_wr | sd_rfsh)) dut_ops = dut_ops + 1;
    prev_active <= ss_mem_active;
    if (~prev_active & ss_mem_active) steal_events = steal_events + 1;
    if (ss_mem_active && dut.arb_state == 3'd0 && !dut.ss_pause_m)
      walk_idle_steal = walk_idle_steal + 1;
  end

  // Engine-accurate qword write: we/addr/data valid at the toggle edge, we
  // drops one cycle later, data port may mutate ddr_do shortly after
  // (savestates.sv zeroes ddr_do[63:8] when the next qword's byte 0 lands)
  task eng_write(input [16:0] qaddr, input [63:0] data);
    integer waits;
    begin
      @(posedge clk_sys);
      ss_ddr_addr <= {1'b0, 1'b0, qaddr};
      ss_ddr_do <= data;
      ss_ddr_we <= 1;
      ss_ddr_req <= ~ss_ddr_req;
      @(posedge clk_sys);
      ss_ddr_we <= 0;  // exactly one cycle, like savestates.sv
      @(posedge clk_sys);
      @(posedge clk_sys);
      ss_ddr_do <= 64'h00000000000000AA;  // next byte mangles the data port
      waits = 0;
      while (ss_ddr_req != ss_ddr_ack) begin
        @(posedge clk_sys);
        waits = waits + 1;
        if (waits > 64) begin
          $display("FAIL: write ack timeout qaddr=%0d", qaddr);
          errors = errors + 1;
          disable eng_write;
        end
      end
    end
  endtask

  // Engine-accurate qword read; returns ack latency in clk_sys cycles
  task eng_read(input [16:0] qaddr, output [63:0] data, output integer lat);
    begin
      @(posedge clk_sys);
      ss_ddr_addr <= {1'b0, 1'b0, qaddr};
      ss_ddr_we <= 0;
      ss_ddr_req <= ~ss_ddr_req;
      lat = 0;
      @(posedge clk_sys);
      while (ss_ddr_req != ss_ddr_ack) begin
        @(posedge clk_sys);
        lat = lat + 1;
        if (lat > 200) begin
          $display("FAIL: read ack timeout qaddr=%0d", qaddr);
          errors = errors + 1;
          disable eng_read;
        end
      end
      data = ss_ddr_di;
    end
  endtask

  function [63:0] pattern(input [16:0] q);
    pattern = {4{13'h0AB5, q[15:0]}} ^ 64'h0123456789ABCDEF;
  endfunction

  integer i, lat, snap, snap2, err_snap;
  reg [63:0] rd_data;
  integer worst_hit_lat;

  // Deterministic background so console fetches outside the blob region
  // return known data instead of x
  integer i2;
  initial begin
    for (i2 = 0; i2 < 524288; i2 = i2 + 1) sdram.mem[i2] = i2[15:0] ^ 16'hA55A;
  end

  initial begin
    // ------------------------------------------------------------------
    // SAVE: body qwords 1..63 written sequentially, header last at 0
    ss_busy = 1;
    for (i = 1; i < 64; i = i + 1) begin
      eng_write(i[16:0], pattern(i[16:0]));
      repeat (30) @(posedge clk_sys);  // DMA pace
    end
    eng_write(17'd0, 64'h00010200_00000001);  // WRITE_CNTSIZE
    ss_busy = 0;
    repeat (20) @(posedge clk_sys);

    // verify memory (word granularity)
    err_snap = errors;
    for (i = 1; i < 64; i = i + 1) begin
      if ({sdram.mem[i*4+3], sdram.mem[i*4+2], sdram.mem[i*4+1], sdram.mem[i*4]} != pattern(
              i[16:0]
          )) begin
        $display("FAIL: save qword %0d = %h expected %h", i, {sdram.mem[i*4+3], sdram.mem[i*4+2],
                                                              sdram.mem[i*4+1], sdram.mem[i*4]},
                 pattern(i[16:0]));
        errors = errors + 1;
      end
    end
    if ({sdram.mem[3], sdram.mem[2], sdram.mem[1], sdram.mem[0]} != 64'h00010200_00000001) begin
      $display("FAIL: header qword = %h", {sdram.mem[3], sdram.mem[2], sdram.mem[1], sdram.mem[0]});
      errors = errors + 1;
    end else if (errors == err_snap) $display("PASS: save side, header written last at 0");

    // ------------------------------------------------------------------
    // Byte enables: the engine's 8'hF0 header rewrite must preserve the
    // count field (bytes 0-3) and update only the size half (bytes 4-7)
    ss_busy   = 1;
    ss_ddr_be = 8'hF0;
    eng_write(17'd0, 64'hDEADBEEF_A5A55A5A);
    ss_ddr_be = 8'hFF;
    ss_busy   = 0;
    repeat (20) @(posedge clk_sys);
    if ({sdram.mem[3], sdram.mem[2]} != 32'hDEADBEEF) begin
      $display("FAIL: BE write upper half = %h expected deadbeef", {sdram.mem[3], sdram.mem[2]});
      errors = errors + 1;
    end else if ({sdram.mem[1], sdram.mem[0]} != 32'h00000001) begin
      $display("FAIL: BE write clobbered the count field: %h", {sdram.mem[1], sdram.mem[0]});
      errors = errors + 1;
    end else $display("PASS: byte enables skip the masked half words");

    // ------------------------------------------------------------------
    // READBACK: console frozen, unloader-style reads
    ss_pause = 1;
    repeat (10) @(posedge clk_mem);
    err_snap = errors;
    for (i = 0; i < 16; i = i + 1) begin
      @(posedge clk_mem);
      blob_addr <= i[19:0] * 2;
      blob_rd   <= 1;
      @(posedge clk_mem);
      blob_rd <= 0;
      repeat (31) @(posedge clk_mem);  // READ_MEM_CLOCK_DELAY(32)
      if (blob_q != sdram.mem[i]) begin
        $display("FAIL: blob read %0d = %h expected %h", i, blob_q, sdram.mem[i]);
        errors = errors + 1;
      end
    end
    if (errors == err_snap) $display("PASS: readback words match memory");
    ss_pause = 0;
    repeat (20) @(posedge clk_mem);

    // ------------------------------------------------------------------
    // LOAD staging: loader-style 16 bit writes while frozen
    ss_pause = 1;
    repeat (10) @(posedge clk_mem);
    for (i = 0; i < 256; i = i + 1) begin
      @(posedge clk_mem);
      stage_addr <= i[19:0] * 2;
      stage_data <= 16'hC000 | i[15:0];
      stage_wr   <= 1;
      @(posedge clk_mem);
      stage_wr <= 0;
      repeat (14) @(posedge clk_mem);  // WRITE_MEM_CLOCK_DELAY(16)
    end
    repeat (100) @(posedge clk_mem);
    err_snap = errors;
    for (i = 0; i < 256; i = i + 1) begin
      if (sdram.mem[i] != (16'hC000 | i[15:0])) begin
        $display("FAIL: staged word %0d = %h", i, sdram.mem[i]);
        errors = errors + 1;
      end
    end
    if (errors == err_snap) $display("PASS: staging landed in memory");
    ss_pause = 0;
    repeat (20) @(posedge clk_sys);

    // ------------------------------------------------------------------
    // LOAD: READ_HEAD at qword 1, re-read qword 1, then DMA-paced stream.
    // Streaming hits must ack fast enough for the no-wait data port (the
    // helper consumes a byte every ~8 clk_sys, so a whole qword every ~64).
    ss_busy = 1;
    worst_hit_lat = 0;

    eng_read(17'd1, rd_data, lat);  // READ_HEAD (miss, covered by busy poll)
    if (rd_data != {sdram.mem[7], sdram.mem[6], sdram.mem[5], sdram.mem[4]}) begin
      $display("FAIL: READ_HEAD data %h", rd_data);
      errors = errors + 1;
    end

    eng_read(17'd1, rd_data, lat);  // engine re-reads qword 1 after SSADDR
    if (rd_data != {sdram.mem[7], sdram.mem[6], sdram.mem[5], sdram.mem[4]}) begin
      $display("FAIL: addr-8 re-read data %h", rd_data);
      errors = errors + 1;
    end

    for (i = 2; i < 64; i = i + 1) begin
      repeat (56) @(posedge clk_sys);  // rest of the qword's DMA time
      eng_read(i[16:0], rd_data, lat);
      if (rd_data != {sdram.mem[i*4+3], sdram.mem[i*4+2], sdram.mem[i*4+1], sdram.mem[i*4]}) begin
        $display("FAIL: stream qword %0d = %h", i, rd_data);
        errors = errors + 1;
      end
      if (lat > worst_hit_lat) worst_hit_lat = lat;
    end
    if (worst_hit_lat > 8) begin
      $display("FAIL: stream hit latency %0d cycles (no-wait budget ~8)", worst_hit_lat);
      errors = errors + 1;
    end else $display("PASS: load stream, worst hit latency %0d clk_sys", worst_hit_lat);
    ss_busy = 0;
    repeat (20) @(posedge clk_mem);

    // ------------------------------------------------------------------
    // WALK PRE-PARK (save): walk armed, engine silent. The console keeps
    // the port, the DUT must not issue a single SDRAM strobe, and the
    // console's unchanged-address strobe must register as auto refresh.
    console_on = 1;
    console_walk = 0;
    repeat (20) @(posedge clk_mem);
    snap  = dut_ops;
    snap2 = sdram.auto_ref_count;
    ss_busy = 1;
    repeat (3000) @(posedge clk_mem);
    ss_busy = 0;
    if (dut_ops != snap) begin
      $display("FAIL: DUT issued %0d SDRAM ops during an op-less walk", dut_ops - snap);
      errors = errors + 1;
    end else if (sdram.auto_ref_count == snap2) begin
      $display("FAIL: console strobe produced no auto refresh during the walk");
      errors = errors + 1;
    end else
      $display("PASS: op-less walk leaves the port to the console (%0d auto refreshes)",
               sdram.auto_ref_count - snap2);
    repeat (20) @(posedge clk_mem);

    // ------------------------------------------------------------------
    // SAVE under contention: a fetching SA-1 strobes the port through the
    // whole walk. Blob must land intact, acks must stay inside the engine
    // budget (eng_write enforces 64 clk_sys), and the DUT must not issue
    // its own refresh cycles mid-walk.
    console_walk = 1;
    if (hold_rom_q) begin
      $display("FAIL: ROM_Q hold armed outside a pause phase");
      errors = errors + 1;
    end
    snap = sdram.refresh_count;
    ss_busy = 1;
    for (i = 1; i < 64; i = i + 1) begin
      eng_write(i[16:0], pattern(i[16:0]) ^ 64'h5A5A);
      repeat (30) @(posedge clk_sys);
    end
    eng_write(17'd0, 64'h00010200_000000AB);
    ss_busy = 0;
    repeat (20) @(posedge clk_sys);
    for (i = 1; i < 64; i = i + 1) begin
      if ({sdram.mem[i*4+3], sdram.mem[i*4+2], sdram.mem[i*4+1], sdram.mem[i*4]} !=
          (pattern(i[16:0]) ^ 64'h5A5A)) begin
        $display("FAIL: contended save qword %0d = %h", i, {sdram.mem[i*4+3], sdram.mem[i*4+2],
                                                            sdram.mem[i*4+1], sdram.mem[i*4]});
        errors = errors + 1;
      end
    end
    if (sdram.refresh_count != snap) begin
      $display("FAIL: DUT issued %0d refresh cycles during the walk", sdram.refresh_count - snap);
      errors = errors + 1;
    end else $display("PASS: contended save intact, no DUT refresh mid-walk");

    // ------------------------------------------------------------------
    // Retarget window sweep: the real SA-1 strobe and the op starts both sit
    // on the clk_sys grid, so their phase is fixed; a period-rotating strobe
    // sweeps every phase and forces the mux flip onto the edge-detect cycle,
    // retargeting that console read into the blob window. The blob must
    // survive and no retargeted access may be a write.
    console_sweep = 1;
    snap = sdram.retargets;
    ss_busy = 1;
    for (i = 1; i < 64; i = i + 1) begin
      eng_write(i[16:0], pattern(i[16:0]) ^ 64'hFACE);
      repeat (30) @(posedge clk_sys);
    end
    eng_write(17'd0, 64'h00010200_000000CD);
    ss_busy = 0;
    console_sweep = 0;
    console_period = 8;
    repeat (20) @(posedge clk_sys);
    for (i = 1; i < 64; i = i + 1) begin
      if ({sdram.mem[i*4+3], sdram.mem[i*4+2], sdram.mem[i*4+1], sdram.mem[i*4]} !=
          (pattern(i[16:0]) ^ 64'hFACE)) begin
        $display("FAIL: window-sweep save qword %0d = %h", i, {sdram.mem[i*4+3], sdram.mem[i*4+2],
                                                               sdram.mem[i*4+1], sdram.mem[i*4]});
        errors = errors + 1;
      end
    end
    if (sdram.retargets == snap) begin
      $display("FAIL: retarget window never exercised by the sweep");
      errors = errors + 1;
    end else
      $display("PASS: %0d retargeted reads swept, blob intact", sdram.retargets - snap);

    // ------------------------------------------------------------------
    // LOAD pre-park: READ_HEAD runs pause-protected; once the pause drops,
    // the helper's SSADDR preload must steal the port exactly twice
    // (direct read + chained prefetch) before any stream traffic.
    ss_pause = 1;
    repeat (10) @(posedge clk_mem);
    eng_read(17'd1, rd_data, lat);  // READ_HEAD under pause
    repeat (10) @(posedge clk_mem);
    ss_pause = 0;
    repeat (10) @(posedge clk_mem);  // pause_m settles, steal drops
    ss_busy = 1;
    repeat (10) @(posedge clk_mem);
    snap = steal_events;
    eng_read(17'd1, rd_data, lat);  // helper's SSADDR preload re-read
    repeat (200) @(posedge clk_mem);  // let the chained prefetch drain
    if (steal_events - snap != 2) begin
      $display("FAIL: SSADDR preload stole the port %0d times (expected 2)", steal_events - snap);
      errors = errors + 1;
    end else $display("PASS: load pre-park steals the port exactly twice");
    if (rd_data != {sdram.mem[7], sdram.mem[6], sdram.mem[5], sdram.mem[4]}) begin
      $display("FAIL: preload data %h", rd_data);
      errors = errors + 1;
    end
    ss_busy = 0;
    console_on = 0;
    repeat (20) @(posedge clk_mem);

    // ------------------------------------------------------------------
    // Pause with a pending console fetch: the parked SA-1 froze with its
    // read strobe asserted and its last fetched word unconsumed. ROM_Q must
    // carry that word through the whole readback (blob traffic trashes
    // sd_dout) and still carry it at resume, when the handback re-read
    // refreshes it and releases the hold.
    console_on = 1;
    console_walk = 1;
    repeat (100) @(posedge clk_mem);  // live fetches release any stale hold
    if (hold_rom_q) begin
      $display("FAIL: ROM_Q hold armed before the pending-fetch pause");
      errors = errors + 1;
    end
    console_freeze = 1;
    repeat (20) @(posedge clk_mem);  // in-flight access settles
    golden = ROM_Q;
    if (golden !== sdram.mem[rom_addr[19:1]]) begin
      $display("FAIL: pre-pause ROM_Q %h does not match memory %h", golden,
               sdram.mem[rom_addr[19:1]]);
      errors = errors + 1;
    end
    rom_q_err = 0;
    rom_q_watch = 1;
    ss_pause = 1;
    repeat (10) @(posedge clk_mem);
    for (i = 0; i < 16; i = i + 1) begin  // readback traffic trashes sd_dout
      @(posedge clk_mem);
      blob_addr <= i[19:0] * 2;
      blob_rd   <= 1;
      @(posedge clk_mem);
      blob_rd <= 0;
      repeat (31) @(posedge clk_mem);
    end
    if (sd_dout == golden) begin
      $display("FAIL: readback left sd_dout untouched; scenario is vacuous");
      errors = errors + 1;
    end
    ss_pause = 0;
    repeat (64) @(posedge clk_mem);  // handback, re-read, hold release
    rom_q_watch = 0;
    if (hold_rom_q) begin
      $display("FAIL: hold not released by the handback re-read");
      errors = errors + 1;
    end
    if (rom_q_err == 0 && ROM_Q === golden)
      $display("PASS: pending fetch word held across the pause");
    else begin
      $display("FAIL: ROM_Q lost the pending word (%0d bad samples, final %h expected %h)",
               rom_q_err, ROM_Q, golden);
      errors = errors + 1;
    end
    console_freeze = 0;
    repeat (40) @(posedge clk_mem);  // live fetches resume
    if (hold_rom_q || ROM_Q !== sd_dout) begin
      $display("FAIL: ROM_Q path not transparent after resume");
      errors = errors + 1;
    end else $display("PASS: ROM_Q live again after resume");
    console_on = 0;
    repeat (20) @(posedge clk_mem);

    // ------------------------------------------------------------------
    if (sdram.refresh_count == 0) begin
      $display("FAIL: no refresh cycles were issued in the pause phases");
      errors = errors + 1;
    end else $display("PASS: %0d refresh cycles issued (pause phases)", sdram.refresh_count);

    if (walk_idle_steal != 0) begin
      $display("FAIL: port held %0d cycles with the walk arbiter idle", walk_idle_steal);
      errors = errors + 1;
    end else $display("PASS: port only held during pause phases or operations");

    if (sdram.retarget_writes != 0) begin
      $display("FAIL: %0d retargeted WRITES observed", sdram.retarget_writes);
      errors = errors + 1;
    end
    $display("INFO: %0d retargeted reads observed (benign by design)", sdram.retargets);

    if (errors == 0) $display("ALL TESTS PASSED");
    else $display("%0d ERRORS", errors);
    $finish;
  end
endmodule
