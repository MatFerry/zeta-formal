// Reset model for the open-source flow, the counterpart of JasperGold's
// "reset -expression {!rst_n}": rst_n is low in the first cycle and high from
// then on. Registers without a reset value start from an arbitrary value.
module oss_reset (
    input logic clk,
    input logic rst_n
);
  logic released = 1'b0;
  always_ff @(posedge clk) released <= 1'b1;
  a_reset_sequence: assume property (@(posedge clk) rst_n == released);
endmodule

// OSS_TOP is the top module of the task (set with -D on read_slang).
bind `OSS_TOP oss_reset u_oss_reset (.clk(clk), .rst_n(rst_n));
