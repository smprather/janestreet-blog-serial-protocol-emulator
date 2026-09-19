// tb_pe_codec_mux.v — config-driven pipeline muxing.
//
// cfg[0]=stuff_en  cfg[1]=nrzi_en  cfg[2]=manch_en  cfg[3]=half_phase
// cfg[7:4]=stuff run length (0 => default 5; CAN 5, USB 6)
//
// TX: tx_bit -> [stuff] -> [nrzi] -> [manch] -> tx_wire
// RX: rx_wire -> [manch] -> [nrzi] -> [stuff] -> rx_bit
//
// Sampling note: the stuff and manch stages are COMBINATIONAL, so their
// outputs are valid before the strobe; the NRZI stage's line level is
// REGISTERED, so its wire output for bit k appears at the strobe. TX
// checks therefore sample per-stage; RX checks sample the settled
// cascade before the strobe commits state.

`timescale 1ns / 1ps

module tb_pe_codec_mux;
  logic       clk=0, rst_n, bit_en, clr;
  logic [7:0] cfg;
  logic       tx_bit, tx_wire, tx_stuffed;
  logic       rx_wire, rx_first, rx_second, rx_bit, rx_bit_valid, rx_err;

  pe_codec_mux dut (.*);
  always #5 clk = ~clk;

  integer errors = 0;

  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL mux: %s @%0t", m, $time); errors++; end
  endtask

  task automatic strobe(); bit_en = 1; @(posedge clk); #1; bit_en = 0; #1; endtask
  task automatic reset_run(); clr = 1; @(posedge clk); #1; clr = 0; endtask

  // --- TX steps -------------------------------------------------------
  // Combinational stages: the emitted wire bit is visible pre-strobe.
  task automatic tx_step_comb(input bit b, output bit w, output bit st);
    tx_bit = b; #1;
    w  = tx_wire;
    st = tx_stuffed;
    strobe();
  endtask
  // NRZI: the line level for this bit is committed AT the strobe.
  task automatic tx_step_nrzi(input bit b, output bit lvl);
    tx_bit = b;
    strobe();
    #1;
    lvl = tx_wire;
  endtask

  // --- RX step: settled cascade sampled before the state commit --------
  task automatic rx_step(input bit wv, output bit rb, output bit rv);
    rx_wire = wv; #1;
    rb = rx_bit;
    rv = rx_bit_valid;
    strobe();
  endtask

  logic w, st, lvl, rb, rv;

  initial begin
    $dumpfile("tb_pe_codec_mux.vcd"); $dumpvars(0, tb_pe_codec_mux);
    rst_n=0; bit_en=0; clr=0; cfg=8'h00;
    tx_bit=0; rx_wire=0; rx_first=0; rx_second=0;
    repeat(3) @(posedge clk); #1; rst_n=1; @(posedge clk); #1;

    // ================= cfg=0x00: everything bypassed =================
    begin
      cfg = 8'h00;
      tx_bit = 1'b1; rx_wire = 1'b0; #1;
      check(tx_wire === 1'b1, "bypass: tx passthrough high");
      check(rx_bit === 1'b0, "bypass: rx passthrough low");
      check(rx_bit_valid === 1'b1, "bypass: rx always valid");
      tx_bit = 1'b0; #1;
      check(tx_wire === 1'b0, "bypass: tx passthrough low");
    end

    // ============ cfg=0x01: stuff only, run 5 (CAN) =================
    begin
      cfg = 8'h01; reset_run();
      for (int k = 0; k < 5; k++) begin
        tx_step_comb(1'b1, w, st);
        check(w === 1'b1, $sformatf("can tx: data bit %0d", k));
        check(st === 1'b0, $sformatf("can tx: no stuff at %0d", k));
      end
      check(tx_stuffed === 1'b1, "can tx: stuff owed after 5 identical");
      tx_step_comb(1'b0, w, st);      // stuff strobe (raw ignored)
      check(st === 1'b1, "can tx: stuff strobe flagged");
      check(w === 1'b0, "can tx: stuff bit complementary");
      tx_step_comb(1'b1, w, st);
      check(w === 1'b1, "can tx: data resumes after stuff");
    end

    // RX: five 1s then the stuff slot
    begin
      cfg = 8'h01; reset_run();
      for (int k = 0; k < 5; k++) begin
        rx_step(1'b1, rb, rv);
        check(rv === 1'b1, $sformatf("can rx: bit %0d valid", k));
        check(rb === 1'b1, $sformatf("can rx: bit %0d = 1", k));
      end
      rx_step(1'b0, rb, rv);          // stuff slot
      check(rv === 1'b0, "can rx: stuff slot flagged invalid");
      rx_step(1'b1, rb, rv);
      check(rv === 1'b1, "can rx: data resumes");
      check(rb === 1'b1, "can rx: resumed bit = 1");
    end

    // ============ cfg=0x61: stuff only, run 6 (USB) =================
    begin
      cfg = 8'h61; reset_run();
      for (int k = 0; k < 6; k++) begin
        tx_step_comb(1'b1, w, st);
        check(st === 1'b0, $sformatf("usb tx: no stuff at %0d", k));
      end
      check(tx_stuffed === 1'b1, "usb tx: owed after 6 identical");
      tx_step_comb(1'b0, w, st);
      check(st === 1'b1, "usb tx: stuff strobe flagged");
      check(w === 1'b0, "usb tx: stuff bit complementary");
    end

    // ================= cfg=0x02: NRZI only ==========================
    begin
      bit prev;
      cfg = 8'h02; reset_run();
      tx_step_nrzi(1'b0, lvl);            // raw 0 -> toggle from idle J
      check(lvl === 1'b0, "nrzi tx: raw 0 toggles the line");
      prev = lvl;
      tx_step_nrzi(1'b1, lvl);            // raw 1 -> hold
      check(lvl === prev, "nrzi tx: raw 1 holds the line");
      tx_step_nrzi(1'b0, lvl);            // raw 0 -> toggle
      check(lvl !== prev, "nrzi tx: raw 0 toggles again");
    end

    // RX: decode a level sequence back to raw bits
    begin
      // levels: start J=1; 0 -> toggle to 0; 1 -> hold 0; 0 -> toggle 1
      cfg = 8'h02; reset_run();
      rx_step(1'b0, rb, rv); check(rb === 1'b0, "nrzi rx: 1->0 decodes 0");
      rx_step(1'b0, rb, rv); check(rb === 1'b1, "nrzi rx: hold decodes 1");
      rx_step(1'b1, rb, rv); check(rb === 1'b0, "nrzi rx: 0->1 decodes 0");
      rx_step(1'b1, rb, rv); check(rb === 1'b1, "nrzi rx: hold decodes 1");
    end

    // =============== cfg=0x04: Manchester only ======================
    begin
      cfg = 8'h04;
      tx_bit = 1'b0; cfg[3] = 1'b0; #1;
      check(tx_wire === 1'b1, "manch: bit 0 first half high");
      cfg[3] = 1'b1; #1;
      check(tx_wire === 1'b0, "manch: bit 0 second half low (H->L)");
      tx_bit = 1'b1; cfg[3] = 1'b0; #1;
      check(tx_wire === 1'b0, "manch: bit 1 first half low");
      cfg[3] = 1'b1; #1;
      check(tx_wire === 1'b1, "manch: bit 1 second half high (L->H)");

      rx_first = 1'b1; rx_second = 1'b0; #1;
      check(rx_bit === 1'b0, "manch rx: decodes 0");
      check(rx_err === 1'b0, "manch rx: legal bit");
      rx_first = 1'b0; rx_second = 1'b1; #1;
      check(rx_bit === 1'b1, "manch rx: decodes 1");
      rx_first = 1'b1; rx_second = 1'b1; #1;
      check(rx_err === 1'b1, "manch rx: no mid-bit edge flagged");
    end

    // ====== cfg=0x63: stuff(run 6) + NRZI, USB-LS composition =======
    begin
      int nraw; logic rec [64]; bit rbv, rvv;
      logic [79:0] wire_lv;   // level per wire bit
      int nwv; bit lv; bit raw_exp [64]; int nraw_exp;
      logic stuffed [128]; int ns; int run; bit last;
      cfg = 8'h63; reset_run();

      // Build the stuffed raw stream (run counter resets after each
      // inserted bit, exactly like the RTL), then NRZI-encode it.
      nraw_exp = 0; ns = 0; run = 0; last = 1'b0;
      for (int k = 0; k < 48; k++) begin
        bit b;
        b = (k % 10 < 7) ? 1'b1 : ((k / 10) % 2);   // long one-runs
        raw_exp[nraw_exp] = b; nraw_exp++;
        stuffed[ns] = b; ns++;
        if (b == last) run++; else begin last = b; run = 1; end
        if (run == 6) begin
          stuffed[ns] = ~b; ns++;      // stuffed bit
          last = ~b; run = 1;          // it opens a new run
        end
      end
      lv = 1'b1; nwv = 0;
      for (int i = 0; i < ns; i++) begin
        if (stuffed[i] == 1'b0) lv = ~lv;
        wire_lv[nwv] = lv; nwv++;
      end
      check(nwv > 48, "usb: stuffing added wire bits");

      // Feed the levels to the RX cascade and recover the raw stream.
      nraw = 0;
      for (int i = 0; i < nwv; i++) begin
        rx_step(wire_lv[i], rbv, rvv);
        if (rvv) begin rec[nraw] = rbv; nraw++; end
      end
      check(nraw == nraw_exp,
            $sformatf("usb: recovered %0d raw bits (expected %0d)", nraw, nraw_exp));
      for (int i = 0; i < nraw_exp && i < nraw; i++)
        check(rec[i] === raw_exp[i], $sformatf("usb: bit %0d round trip", i));
    end

    // ====== cfg=0x02: NRZI round trip, long no-transition run =======
    begin
      int nraw; logic rec [64]; bit rbv, rvv; bit lv; bit exp_b;
      cfg = 8'h02; reset_run();
      lv = 1'b1; nraw = 0;
      for (int k = 0; k < 40; k++) begin
        exp_b = (k < 20) ? 1'b1 : ~(k % 2);   // 20 ones (no transitions), then toggling
        if (exp_b == 1'b0) lv = ~lv;
        rx_step(lv, rbv, rvv);
        if (rvv) begin
          check(rbv === exp_b, $sformatf("nrzi rt: bit %0d", k));
          nraw++;
        end
      end
      check(nraw == 40, $sformatf("nrzi rt: recovered %0d bits", nraw));
    end

    // ============ clr resets run tracking mid-stream ================
    begin
      cfg = 8'h01;
      reset_run();
      for (int k = 0; k < 4; k++) tx_step_comb(1'b1, w, st);
      reset_run();                       // clears the run counter
      for (int k = 0; k < 4; k++) begin
        tx_step_comb(1'b1, w, st);
        check(st === 1'b0, $sformatf("clr: no stuff at %0d after clear", k));
      end
      tx_step_comb(1'b1, w, st);
      check(tx_stuffed === 1'b1, "clr: run tracking restarted from the clear");
    end

    if (errors == 0) $display("PASS: tb_pe_codec_mux");
    else $display("FAILURES mux: %0d", errors);
    $finish;
  end
endmodule
