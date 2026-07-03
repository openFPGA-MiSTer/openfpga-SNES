// Save state command controller.
//
// Sequences the APF savestate protocol (host commands 0xA0/0xA4 via
// core_bridge_cmd) against the CPU driven save state engine in the core.
// The data path does not run through this module: the state blob lives in
// cart SDRAM (see rtl/mister_top/save_state_mem.sv) and moves over the
// bridge through data_loader/data_unloader. This module only decides when
// to trigger the engine, when to freeze the console, and what to report
// back to the firmware.
//
// Save:  Start command -> pulse ss_save -> engine hijacks the next NMI and
//        walks the state into SDRAM (console keeps running the helper) ->
//        walk ends -> freeze console, report ok -> firmware reads the blob
//        from the bridge region -> unfreeze when the last word was read.
// Load:  firmware writes the blob into the bridge region (console frozen
//        while it lands in SDRAM) -> last word written -> unfreeze, pulse
//        ss_load -> engine restores on the next NMI -> walk ends ->
//        report ok. A bad blob (magic mismatch) means the engine never
//        goes busy; the timeout turns that into an error.
//
// End of stream is detected by the address of the last word of the blob,
// not by gaps in bridge activity: the firmware interleaves bridge access
// with SD card I/O, and an SD write can stall the read-back for hundreds
// of milliseconds. Treating such a gap as completion would unfreeze the
// console while the firmware still owns the SDRAM port.

module save_state_controller #(
    // Bridge address region (upper nibble) that carries the blob; must match
    // the data_loader/data_unloader region in core_top.sv
    parameter [3:0] SS_REGION = 4'h4,

    // ~10 s, ~6 s and ~12 s at 21.48 MHz; overridable so simulation stays fast.
    // The trigger wait must outlast a full game boot: once pulsed, the engine
    // request cannot be canceled and only fires when the game fetches its
    // first native NMI/IRQ vector. At wake the console boots from the reset
    // vector first (F-Zero reaches its first NMI around 1.5 s, GSU carts
    // later still), so an early error report here abandons a load that was
    // about to succeed.
    parameter [27:0] TIMEOUT_TRIGGER = 28'd215_000_000,
    parameter [27:0] TIMEOUT_WALK = 28'd128_000_000,
    parameter [27:0] TIMEOUT_READBACK = 28'd256_000_000,

    // ~50 ms at 21.48 MHz. The engine can only trigger by hijacking a CPU
    // vector fetch, and a console running with interrupts off (title
    // screens: NMI disabled, no IRQ source, a polling loop) never fetches
    // one. After this long armed with no hijack, pull the S-CPU NMI line:
    // the CPU core edge-detects it (one NMI per assertion), the engine
    // steals the resulting vector fetch, and the game's own handler never
    // runs. Far above any natural trigger latency (NMI games fire within a
    // frame), so it only acts when nothing else would. A console sitting in
    // emulation mode fetches $00FFFA instead, which the engine does not
    // watch; such a save still errs cleanly at TIMEOUT_TRIGGER (commercial
    // games are in native mode anywhere a save makes sense).
    parameter [27:0] FORCE_NMI_DELAY = 28'd1_074_000,

    // ~2 ms at 21.48 MHz of console run time between the end of the save
    // walk and the readback freeze. The walk ends inside the helper: the
    // S-CPU has yet to RTI and re-enter the interrupt whose vector fetch
    // was stolen, and on SA-1 carts the SA-1 is fresh out of its park
    // loop. Freezing the console inside that window has wedged SA-1 games
    // at resume (picture dead, music alive), so let the machine settle
    // into steady state first; the blob in SDRAM is already complete,
    // only the freeze point moves.
    parameter [27:0] SETTLE_RESUME = 28'd43_000
) (
    input wire clk_74a,
    input wire clk_sys_21_48,

    // APF bridge (clk_74a)
    input wire bridge_rd,
    input wire bridge_wr,
    input wire [31:0] bridge_addr,
    // Declared savestate size in bytes; cart dependent (the blob carries
    // cart RAM), set by the loader long before any savestate command
    input wire [31:0] ss_size,

    // APF savestate handshake (clk_74a)
    input  wire savestate_load,
    output wire savestate_load_ack_s,
    output wire savestate_load_busy_s,
    output wire savestate_load_ok_s,
    output wire savestate_load_err_s,

    input  wire savestate_start,
    output wire savestate_start_ack_s,
    output wire savestate_start_busy_s,
    output wire savestate_start_ok_s,
    output wire savestate_start_err_s,

    // Core (clk_sys)
    input wire ss_allow,     // save states usable right now (cart ready etc)
    input wire ss_busy,      // engine walk running
    input wire stage_lost,   // staging dropped data, blob in SDRAM is torn (clk_mem)

    output reg ss_save = 0,
    output reg ss_load = 0,
    output reg ss_abort = 0,  // disarm an engine request that never fired
    output reg ss_force_nmi = 0,  // make a quiet console fetch a vector
    output reg ss_pause = 0,
    output wire ss_idle      // sequencer idle, clears the stage_lost latch
);

  //////////////////////////////////////////////////////////////////////////
  // clk_74a side: bridge activity monitors

  wire in_region = bridge_addr[31:28] == SS_REGION;

  // Retriggerable monostable covering gaps in the firmware write stream
  // (2^21 cycles at 74.25 MHz is roughly 28 ms); only used to notice that
  // staging has started, never to detect its end
  reg [20:0] wr_quiet = 0;
  wire stage_active = wr_quiet != 0;

  // Latched when the firmware touches the last word of the blob; cleared
  // whenever the sequencer is idle
  reg last_read_seen = 0;
  reg last_write_seen = 0;
  wire seq_idle_74;

  wire last_word = bridge_addr[27:0] >= ss_size[27:0] - 28'd4;

  always @(posedge clk_74a) begin
    if (bridge_wr && in_region) wr_quiet <= ~21'd0;
    else if (wr_quiet != 0) wr_quiet <= wr_quiet - 1'd1;

    if (seq_idle_74) begin
      last_read_seen  <= 0;
      last_write_seen <= 0;
    end else begin
      if (bridge_rd && in_region && last_word) last_read_seen <= 1;
      if (bridge_wr && in_region && last_word) last_write_seen <= 1;
    end
  end

  //////////////////////////////////////////////////////////////////////////
  // clk_sys side: sequencer

  wire start_s, load_s, stage_active_s, last_read_s, last_write_s;
  wire stage_lost_s;

  synch_3 #(
      .WIDTH(5)
  ) cmd_sync (
      {savestate_start, savestate_load, stage_active, last_read_seen, last_write_seen},
      {start_s, load_s, stage_active_s, last_read_s, last_write_s},
      clk_sys_21_48
  );

  synch_3 stage_lost_sync (
      stage_lost,
      stage_lost_s,
      clk_sys_21_48
  );

  reg start_ack = 0, start_busy = 0, start_ok = 0, start_err = 0;
  reg load_ack = 0, load_busy = 0, load_ok = 0, load_err = 0;

  localparam IDLE = 4'd0;
  localparam SAVE_WAIT_BUSY = 4'd1;
  localparam SAVE_WALK = 4'd2;
  localparam SAVE_READBACK = 4'd3;
  localparam PRELOAD_STAGE = 4'd4;
  localparam LOAD_WAIT_STAGE = 4'd5;
  localparam LOAD_WAIT_BUSY = 4'd6;
  localparam LOAD_WALK = 4'd7;
  localparam LOAD_HEAD = 4'd8;
  localparam SAVE_DRAIN = 4'd9;
  localparam ABORT_CHECK = 4'd10;
  localparam SAVE_SETTLE = 4'd11;

  reg [3:0] state = IDLE;
  reg prev_start = 0, prev_load = 0, prev_stage = 0;
  reg [27:0] timeout = 0;

  // ss_allow rises a few clk_sys after a download ends, but the console
  // reset tail (parser delay plus the divided RESET_N sampler) releases
  // several cycles later. A load pulse fired into that tail is silently
  // dropped by the engine, so require the window to have been open for a
  // safe margin before triggering.
  reg [6:0] allow_cnt = 0;
  wire allow_settled = allow_cnt[6];

  // Set when a trigger timeout tried to disarm the engine request latch
  // (savestates.sv save_en/load_en) but a vector fetch hijacked it on the
  // same edge: a walk no command owns is now running. While it is set every
  // new command is refused, because the engine would swallow the trigger
  // pulse and the stale walk would be misattributed to the new command (a
  // stale save walk would even overwrite a freshly staged load blob).
  // Cleared when the stale walk is consumed (busy rise+fall) or when a
  // console reset clears the engine latch; ~ss_allow tracks every reset
  // source (see SNES.sv reset wire and core_top.sv ss_allow).
  reg stale_walk = 0;
  reg prev_busy = 0;


  assign ss_idle = state == IDLE;

  synch_3 idle_sync (
      ss_idle,
      seq_idle_74,
      clk_74a
  );

  always @(posedge clk_sys_21_48) begin
    prev_start <= start_s;
    prev_load <= load_s;
    prev_stage <= stage_active_s;
    prev_busy <= ss_busy;

    // Stale walk consumed (busy was low when the flag was set, so a fall
    // implies a full rise+fall and the engine RTI cleared its latch), or the
    // latch was cleared by a console reset. A same-cycle set in a timeout
    // branch below wins; the clear re-fires next cycle if still due.
    if (~ss_allow || (prev_busy && ~ss_busy)) stale_walk <= 0;

    ss_save  <= 0;
    ss_load  <= 0;
    ss_abort <= 0;

    // Hold ack while the firmware still asserts the request
    if (~start_s) start_ack <= 0;
    if (~load_s) load_ack <= 0;

    timeout <= timeout + 1'd1;

    if (~ss_allow) allow_cnt <= 0;
    else if (~allow_settled) allow_cnt <= allow_cnt + 1'd1;

    case (state)
      IDLE: begin
        ss_pause <= 0;
        timeout <= 0;

        if (start_s & ~prev_start) begin
          start_ack <= 1;
          start_ok <= 0;
          start_err <= 0;

          // Same margin as the load trigger below: a save pulse fired into
          // the post-download reset tail is silently dropped by the engine
          // and would hang here until TIMEOUT_TRIGGER
          if (ss_allow && allow_settled && ~stale_walk) begin
            start_busy <= 1;
            ss_save <= 1;
            state <= SAVE_WAIT_BUSY;
          end else begin
            start_err <= 1;
          end
        end else if (load_s & ~prev_load) begin
          load_ack <= 1;
          load_ok <= 0;
          load_err <= 0;

          if (ss_allow && ~stale_walk) begin
            load_busy <= 1;
            ss_pause <= 1;
            state <= LOAD_WAIT_STAGE;
          end else begin
            load_err <= 1;
          end
        end else if (stage_active_s & ~prev_stage) begin
          // Blob data arriving ahead of the Load command: freeze the
          // console so staging does not race the CPU on the SDRAM port
          ss_pause <= 1;
          state <= PRELOAD_STAGE;
        end
      end

      SAVE_WAIT_BUSY: begin
        if (ss_busy) begin
          timeout <= 0;
          state <= SAVE_WALK;
        end else if (~ss_allow) begin
          // A console reset cleared the armed request; plain error, the
          // engine latch is provably free again
          start_busy <= 0;
          start_err <= 1;
          state <= IDLE;
        end else if (timeout == TIMEOUT_TRIGGER) begin
          // Timed out with ss_allow high throughout: the request is still
          // armed inside the engine. Disarm it so the command fails
          // cleanly and stays retryable instead of a stale walk firing
          // minutes later at a hostile moment.
          start_busy <= 0;
          start_err <= 1;
          ss_abort <= 1;
          timeout <= 0;
          state <= ABORT_CHECK;
        end
      end

      SAVE_WALK: begin
        if (~ss_busy && ~ss_allow) begin
          // ss_busy fell because a console reset killed the engine mid-walk
          // (ss_allow drops before RESET_N clears ss_busy), not because the
          // walk finished: the blob is torn, do not offer it to the firmware
          start_busy <= 0;
          start_err <= 1;
          state <= IDLE;
        end else if (~ss_busy) begin
          timeout <= 0;
          state <= SAVE_SETTLE;
        end else if (timeout == TIMEOUT_WALK) begin
          start_busy <= 0;
          start_err <= 1;
          state <= IDLE;
        end
      end

      SAVE_SETTLE: begin
        // Console runs for SETTLE_RESUME cycles before the readback
        // freeze (see the parameter comment). No ~ss_allow bail: the blob
        // is complete, so like SAVE_READBACK this proceeds even across a
        // console reset.
        if (timeout == SETTLE_RESUME) begin
          ss_pause <= 1;
          start_busy <= 0;
          start_ok <= 1;
          timeout <= 0;
          state <= SAVE_READBACK;
        end
      end

      SAVE_READBACK: begin
        // Stay frozen until the firmware has read the whole blob; the
        // timeout only rescues a firmware that walked away mid-transfer
        if (last_read_s || timeout == TIMEOUT_READBACK) begin
          timeout <= 0;
          state <= SAVE_DRAIN;
        end
      end

      SAVE_DRAIN: begin
        // Let the read of the last word finish its trip through the
        // unloader and the SDRAM arbiter before handing the port back
        if (timeout == 28'd2048) begin
          state <= IDLE;
        end
      end

      PRELOAD_STAGE: begin
        // Staging is alive as long as writes keep arriving; only give up
        // after a sustained quiet period, so an SD stall mid-transfer can
        // never unfreeze the console under the firmware
        if (stage_active_s) timeout <= 0;

        if (load_s & ~prev_load) begin
          // No ss_allow test here: in the wake-from-sleep flow the Load
          // command can legitimately arrive while the download tail still
          // holds ss_allow low; LOAD_WAIT_STAGE waits it out
          load_ack <= 1;
          load_ok <= 0;
          load_err <= 0;

          if (stale_walk) begin
            // Cannot start a load with a stale walk armed: unfreeze so the
            // walk can fire and clear itself; the staged blob is abandoned
            load_err <= 1;
            state <= IDLE;
          end else begin
            load_busy <= 1;
            timeout <= 0;
            state <= LOAD_WAIT_STAGE;
          end
        end else if (~stage_active_s && timeout >= TIMEOUT_WALK) begin
          // Data arrived but no Load command followed
          state <= IDLE;
        end
      end

      LOAD_WAIT_STAGE: begin
        if (last_write_s && stage_lost_s) begin
          // Staging overflowed while a cart download owned the SDRAM port:
          // the blob is torn and restoring it would wedge the console
          load_busy <= 0;
          load_err <= 1;
          state <= IDLE;
        end else if (last_write_s && allow_settled) begin
          // Last word of the blob landed in SDRAM and any download has
          // finished draining. Trigger the engine while the console is
          // still frozen: its header check reads SDRAM immediately, and
          // that access must not race CPU ROM fetches.
          ss_load <= 1;
          timeout <= 0;
          state <= LOAD_HEAD;
        end else if (timeout == TIMEOUT_READBACK) begin
          load_busy <= 0;
          load_err <= 1;
          state <= IDLE;
        end
      end

      LOAD_HEAD: begin
        // Give the engine time to fetch and check the header, then let the
        // console run so the next NMI can start the restore
        if (timeout == 28'd4096) begin
          ss_pause <= 0;
          timeout <= 0;
          state <= LOAD_WAIT_BUSY;
        end
      end

      LOAD_WAIT_BUSY: begin
        if (ss_busy) begin
          timeout <= 0;
          state <= LOAD_WALK;
        end else if (~ss_allow) begin
          // Console reset cleared the armed request; plain error
          load_busy <= 0;
          load_err <= 1;
          state <= IDLE;
        end else if (timeout == TIMEOUT_TRIGGER) begin
          // Engine refused the blob (bad magic, in which case its latch
          // is already free) or never saw an interrupt (latch still
          // armed). Disarm covers both, no need to tell them apart.
          load_busy <= 0;
          load_err <= 1;
          ss_abort <= 1;
          timeout <= 0;
          state <= ABORT_CHECK;
        end
      end

      ABORT_CHECK: begin
        // The abort pulse and a vector fetch can land on the same engine
        // clock edge, and the engine lets the hijack win. Give the pulse a
        // few cycles to act, then read the outcome: busy means a walk no
        // command owns is running, which is exactly a stale walk. Without
        // a hijack the latch is provably clear and a retry is safe.
        if (timeout == 28'd8) begin
          if (ss_busy) stale_walk <= 1;
          state <= IDLE;
        end
      end

      LOAD_WALK: begin
        if (~ss_busy && ~ss_allow) begin
          // Same as SAVE_WALK: a mid-walk console reset is not a completion
          load_busy <= 0;
          load_err <= 1;
          state <= IDLE;
        end else if (~ss_busy) begin
          load_busy <= 0;
          load_ok <= 1;
          state <= IDLE;
        end else if (timeout == TIMEOUT_WALK) begin
          load_busy <= 0;
          load_err <= 1;
          state <= IDLE;
        end
      end

      default: state <= IDLE;
    endcase

    // A request that lands while another operation is in flight is not
    // handled by the states above, and core_bridge_cmd waits for the ack
    // forever, wedging the whole host command channel. Acknowledge it here;
    // report an error unless the same operation is already running (then
    // the busy flag tells the firmware to keep polling).
    if ((start_s & ~prev_start) && state != IDLE) begin
      start_ack <= 1;
      if (~start_busy) begin
        start_ok  <= 0;
        start_err <= 1;
      end
    end
    if ((load_s & ~prev_load) && state != IDLE && state != PRELOAD_STAGE) begin
      load_ack <= 1;
      if (~load_busy) begin
        load_ok  <= 0;
        load_err <= 1;
      end
    end
  end

  // Forced NMI for a quiet console (see FORCE_NMI_DELAY). Held as a level
  // while the wait state persists: it drops with the state change on
  // hijack, timeout or console reset, and the edge detect in the CPU core
  // means the level can never deliver a second NMI. The armed gate in
  // main.v keeps it away from the game if the engine has already dropped
  // the request (bad header).
  always @(posedge clk_sys_21_48) begin
    ss_force_nmi <= (state == SAVE_WAIT_BUSY || state == LOAD_WAIT_BUSY)
        && timeout >= FORCE_NMI_DELAY;
  end

  // The result flags and the ack can change on the same clk_sys edge but
  // cross to clk_74a through independent per-bit synchronizers, and
  // core_bridge_cmd latches the result code on the first cycle it sees the
  // ack. Delay the ack two cycles so the flags always land first.
  reg [1:0] start_ack_dly = 0, load_ack_dly = 0;

  always @(posedge clk_sys_21_48) begin
    start_ack_dly <= {start_ack_dly[0], start_ack};
    load_ack_dly  <= {load_ack_dly[0], load_ack};
  end

  synch_3 #(
      .WIDTH(8)
  ) status_sync (
      {start_ack_dly[1], start_busy, start_ok, start_err, load_ack_dly[1], load_busy, load_ok, load_err},
      {
        savestate_start_ack_s,
        savestate_start_busy_s,
        savestate_start_ok_s,
        savestate_start_err_s,
        savestate_load_ack_s,
        savestate_load_busy_s,
        savestate_load_ok_s,
        savestate_load_err_s
      },
      clk_74a
  );

endmodule
