// Save state helper program ROM (upstream SNES_MiSTer releases/boot1.rom).
//
// While a save state operation is running, savestates.sv redirects all CPU
// ROM fetches into bank $FF. On MiSTer the helper binary is loaded there by
// the HPS; on the Pocket it is baked into this BRAM and muxed over the SDRAM
// read data instead. Byte lane behavior matches sdram.sv: word reads return
// the stored little endian word, byte reads place the addressed byte in the
// low byte by swapping on odd addresses.

module boot1_rom (
    input wire clk,

    input wire [11:0] addr,  // byte address within bank $FF
    input wire word,
    output wire [15:0] q
);
  wire [15:0] rom_q;
  reg addr0;

  spram #(
      .addr_width(11),
      .data_width(16),
      .mem_init_file("rtl/mister_top/boot1.mif")
  ) rom (
      .clock(clk),
      .address(addr[11:1]),
      .q(rom_q)
  );

  always @(posedge clk) begin
    addr0 <= addr[0];
  end

  assign q = (~word & addr0) ? {rom_q[7:0], rom_q[15:8]} : rom_q;
endmodule
