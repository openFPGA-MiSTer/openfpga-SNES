// Save state memory transport.
//
// Bridges the save state engine (savestates.sv) and the APF bridge streams to
// the cart SDRAM, where the state blob lives at SSBASE (well above the
// largest cart image). MiSTer stores the blob in HPS DDR3; the Pocket has no
// equivalent, and the APF bridge cannot serve the engine directly:
//
//  - During a save the helper program DMAs bytes into the engine with no
//    flow control, so a queued 64 bit word must be retired within ~64 core
//    clocks or it is overwritten. Only a local memory write is fast enough.
//  - During a load the engine re-reads the header qword and then consumes
//    the stream at DMA pace without waiting, so reads must be served from
//    local memory, with the next sequential qword prefetched while the
//    helper drains the current one.
//
// The SDRAM port is borrowed continuously while the console is frozen (blob
// upload / readback), but only per operation during the engine walk. On SA-1
// carts the coprocessor keeps executing game ROM until the helper program
// parks it through the $2200 NMI hijack, so the ROM path must stay live
// between operations or the SA-1 fetches stale data, executes garbage and
// corrupts the very state being captured. The helper parks the SA-1 before
// it touches the blob stream in both directions (sa1_save_init precedes the
// header write, sa1_load_init precedes the first SSDATA read), so on a save
// no operation can steal the port before the park; on a load only the two
// reads triggered by the SSADDR reset can, and everything the SA-1 could
// disturb in that window is overwritten by the restore anyway.
//
// While the port is borrowed for staging this module issues periodic auto
// refresh, because the normal refresh source is gone and both the cart image
// and the blob have to survive multi second APF transfers. During the walk
// no refresh is needed from here: the mapper's ROM read strobe free-runs on
// the CE clocks even while the CPU sits in DMA or a spin loop, and the SDRAM
// controller turns repeated reads of an unchanged address into auto refresh.
//
// The continuous borrowing during ss_pause is only safe under the console
// freeze contract: the S-CPU clock enables stop, the SA-1 parks its clock
// enable (SA1.vhd PAUSE), the GSU quiesces through its SS_BUSY freeze, and
// SNES.sv holds ROM_Q at its pre-pause value (using ss_pause_mem from here)
// so a master frozen between fetch and consume still finds its own word on
// resume instead of blob traffic.

module save_state_mem #(
    // Byte address of the state blob in SDRAM. The 1MB left to the top of
    // the 32MB SDRAM must cover the largest blob core_top declares
    // (SS_BLOB_FIXED + 128KB cart RAM = 0x64000): grow that past 1MB and
    // SSBASE has to move down with it.
    parameter logic [24:0] SSBASE = 25'h1F0_0000
) (
    input wire clk_sys,
    input wire clk_mem,

    // Save state engine, clk_sys domain (toggle handshake, see savestates.sv)
    input wire [63:0] ss_ddr_do,
    input wire [21:3] ss_ddr_addr,
    input wire [7:0] ss_ddr_be,
    input wire ss_ddr_we,
    input wire ss_ddr_req,
    output reg [63:0] ss_ddr_di = 0,
    output reg ss_ddr_ack = 0,

    input wire ss_busy,   // engine walk active (clk_sys)
    input wire ss_pause,  // console frozen for blob upload/readback (clk_sys)
    output wire ss_pause_mem,  // ss_pause seen from clk_mem, for the ROM_Q hold

    // While a cart download owns the SDRAM port every access issued from
    // here is silently dropped by the port mux, and the busy edges of the
    // foreign traffic would be mistaken for completions of our own. Park
    // the arbiter instead and let the stage queue absorb the overlap.
    input wire blocked,    // cart download active (clk_sys)
    input wire ctrl_idle,  // command sequencer idle (clk_sys)
    output reg stage_lost = 0,  // stage queue overflowed, blob is torn (clk_mem)

    // Blob staging stream from data_loader, clk_mem domain
    input wire stage_wr,
    input wire [19:0] stage_addr,
    input wire [15:0] stage_data,

    // Blob readback stream to data_unloader, clk_mem domain
    input wire blob_rd,
    input wire [19:0] blob_addr,
    output reg [15:0] blob_q = 0,

    // Borrowed SDRAM port, clk_mem domain
    output wire ss_mem_active,
    output reg [24:0] sd_addr = 0,
    output reg [15:0] sd_din = 0,
    output reg sd_rd = 0,
    output reg sd_wr = 0,
    output reg sd_rfsh = 0,
    input wire [15:0] sd_dout,
    input wire sd_busy
);

  //////////////////////////////////////////////////////////////////////////
  // clk_sys side: engine qword commands with sequential read prefetch

  reg [16:0] cmd_qaddr = 0;  // qword index within the blob
  reg [63:0] cmd_data = 0;
  reg [7:0] cmd_be = 8'hFF;
  reg cmd_we = 0;
  reg cmd_go = 0;  // toggle
  wire cmd_done_s;

  reg [63:0] rsp_data = 0;  // written by clk_mem side, read after done toggles
  reg cmd_done = 0;  // toggle, clk_mem side

  reg [63:0] pf_data = 0;
  reg [16:0] pf_qaddr = 0;
  reg pf_valid = 0;

  reg prev_req = 0;
  reg prev_done = 0;
  reg prev_busy = 0;
  reg req_pending = 0;

  // The engine asserts ddr_we (and updates address/data) for a single cycle
  // around the request toggle, so everything must be captured right when the
  // toggle is seen, not when the request is serviced
  reg [16:0] req_qaddr_r = 0;
  reg [63:0] req_data_r = 0;
  reg [7:0] req_be_r = 8'hFF;
  reg req_we_r = 0;

  synch_3 cmd_done_sync (
      cmd_done,
      cmd_done_s,
      clk_sys
  );

  localparam ENG_IDLE = 2'd0;
  localparam ENG_WAIT_DIRECT = 2'd1;
  localparam ENG_WAIT_PF = 2'd2;

  reg [1:0] eng_state = ENG_IDLE;

  // Bits [21:20] of the engine address carry its save slot index
  // (savestates.sv: ddr_addr = {ss_slot, ss_ddr_addr[19:3]}), deliberately
  // dropped: SNES.sv ties SS_SLOT to 2'd0, and SSBASE sits 1 MB below the
  // top of the 32 MB SDRAM, so there is no room for a 4 MB slotted window.
  // Wiring multi slot support later means moving SSBASE and widening this.
  wire [16:0] req_qaddr = ss_ddr_addr[19:3];

  always @(posedge clk_sys) begin
    prev_req  <= ss_ddr_req;
    prev_busy <= ss_busy;
    prev_done <= cmd_done_s;

    // A new walk must never hit stale prefetch data from the previous one
    if (ss_busy != prev_busy) pf_valid <= 0;

    if (ss_ddr_req != prev_req) begin
      req_pending <= 1;
      req_qaddr_r <= req_qaddr;
      req_data_r <= ss_ddr_do;
      req_be_r <= ss_ddr_be;
      req_we_r <= ss_ddr_we;
    end

    case (eng_state)
      ENG_IDLE: begin
        if (req_pending) begin
          req_pending <= 0;

          if (req_we_r) begin
            cmd_qaddr <= req_qaddr_r;
            cmd_data <= req_data_r;
            cmd_be <= req_be_r;
            cmd_we <= 1;
            cmd_go <= ~cmd_go;
            eng_state <= ENG_WAIT_DIRECT;
          end else if (pf_valid && pf_qaddr == req_qaddr_r) begin
            // Sequential stream hit: answer immediately, refill the buffer
            ss_ddr_di <= pf_data;
            ss_ddr_ack <= ~ss_ddr_ack;
            pf_valid <= 0;
            cmd_qaddr <= req_qaddr_r + 1'd1;
            cmd_we <= 0;
            cmd_go <= ~cmd_go;
            eng_state <= ENG_WAIT_PF;
          end else begin
            // Miss: the helper program polls the busy flag across this
            cmd_qaddr <= req_qaddr_r;
            cmd_we <= 0;
            cmd_go <= ~cmd_go;
            eng_state <= ENG_WAIT_DIRECT;
          end
        end
      end

      ENG_WAIT_DIRECT: begin
        if (cmd_done_s != prev_done) begin
          if (~cmd_we) ss_ddr_di <= rsp_data;
          ss_ddr_ack <= ~ss_ddr_ack;

          if (~cmd_we) begin
            // Chain the prefetch of the next sequential qword
            cmd_qaddr <= cmd_qaddr + 1'd1;
            cmd_go <= ~cmd_go;
            eng_state <= ENG_WAIT_PF;
          end else begin
            eng_state <= ENG_IDLE;
          end
        end
      end

      ENG_WAIT_PF: begin
        if (cmd_done_s != prev_done) begin
          pf_data <= rsp_data;
          pf_qaddr <= cmd_qaddr;
          pf_valid <= 1;
          eng_state <= ENG_IDLE;
        end
      end
    endcase
  end

  //////////////////////////////////////////////////////////////////////////
  // clk_mem side: SDRAM arbiter

  wire cmd_go_m;
  wire ss_busy_m;
  wire ss_pause_m;
  wire blocked_m;
  wire ctrl_idle_m;

  synch_3 cmd_go_sync (
      cmd_go,
      cmd_go_m,
      clk_mem
  );

  synch_3 #(
      .WIDTH(4)
  ) status_sync (
      {ss_busy, ss_pause, blocked, ctrl_idle},
      {ss_busy_m, ss_pause_m, blocked_m, ctrl_idle_m},
      clk_mem
  );

  reg prev_go_m = 0;
  reg cmd_pending = 0;

  // Queue for data_loader write bursts so no pulse is ever dropped. Deep
  // enough (one M10K pair) to also ride out a cart download that is still
  // winding down when the firmware starts writing the blob.
  reg [35:0] stage_fifo[512];
  reg [35:0] stage_q = 0;
  reg [9:0] stage_wp = 0, stage_rp = 0;
  wire stage_pending = stage_wp != stage_rp;
  wire stage_full = (stage_wp - stage_rp) == 10'd512;

  // Registered read so the array infers as block RAM. The arbiter only
  // consumes stage_q two cycles after the pointers move, which covers the
  // one cycle of read latency.
  always @(posedge clk_mem) begin
    if (stage_wr && ~stage_full) begin
      stage_fifo[stage_wp[8:0]] <= {stage_addr, stage_data};
    end
    stage_q <= stage_fifo[stage_rp[8:0]];
  end

  always @(posedge clk_mem) begin
    if (stage_wr) begin
      if (stage_full) stage_lost <= 1;
      else stage_wp <= stage_wp + 1'd1;
    end
    if (ctrl_idle_m) stage_lost <= 0;
  end

  reg blob_pending = 0;
  reg [19:0] blob_addr_r = 0;

  // Periodic refresh while this module owns the bus
  reg [8:0] ref_cnt = 0;
  wire ref_due = ref_cnt[8];  // every 256 clk_mem cycles (~3 us)

  localparam ARB_IDLE = 3'd0;
  localparam ARB_CMD = 3'd1;
  localparam ARB_STAGE = 3'd2;
  localparam ARB_BLOB = 3'd3;
  localparam ARB_REFRESH = 3'd4;

  localparam ACC_SETUP = 2'd0;
  localparam ACC_WAIT_BUSY = 2'd1;
  localparam ACC_WAIT_DONE = 2'd2;
  localparam ACC_GAP = 2'd3;

  reg [2:0] arb_state = ARB_IDLE;
  reg [1:0] acc_state = ACC_SETUP;
  reg [1:0] beat = 0;

  // Grabbing the port mid-access is safe: the controller edge-detects rd/wr
  // and finishes an in-flight access from latched state. If the grab lands on
  // the exact cycle a console read is edge-detected, the address is resampled
  // one cycle later (already ours) and that read is retargeted into the blob
  // window; harmless, because every save state capable mapper ties ROM_WE_N
  // high and the retargeted data has no consumer while the walk runs from the
  // boot1 overlay.
  assign ss_mem_active = ss_pause_m | (arb_state != ARB_IDLE);
  assign ss_pause_mem = ss_pause_m;

  always @(posedge clk_mem) begin
    prev_go_m <= cmd_go_m;
    if (cmd_go_m != prev_go_m) cmd_pending <= 1;

    if (ss_mem_active) begin
      if (~ref_due) ref_cnt <= ref_cnt + 1'd1;
    end else begin
      ref_cnt <= 0;
    end

    if (blob_rd) begin
      blob_addr_r  <= blob_addr;
      blob_pending <= 1;
    end

    case (arb_state)
      ARB_IDLE: begin
        acc_state <= ACC_SETUP;
        beat <= 0;

        // All accesses stay parked while a download owns the port
        if (cmd_pending && ~blocked_m) begin
          cmd_pending <= 0;
          arb_state   <= ARB_CMD;
        end else if (stage_pending && ~blocked_m) begin
          arb_state <= ARB_STAGE;
        end else if (blob_pending && ~blocked_m) begin
          arb_state <= ARB_BLOB;
        end else if (ref_due && ss_mem_active && ~blocked_m) begin
          // Never refresh while a download owns the port: the SDRAM
          // controller only samples write pulses when idle, so a refresh
          // cycle would swallow download words and corrupt the cart image
          arb_state <= ARB_REFRESH;
        end
      end

      ARB_CMD: begin
        case (acc_state)
          ACC_SETUP:
          if (cmd_we && cmd_be[{beat, 1'b0}+:2] == 2'b00) begin
            // Engine byte enables skip this half word (the 8'hF0 header
            // write preserves the count field). Mixed pairs degrade to a
            // full write: sdram.sv has no per byte masking for word writes
            // and the engine only ever emits 00 or 11 pairs.
            acc_state <= ACC_GAP;
          end else if (~sd_busy && ~blocked_m) begin
            sd_addr <= SSBASE | {cmd_qaddr, beat, 1'b0};
            sd_din <= cmd_data[{3'b000, beat, 4'b0000}+:16];
            sd_rd <= ~cmd_we;
            sd_wr <= cmd_we;
            acc_state <= ACC_WAIT_BUSY;
          end
          ACC_WAIT_BUSY: if (sd_busy) acc_state <= ACC_WAIT_DONE;
          ACC_WAIT_DONE:
          if (~sd_busy) begin
            if (~cmd_we) rsp_data[{3'b000, beat, 4'b0000}+:16] <= sd_dout;
            sd_rd <= 0;
            sd_wr <= 0;
            acc_state <= ACC_GAP;
          end
          ACC_GAP: begin
            acc_state <= ACC_SETUP;
            beat <= beat + 1'd1;
            if (beat == 2'd3) begin
              cmd_done  <= ~cmd_done;
              arb_state <= ARB_IDLE;
            end
          end
        endcase
      end

      ARB_STAGE: begin
        case (acc_state)
          ACC_SETUP:
          if (~sd_busy && ~blocked_m) begin
            sd_addr <= SSBASE | stage_q[35:16];
            sd_din <= stage_q[15:0];
            sd_wr <= 1;
            acc_state <= ACC_WAIT_BUSY;
          end
          ACC_WAIT_BUSY:
          if (sd_busy) acc_state <= ACC_WAIT_DONE;
          else if (blocked_m) begin
            // A download flips the SDRAM port mux before blocked_m parks
            // the arbiter. If the controller never saw this write edge, a
            // busy pulse from the download would fake completion and the
            // word would be lost without setting stage_lost. Retract and
            // retry the same word once the download releases the port.
            sd_wr <= 0;
            acc_state <= ACC_SETUP;
          end
          ACC_WAIT_DONE:
          if (~sd_busy) begin
            sd_wr <= 0;
            acc_state <= ACC_GAP;
          end
          ACC_GAP: begin
            stage_rp  <= stage_rp + 1'd1;
            arb_state <= ARB_IDLE;
          end
        endcase
      end

      ARB_BLOB: begin
        case (acc_state)
          ACC_SETUP:
          if (~sd_busy && ~blocked_m) begin
            sd_addr <= SSBASE | blob_addr_r;
            sd_rd <= 1;
            acc_state <= ACC_WAIT_BUSY;
          end
          ACC_WAIT_BUSY: if (sd_busy) acc_state <= ACC_WAIT_DONE;
          ACC_WAIT_DONE:
          if (~sd_busy) begin
            blob_q <= sd_dout;
            sd_rd <= 0;
            acc_state <= ACC_GAP;
          end
          ACC_GAP: begin
            blob_pending <= 0;
            arb_state <= ARB_IDLE;
          end
        endcase
      end

      ARB_REFRESH: begin
        case (acc_state)
          ACC_SETUP:
          if (~sd_busy && ~blocked_m) begin
            sd_rfsh   <= 1;
            acc_state <= ACC_WAIT_BUSY;
          end
          ACC_WAIT_BUSY: if (sd_busy) acc_state <= ACC_WAIT_DONE;
          ACC_WAIT_DONE:
          if (~sd_busy) begin
            sd_rfsh   <= 0;
            acc_state <= ACC_GAP;
          end
          ACC_GAP: begin
            ref_cnt   <= 0;
            arb_state <= ARB_IDLE;
          end
        endcase
      end

      default: arb_state <= ARB_IDLE;
    endcase
  end

endmodule
