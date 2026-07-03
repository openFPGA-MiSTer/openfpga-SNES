// Testbench for save_state_controller: drives the APF handshake and bridge
// activity patterns and a fake engine, checks sequencing and status codes.

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

module tb_ss_ctrl;
  reg clk_74a = 0;
  reg clk_sys = 0;
  always #6.73 clk_74a = ~clk_74a;  // 74.25
  always #23.28 clk_sys = ~clk_sys;  // 21.48

  reg bridge_rd = 0, bridge_wr = 0;
  reg [31:0] bridge_addr = 0;

  reg savestate_load = 0, savestate_start = 0;
  wire l_ack, l_busy, l_ok, l_err;
  wire s_ack, s_busy, s_ok, s_err;

  reg ss_allow = 1;
  reg ss_busy = 0;
  reg stage_lost = 0;
  wire ss_save, ss_load, ss_abort, ss_force_nmi, ss_pause, ss_idle;

  save_state_controller #(
      .TIMEOUT_TRIGGER(28'd200_000),
      .TIMEOUT_WALK(28'd800_000),
      .TIMEOUT_READBACK(28'd1_000_000),
      .FORCE_NMI_DELAY(28'd10_000)
  ) dut (
      .clk_74a(clk_74a),
      .clk_sys_21_48(clk_sys),
      .bridge_rd(bridge_rd),
      .bridge_wr(bridge_wr),
      .bridge_addr(bridge_addr),
      .ss_size(32'h1000),  // small for sim speed
      .savestate_load(savestate_load),
      .savestate_load_ack_s(l_ack),
      .savestate_load_busy_s(l_busy),
      .savestate_load_ok_s(l_ok),
      .savestate_load_err_s(l_err),
      .savestate_start(savestate_start),
      .savestate_start_ack_s(s_ack),
      .savestate_start_busy_s(s_busy),
      .savestate_start_ok_s(s_ok),
      .savestate_start_err_s(s_err),
      .ss_allow(ss_allow),
      .ss_busy(ss_busy),
      .stage_lost(stage_lost),
      .ss_save(ss_save),
      .ss_load(ss_load),
      .ss_abort(ss_abort),
      .ss_force_nmi(ss_force_nmi),
      .ss_pause(ss_pause),
      .ss_idle(ss_idle)
  );

  integer errors = 0;

  // fake engine: on ss_save/ss_load pulse, go busy after an "NMI delay"
  // (only if console is not paused, like the real CPU), stay busy a while.
  // Like the real engine, a pulse is swallowed while a request is already
  // armed or a walk is running, and a console reset clears the latch.
  reg pend_walk = 0;
  integer nmi_delay = 300;
  integer nmi_cnt = 0, walk_cnt = 0;
  reg reject_load = 0;
  reg abort_races_hijack = 0;
  reg console_dead = 0;
  always @(posedge clk_sys) begin
    if (ss_save && !pend_walk && !ss_busy) begin
      pend_walk <= 1;
      nmi_cnt   <= nmi_delay;
    end
    if (ss_load && !reject_load && !pend_walk && !ss_busy) begin
      pend_walk <= 1;
      nmi_cnt   <= nmi_delay;
    end
    if (pend_walk && !ss_pause) begin
      if (ss_force_nmi && !console_dead) begin
        // Injected NMI: the CPU fetches a vector at once and the engine
        // hijacks it. console_dead models a machine that cannot execute
        // even a forced NMI (STP, or a wedge), where only the timeout
        // backstop remains.
        pend_walk <= 0;
        ss_busy   <= 1;
        walk_cnt  <= 2000;
      end else if (nmi_cnt > 0) nmi_cnt <= nmi_cnt - 1;
      else begin
        pend_walk <= 0;
        ss_busy   <= 1;
        walk_cnt  <= 2000;
      end
    end
    if (ss_busy) begin
      if (walk_cnt > 0) walk_cnt <= walk_cnt - 1;
      else ss_busy <= 0;
    end
    if (ss_abort) begin
      if (abort_races_hijack && pend_walk) begin
        // A vector fetch hijacks the request on the same edge the abort
        // lands: the real engine lets the hijack win. Long walk so the
        // stale window is wide enough to probe.
        pend_walk <= 0;
        ss_busy   <= 1;
        walk_cnt  <= 500_000;
      end else begin
        // Like the real engine: the abort clears the request latch
        pend_walk <= 0;
      end
    end
    if (!ss_allow) begin
      pend_walk <= 0;
      ss_busy   <= 0;
    end
  end

  // The controller must never pulse a trigger while the engine latch is
  // armed: the engine would swallow it and the walk be misattributed
  always @(posedge clk_sys) begin
    if ((ss_save || ss_load) && (pend_walk || ss_busy)) begin
      $display("FAIL: trigger pulsed while engine latch armed");
      errors = errors + 1;
    end
  end

  // The readback freeze must never land right after the walk: the console
  // gets SETTLE_RESUME cycles to leave the helper and its interrupt
  // re-entry before it is frozen
  reg prev_busy_tb = 0, prev_pause_tb = 0;
  integer busy_fall_age = 1000000;
  always @(posedge clk_sys) begin
    prev_busy_tb  <= ss_busy;
    prev_pause_tb <= ss_pause;
    if (prev_busy_tb && !ss_busy) busy_fall_age = 0;
    else if (busy_fall_age < 1000000) busy_fall_age = busy_fall_age + 1;
    if (ss_pause && !prev_pause_tb && dut.state == dut.SAVE_READBACK && busy_fall_age < 40000) begin
      $display("FAIL: readback freeze landed %0d cycles after walk end", busy_fall_age);
      errors = errors + 1;
    end
  end

  task bridge_write_burst(input integer words);
    integer k;
    begin
      for (k = 0; k < words; k = k + 1) begin
        @(posedge clk_74a);
        bridge_addr <= 32'h40000000 + k * 4;
        bridge_wr   <= 1;
        @(posedge clk_74a);
        bridge_wr <= 0;
        repeat (70) @(posedge clk_74a);
      end
    end
  endtask

  task bridge_write_all;
    integer k;
    begin
      for (k = 0; k < 'h1000 / 4; k = k + 1) begin
        @(posedge clk_74a);
        bridge_addr <= 32'h40000000 + k * 4;
        bridge_wr   <= 1;
        @(posedge clk_74a);
        bridge_wr <= 0;
        repeat (10) @(posedge clk_74a);
      end
    end
  endtask

  task bridge_read_all;
    integer k;
    begin
      for (k = 0; k < 'h1000 / 4; k = k + 1) begin
        @(posedge clk_74a);
        bridge_addr <= 32'h40000000 + k * 4;
        bridge_rd   <= 1;
        @(posedge clk_74a);
        bridge_rd <= 0;
        repeat (30) @(posedge clk_74a);
      end
    end
  endtask

  integer guard;
  integer scen_errors;

  task wait_ok(input is_load, input integer max_us);
    begin
      guard = 0;
      while (guard < max_us * 149 && !(is_load ? (l_ok | l_err) : (s_ok | s_err))) begin
        @(posedge clk_74a);
        guard = guard + 1;
      end
      if (is_load ? l_err : s_err) begin
        $display("FAIL: got err instead of ok");
        errors = errors + 1;
      end else if (!(is_load ? l_ok : s_ok)) begin
        $display("FAIL: timeout waiting ok");
        errors = errors + 1;
      end
    end
  endtask

  // Full happy-path save: command, ok, readback, unfreeze. Waits out a
  // stale err flag from a previous attempt before checking the result.
  task start_and_expect_ok;
    begin
      savestate_start <= 1;
      guard = 0;
      while (!s_ack && guard < 10000) begin
        @(posedge clk_74a);
        guard = guard + 1;
      end
      if (!s_ack) begin
        $display("FAIL: no start ack");
        errors = errors + 1;
      end
      savestate_start <= 0;
      guard = 0;
      while (s_err && guard < 1000) begin
        @(posedge clk_74a);
        guard = guard + 1;
      end
      wait_ok(0, 3000);
      bridge_read_all;
      guard = 0;
      while (ss_pause && guard < 100000) begin
        @(posedge clk_74a);
        guard = guard + 1;
      end
      if (ss_pause) begin
        $display("FAIL: still paused after readback");
        errors = errors + 1;
      end
    end
  endtask

  reg saw_load_while_paused = 0;
  reg ss_load_fired = 0;
  reg force_seen = 0;
  always @(posedge clk_sys) begin
    if (ss_load && ss_pause) saw_load_while_paused <= 1;
    if (ss_load) ss_load_fired <= 1;
    if (ss_force_nmi) force_seen <= 1;
  end

  initial begin
    // Let the allow window settle (allow_cnt[6], 64 clk_sys) as the real
    // firmware always does before its first command
    repeat (80) @(posedge clk_sys);

    // ---------------- SAVE flow ----------------
    savestate_start <= 1;
    // firmware holds the request until ack
    guard = 0;
    while (!s_ack && guard < 10000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    if (!s_ack) begin
      $display("FAIL: no start ack");
      errors = errors + 1;
    end
    savestate_start <= 0;

    wait_ok(0, 3000);
    if (!ss_pause) begin
      $display("FAIL: console not frozen for readback");
      errors = errors + 1;
    end
    bridge_read_all;
    // reading the last word should release the console
    guard = 0;
    while (ss_pause && guard < 100000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    if (ss_pause) begin
      $display("FAIL: still paused after readback");
      errors = errors + 1;
    end else $display("PASS: save flow (ok + freeze + release on last read)");
    if (force_seen) begin
      $display("FAIL: forced NMI fired on a console that triggers naturally");
      errors = errors + 1;
    end

    repeat (1000) @(posedge clk_74a);

    // ---------------- LOAD flow, data first ----------------
    bridge_write_burst(16);
    if (!ss_pause) begin
      $display("FAIL: console not frozen during staging");
      errors = errors + 1;
    end
    bridge_write_all;
    savestate_load <= 1;
    guard = 0;
    while (!l_ack && guard < 10000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    if (!l_ack) begin
      $display("FAIL: no load ack");
      errors = errors + 1;
    end
    savestate_load <= 0;
    wait_ok(1, 60000);
    if (!saw_load_while_paused) begin
      $display("FAIL: ss_load was not issued under pause (header race)");
      errors = errors + 1;
    end else $display("PASS: load flow data-first (ok, header under pause)");

    repeat (1000) @(posedge clk_74a);

    // ---------------- LOAD flow, command first ----------------
    saw_load_while_paused = 0;
    savestate_load <= 1;
    guard = 0;
    while (!l_ack && guard < 10000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    savestate_load <= 0;
    bridge_write_all;
    wait_ok(1, 60000);
    if (!saw_load_while_paused) begin
      $display("FAIL: cmd-first: ss_load not under pause");
      errors = errors + 1;
    end else $display("PASS: load flow command-first");

    repeat (1000) @(posedge clk_74a);

    // ---------------- LOAD with truncated stream ----------------
    // Firmware never reaches the last word: no ss_load, timeout error
    savestate_load <= 1;
    guard = 0;
    while (!l_ack && guard < 10000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    savestate_load <= 0;
    bridge_write_burst(16);
    guard = 0;
    while (!(l_ok | l_err) && guard < 60000000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    if (!l_err) begin
      $display("FAIL: truncated stream did not produce err");
      errors = errors + 1;
    end else $display("PASS: truncated stream reports Loading failed");
    if (ss_pause) begin
      $display("FAIL: stuck paused after truncated stream");
      errors = errors + 1;
    end

    repeat (1000) @(posedge clk_74a);

    // ---------------- LOAD with bad blob (engine never goes busy) --------
    reject_load = 1;
    bridge_write_all;
    savestate_load <= 1;
    guard = 0;
    while (!l_ack && guard < 10000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    savestate_load <= 0;
    guard = 0;
    while (!(l_ok | l_err) && guard < 60000000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    if (!l_err) begin
      $display("FAIL: bad blob did not produce err");
      errors = errors + 1;
    end else $display("PASS: bad blob reports Loading failed");
    if (ss_pause) begin
      $display("FAIL: stuck paused after error");
      errors = errors + 1;
    end
    reject_load = 0;

    // The timeout disarmed the engine request, so the very next command
    // must work with no console reset in between; command-first staging
    // sidesteps the still-running write monostable. Small gap so the
    // command lands after the ABORT_CHECK tail of the timeout.
    repeat (100) @(posedge clk_74a);
    savestate_load <= 1;
    guard = 0;
    while (!l_ack && guard < 10000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    savestate_load <= 0;
    bridge_write_all;
    wait_ok(1, 60000);
    $display("PASS: load retry works right after the timeout error");

    // ---------------- LOAD with torn blob (staging lost data) ------------
    // A cart download overlapped the staging writes: the controller must
    // report an error instead of triggering a restore from the torn blob
    ss_load_fired = 0;
    stage_lost = 1;
    savestate_load <= 1;
    guard = 0;
    while (!l_ack && guard < 10000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    savestate_load <= 0;
    bridge_write_all;
    guard = 0;
    while (!(l_ok | l_err) && guard < 60000000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    if (!l_err) begin
      $display("FAIL: torn blob did not produce err");
      errors = errors + 1;
    end else if (ss_load_fired) begin
      $display("FAIL: torn blob still triggered ss_load");
      errors = errors + 1;
    end else $display("PASS: torn blob reports Loading failed without restore");
    if (ss_pause) begin
      $display("FAIL: stuck paused after torn blob");
      errors = errors + 1;
    end
    stage_lost = 0;

    // let the write-activity monostable expire so staging retriggers
    repeat (2_200_000) @(posedge clk_74a);

    // ---------------- LOAD deferred until allowed ----------------
    // Blob lands while a download still holds ss_allow low; ss_load must
    // wait for allow instead of racing the download on the SDRAM port
    ss_load_fired = 0;
    ss_allow = 0;
    bridge_write_all;
    savestate_load <= 1;
    guard = 0;
    while (!l_ack && guard < 10000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    savestate_load <= 0;
    repeat (2000) @(posedge clk_74a);
    if (ss_load_fired) begin
      $display("FAIL: ss_load fired while not allowed");
      errors = errors + 1;
    end
    ss_allow = 1;
    wait_ok(1, 60000);
    if (!ss_load_fired) begin
      $display("FAIL: ss_load never fired after allow rose");
      errors = errors + 1;
    end else $display("PASS: load deferred until download released the port");

    repeat (1000) @(posedge clk_74a);

    // ---------------- LOAD with a slow boot (late first NMI) -------------
    // At wake the console boots from the reset vector after ss_load fires
    // and the first hijackable NMI can be a long way out; the trigger wait
    // must cover it instead of abandoning a load that will still complete.
    // Injection modeled ineffective so the wait itself is exercised.
    console_dead = 1;
    nmi_delay = 150_000;  // 75% of TIMEOUT_TRIGGER
    savestate_load <= 1;
    guard = 0;
    while (!l_ack && guard < 10000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    savestate_load <= 0;
    bridge_write_all;
    wait_ok(1, 60000);
    $display("PASS: slow boot load survives the trigger wait");
    nmi_delay = 300;
    console_dead = 0;

    repeat (1000) @(posedge clk_74a);

    // ---------------- quiet console: forced NMI rescues the save ---------
    // Interrupts off, no vector fetch ever (title screens); the controller
    // pulls the NMI line after FORCE_NMI_DELAY and the save completes
    // instead of dying at TIMEOUT_TRIGGER
    nmi_delay = 10_000_000;  // never fires on its own
    force_seen = 0;
    scen_errors = errors;
    start_and_expect_ok;
    if (!force_seen) begin
      $display("FAIL: quiet save completed without the forced NMI");
      errors = errors + 1;
    end
    if (ss_force_nmi) begin
      $display("FAIL: force still asserted after the save finished");
      errors = errors + 1;
    end
    if (errors == scen_errors) $display("PASS: quiet console save via forced NMI");
    nmi_delay = 300;

    repeat (1000) @(posedge clk_74a);

    // ---------------- quiet console: forced NMI rescues the load ---------
    nmi_delay = 10_000_000;
    force_seen = 0;
    scen_errors = errors;
    savestate_load <= 1;
    guard = 0;
    while (!l_ack && guard < 10000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    savestate_load <= 0;
    bridge_write_all;
    wait_ok(1, 60000);
    if (!force_seen) begin
      $display("FAIL: quiet load completed without the forced NMI");
      errors = errors + 1;
    end
    if (errors == scen_errors) $display("PASS: quiet console load via forced NMI");
    nmi_delay = 300;

    repeat (1000) @(posedge clk_74a);

    // ---------------- ss_load held through the reset tail ----------------
    // ss_allow rises a few cycles before the console leaves reset after a
    // download; the pulse must wait for a continuously open window.
    // Stage first with allow low, like a real wake with a download running.
    repeat (2_200_000) @(posedge clk_74a);  // let the staging monostable expire
    ss_load_fired = 0;
    ss_allow = 0;
    bridge_write_all;
    savestate_load <= 1;
    guard = 0;
    while (!l_ack && guard < 10000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    savestate_load <= 0;
    repeat (100) @(posedge clk_sys);
    ss_allow = 1;
    repeat (30) @(posedge clk_sys);
    ss_allow = 0;
    repeat (4) @(posedge clk_sys);
    if (ss_load_fired) begin
      $display("FAIL: ss_load fired inside a short allow window");
      errors = errors + 1;
    end
    repeat (10) @(posedge clk_sys);
    ss_allow = 1;
    wait_ok(1, 60000);
    if (!ss_load_fired) begin
      $display("FAIL: ss_load never fired after allow settled");
      errors = errors + 1;
    end else $display("PASS: ss_load waits out the reset tail");

    repeat (1000) @(posedge clk_74a);

    // ---------------- trigger timeout: disarm, then clean retry ----------
    // The trigger wait expires while the engine request is still armed; the
    // abort must clear the latch so no stale walk fires later and an
    // immediate retry works with no console reset in between
    console_dead = 1;
    nmi_delay = 260_000;  // beyond TIMEOUT_TRIGGER (200k)
    savestate_start <= 1;
    guard = 0;
    while (!s_ack && guard < 10000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    savestate_start <= 0;
    guard = 0;
    while (!(s_ok | s_err) && guard < 60000000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    if (!s_err) begin
      $display("FAIL: trigger timeout did not err");
      errors = errors + 1;
    end
    repeat (100) @(posedge clk_sys);
    if (pend_walk) begin
      $display("FAIL: abort left the engine request armed");
      errors = errors + 1;
    end
    nmi_delay = 300;
    console_dead = 0;
    scen_errors = errors;
    start_and_expect_ok;
    if (errors == scen_errors) $display("PASS: trigger timeout disarms, retry works");

    repeat (1000) @(posedge clk_74a);

    // ---------------- abort loses to a same-edge hijack ------------------
    // A vector fetch can hijack the request on the very edge the abort
    // lands; the engine lets the hijack win, so the controller must notice
    // the unowned walk and refuse commands until it is consumed
    console_dead = 1;
    abort_races_hijack = 1;
    nmi_delay = 260_000;
    savestate_start <= 1;
    guard = 0;
    while (!s_ack && guard < 10000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    savestate_start <= 0;
    guard = 0;
    while (!(s_ok | s_err) && guard < 60000000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    if (!s_err) begin
      $display("FAIL: raced timeout did not err");
      errors = errors + 1;
    end
    abort_races_hijack = 0;
    savestate_start <= 1;
    guard = 0;
    while (!s_ack && guard < 10000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    savestate_start <= 0;
    guard = 0;
    while (!s_err && guard < 5000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    if (!s_err) begin
      $display("FAIL: stale walk retry not refused promptly");
      errors = errors + 1;
    end else $display("PASS: stale walk refuses retries promptly");

    // The unowned walk completes: silent, no freeze, next command works
    guard = 0;
    while (ss_busy && guard < 60000000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    repeat (100) @(posedge clk_sys);
    scen_errors = errors;
    // l_ok may still be latched from an earlier successful load scenario;
    // only a fresh start_ok would be a misreport here
    if (s_ok) begin
      $display("FAIL: stale walk misreported as success");
      errors = errors + 1;
    end
    if (ss_pause) begin
      $display("FAIL: stale walk froze the console");
      errors = errors + 1;
    end
    nmi_delay = 300;
    console_dead = 0;
    start_and_expect_ok;
    if (errors == scen_errors) $display("PASS: stale walk consumed silently, next save works");

    repeat (1000) @(posedge clk_74a);

    // ---------------- stale walk cleared by console reset ----------------
    console_dead = 1;
    abort_races_hijack = 1;
    nmi_delay = 260_000;
    savestate_start <= 1;
    guard = 0;
    while (!s_ack && guard < 10000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    savestate_start <= 0;
    guard = 0;
    while (!(s_ok | s_err) && guard < 60000000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    abort_races_hijack = 0;
    ss_allow = 0;  // console reset kills the unowned walk and the flag
    repeat (20) @(posedge clk_sys);
    ss_allow = 1;
    repeat (80) @(posedge clk_sys);
    nmi_delay = 300;
    console_dead = 0;
    scen_errors = errors;
    start_and_expect_ok;
    if (errors == scen_errors) $display("PASS: reset clears the stale walk flag");

    repeat (1000) @(posedge clk_74a);

    // ---------------- reset during the trigger wait bails early ----------
    // A reset kills the armed request; the controller must err well before
    // TIMEOUT_TRIGGER and must not latch stale_walk
    console_dead = 1;
    nmi_delay = 260_000;
    savestate_start <= 1;
    guard = 0;
    while (!s_ack && guard < 10000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    savestate_start <= 0;
    repeat (10_000) @(posedge clk_sys);
    ss_allow = 0;
    guard = 0;
    while (!s_err && guard < 5000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    if (!s_err) begin
      $display("FAIL: reset during trigger wait did not err early");
      errors = errors + 1;
    end else $display("PASS: reset during trigger wait errs early");
    ss_allow = 1;
    repeat (80) @(posedge clk_sys);
    nmi_delay = 300;
    console_dead = 0;
    scen_errors = errors;
    start_and_expect_ok;
    if (errors == scen_errors) $display("PASS: no stale flag after reset-killed request");

    repeat (1000) @(posedge clk_74a);

    // ---------------- unsupported cart ----------------
    ss_allow = 0;
    savestate_start <= 1;
    guard = 0;
    while (!s_ack && guard < 10000) begin
      @(posedge clk_74a);
      guard = guard + 1;
    end
    savestate_start <= 0;
    repeat (100) @(posedge clk_74a);
    if (!s_err) begin
      $display("FAIL: unsupported cart did not err");
      errors = errors + 1;
    end else $display("PASS: unsupported cart errors immediately");

    if (errors == 0) $display("ALL TESTS PASSED");
    else $display("%0d ERRORS", errors);
    $finish;
  end
endmodule
