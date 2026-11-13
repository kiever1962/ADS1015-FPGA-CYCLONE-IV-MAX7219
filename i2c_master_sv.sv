`timescale 1ns / 1ps
//--------------------------------------------------------------------------------
//
//   FileName:         i2c_master.sv
//   Dependencies:     none
//   Design Software:  Quartus II 64-bit Version 13.1 Build 162 SJ Full Version
//
//   Converted strict one-to-one from VHDL to SystemVerilog (Part 1)
// 
//--------------------------------------------------------------------------------

module i2c_master_sv #(
    parameter int input_clk = 50_000_000, // input clock speed from user logic in Hz
    parameter int bus_clk   = 400_000     // speed the i2c bus (scl) will run at in Hz
)(
    input  logic        clk,              // system clock
    input  logic        reset_n,          // active low reset
    input  logic        ena,              // latch in command
    input  logic [6:0]  addr,             // address of target slave
    input  logic        rw,               // '0' is write, '1' is read
    input  logic [7:0]  data_wr,          // data to write to slave
    output logic        busy,             // indicates transaction in progress
    output logic [7:0]  data_rd,          // data read from slave
    output logic        ack_error,        // flag if improper acknowledge from slave
    inout  logic        sda,              // serial data output of i2c bus
    inout  logic        scl               // serial clock output of i2c bus
);

  localparam int divider = (input_clk / bus_clk) / 4; // number of clocks in 1/4 cycle of scl

  // needed states
  typedef enum logic [3:0] {
    ready, 
    start, 
    command, 
    slv_ack1, 
    wr, 
    rd, 
    slv_ack2, 
    mstr_ack, 
    stop
  } machine;

  machine      state;                      // state machine
  logic        data_clk;                   // data clock for sda
  logic        data_clk_prev;              // data clock during previous system clock
  logic        scl_clk;                    // constantly running internal scl
  logic        scl_ena = 1'b0;             // enables internal scl to output
  logic        sda_int = 1'b1;             // internal sda
  logic        sda_ena_n;                  // enables internal sda to output
  logic [7:0]  addr_rw;                    // latched in address and read/write
  logic [7:0]  data_tx;                    // latched in data to write to slave
  logic [7:0]  data_rx;                    // data received from slave
  int          bit_cnt = 7;                // tracks bit number in transaction (range 0 to 7)
  logic        stretch = 1'b0;             // identifies if slave is stretching scl
  logic        data_clk_m;
  
  int          count;                      // VHDL VARIABLE count moved here to retain state across clocks

  // generate the timing for the bus clock (scl_clk) and the data clock (data_clk)
  always_ff @(posedge clk or negedge reset_n) begin : timing_proc
    if (reset_n == 1'b0) begin             // reset asserted
      stretch <= 1'b0;
      count   = 0;                         // blocking assignment to mimic VHDL variable initialization
    end else begin
      data_clk_prev <= data_clk;           // store previous value of data clock
      if (count == (divider * 4 - 1)) begin // end of timing cycle
        count = 0;                         // reset timer
      end else if (stretch == 1'b0) begin  // clock stretching from slave not detected
        count = count + 1;                 // continue clock generation timing
      end
      
      // Case structure replicating VHDL logic exactly
      if (count >= 0 && count <= (divider - 1)) begin // first 1/4 cycle of clocking
        scl_clk  <= 1'b0;
        data_clk <= 1'b0;
      end 
      else if (count >= divider && count <= (divider * 2 - 1)) begin // second 1/4 cycle of clocking
        scl_clk  <= 1'b0;
        data_clk <= 1'b1;
      end 
      else if (count >= (divider * 2) && count <= (divider * 3 - 1)) begin // third 1/4 cycle of clocking
        scl_clk <= 1'b1;                   // release scl
        if (scl == 1'b0) begin             // detect if slave is stretching clock
          stretch <= 1'b1;
        end else begin
          stretch <= 1'b0;
        end
        data_clk <= 1'b1;
      end 
      else begin                           // OTHERS => last 1/4 cycle of clocking
        scl_clk  <= 1'b1;
        data_clk <= 1'b0;
      end
    end
  end
  // state machine and writing to sda during scl low (data_clk rising edge)
  always_ff @(posedge clk or negedge reset_n) begin : fsm_proc
    if (reset_n == 1'b0) begin             // reset asserted
      state     <= ready;                  // return to initial state
      busy      <= 1'b1;                   // indicate not available
      scl_ena   <= 1'b0;                   // sets scl high impedance
      sda_int   <= 1'b1;                   // sets sda high impedance
      ack_error <= 1'b0;                   // clear acknowledge error flag
      bit_cnt   <= 7;                      // restarts data bit counter
      data_rd   <= 8'b00000000;            // clear data read port
    end else begin
      if (data_clk == 1'b1 && data_clk_prev == 1'b0) begin // data clock rising edge
        case (state)
          ready: begin                     // idle state
            if (ena == 1'b1) begin         // transaction requested
              busy    <= 1'b1;             // flag busy
              addr_rw <= {addr, rw};       // collect requested slave address and command
              data_tx <= data_wr;          // collect requested data to write
              state   <= start;            // go to start bit
            end else begin                 // remain idle
              busy    <= 1'b0;             // unflag busy
              state   <= ready;            // remain idle
            end
          end

          start: begin                     // start bit of transaction
            busy    <= 1'b1;               // resume busy if continuous mode
            sda_int <= addr_rw[bit_cnt];   // set first address bit to bus
            state   <= command;            // go to command
          end

          command: begin                   // address and command byte of transaction
            if (bit_cnt == 0) begin        // command transmit finished
              sda_int <= 1'b1;             // release sda for slave acknowledge
              bit_cnt <= 7;                // reset bit counter for "byte" states
              state   <= slv_ack1;         // go to slave acknowledge (command)
            end else begin                 // next clock cycle of command state
              bit_cnt <= bit_cnt - 1;      // keep track of transaction bits
              sda_int <= addr_rw[bit_cnt-1]; // write address/command bit to bus
              state   <= command;          // continue with command
            end
          end

          slv_ack1: begin                  // slave acknowledge bit (command)
            if (addr_rw[0] == 1'b0) begin  // write command (fixed slice index)
              sda_int <= data_tx[bit_cnt]; // write first bit of data
              state   <= wr;               // go to write byte
            end else begin                 // read command
              sda_int <= 1'b1;             // release sda from incoming data
              state   <= rd;               // go to read byte
            end
          end

          wr: begin                        // write byte of transaction
            busy <= 1'b1;                  // resume busy if continuous mode
            if (bit_cnt == 0) begin        // write byte transmit finished
              sda_int <= 1'b1;             // release sda for slave acknowledge
              bit_cnt <= 7;                // reset bit counter for "byte" states
              busy    <= 1'b0;             // modified
              state   <= slv_ack2;         // go to slave acknowledge (write)
            end else begin                 // next clock cycle of write state
              bit_cnt <= bit_cnt - 1;      // keep track of transaction bits
              sda_int <= data_tx[bit_cnt-1]; // write next bit to bus
              state   <= wr;               // continue writing
            end
          end

          rd: begin                        // read byte of transaction
            busy <= 1'b1;                  // resume busy if continuous mode
            if (bit_cnt == 0) begin        // read byte receive finished
              if ((ena == 1'b1) && (addr_rw == {addr, rw})) begin // continuing with another read at same address
                sda_int <= 1'b0;           // acknowledge the byte has been received
              end else begin               // stopping or continuing with a write
                sda_int <= 1'b1;           // send a no-acknowledge (before stop or repeated start)
              end
              bit_cnt <= 7;                // reset bit counter for "byte" states
              data_rd <= data_rx;          // output received data
              state   <= mstr_ack;         // go to master acknowledge
            end else begin                 // next clock cycle of read state
              bit_cnt <= bit_cnt - 1;      // keep track of transaction bits
              state   <= rd;               // continue reading
            end
          end

          slv_ack2: begin                  // slave acknowledge bit (write)
            if (ena == 1'b1) begin         // continue transaction
              // busy <= 1'b0;            // continue is accepted
              addr_rw <= {addr, rw};       // collect requested slave address and command
              data_tx <= data_wr;          // collect requested data to write
              if (addr_rw == {addr, rw}) begin // continue transaction with another write
                busy    <= 1'b1;
                sda_int <= data_wr[bit_cnt]; // write first bit of data
                state   <= wr;             // go to write byte
              end else begin               // continue transaction with a read or new slave
                state <= start;            // go to repeated start
              end
            end else begin                 // complete transaction
              state <= stop;               // go to stop bit
            end
          end

          mstr_ack: begin                  // master acknowledge bit after a read
            if (ena == 1'b1) begin         // continue transaction
              busy    <= 1'b0;             // continue is accepted and data received is available on bus
              addr_rw <= {addr, rw};       // collect requested slave address and command
              data_tx <= data_wr;          // collect requested data to write
              if (addr_rw == {addr, rw}) begin // continue transaction with another read
                sda_int <= 1'b1;           // release sda from incoming data
                state   <= rd;             // go to read byte
              end else begin               // continue transaction with a write or new slave
                state <= start;            // repeated start
              end
            end else begin                 // complete transaction
              state <= stop;               // go to stop bit
            end
          end

          stop: begin                      // stop bit of transaction
            busy  <= 1'b0;                 // unflag busy
            state <= ready;                // go to idle state
          end
        endcase
      end 
      else if (data_clk == 1'b0 && data_clk_prev == 1'b1) begin // data clock falling edge
        case (state)
          start: begin
            if (scl_ena == 1'b0) begin     // starting new transaction
              scl_ena   <= 1'b1;           // enable scl output
              ack_error <= 1'b0;           // reset acknowledge error output
            end
          end
          
          slv_ack1: begin                  // receiving slave acknowledge (command)
            if ((sda !== 1'b0) || (ack_error == 1'b1)) begin // no-acknowledge or previous no-acknowledge
              ack_error <= 1'b1;           // set error output if no-acknowledge
            end
          end
          
          rd: begin                        // receiving slave data
            data_rx[bit_cnt] <= sda;       // receive current slave data bit
          end
          
          slv_ack2: begin                  // receiving slave acknowledge (write)
            if ((sda !== 1'b0) || (ack_error == 1'b1)) begin // no-acknowledge or previous no-acknowledge
              ack_error <= 1'b1;           // set error output if no-acknowledge
            end
          end
          
          stop: begin
            scl_ena <= 1'b0;               // disable scl
          end
          
          default: begin
            // OTHERS => NULL
          end
        endcase
      end
    end
  end

  // set sda output
  assign data_clk_m = data_clk_prev && data_clk;
  
  // VHDL WITH...SELECT translated strictly using continuous assignment with conditional operators
  assign sda_ena_n = (state == start) ? data_clk :
                     (state == stop)  ? !data_clk_m :
                                        sda_int; // OTHERS

  // set scl and sda outputs (Tri-state buffers)
  assign scl = ((scl_ena == 1'b1) && (scl_clk == 1'b0)) ? 1'b0 : 1'bz;
  assign sda = (sda_ena_n == 1'b0) ? 1'b0 : 1'bz;

endmodule
