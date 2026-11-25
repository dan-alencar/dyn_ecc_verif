// dyn_ecc scoreboard. Receives transactions from each monitored interface via
// its own analysis implementation port. Separate ports are declared with
// `uvm_analysis_imp_decl so that a single component can expose one write method
// per source (write_mcu, write_sb, write_sram0, write_sram1).
//
// The write methods are intentionally empty for now - this wires up the TLM
// plumbing; the checking logic will be added later.

// Declare the specialized analysis imp ports (one suffix per source).
`uvm_analysis_imp_decl(_mcu)
`uvm_analysis_imp_decl(_sb)
`uvm_analysis_imp_decl(_sram0)
`uvm_analysis_imp_decl(_sram1)

class dyn_ecc_scbd extends uvm_scoreboard;

  `uvm_component_utils(dyn_ecc_scbd)

  // One analysis imp per interface. The MCU and the two SRAMs carry
  // sram_seq_item; the sideband carries sideband_seq_item.
  uvm_analysis_imp_mcu   #(sram_seq_item,     dyn_ecc_scbd) mcu_imp;
  uvm_analysis_imp_sb    #(sideband_seq_item, dyn_ecc_scbd) sb_imp;
  uvm_analysis_imp_sram0 #(sram_seq_item,     dyn_ecc_scbd) sram0_imp;
  uvm_analysis_imp_sram1 #(sram_seq_item,     dyn_ecc_scbd) sram1_imp;

  // Per-interface FIFOs holding the observed data words, in arrival order.
  // Split by operation: write transactions and read transactions each queue.
  bit [SRAM_DATA_WIDTH-1:0] mcu_write_t_q   [$];
  bit [SRAM_DATA_WIDTH-1:0] mcu_read_t_q    [$];
  bit [SRAM_DATA_WIDTH-1:0] sram0_write_t_q [$];
  bit [SRAM_DATA_WIDTH-1:0] sram0_read_t_q  [$];
  bit [SRAM_DATA_WIDTH-1:0] sram1_write_t_q [$];
  bit [SRAM_DATA_WIDTH-1:0] sram1_read_t_q  [$];
  sel_t ecc_write_cfg_q [$]; // ECC Configuration when the Data is written
  sel_t ecc_read_cfg_q [$]; // ECC Configuration when the Data is read

  // ECC Selection
  sel_t ecc_sel; // Current ECC configuration

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    mcu_imp   = new("mcu_imp",   this);
    sb_imp    = new("sb_imp",    this);
    sram0_imp = new("sram0_imp", this);
    sram1_imp = new("sram1_imp", this);
  endfunction

  // ---- Analysis write methods (one per source; empty for now) ---------------
  virtual function void write_mcu(sram_seq_item t);
    if (t.op == SRAM_WRITE) begin
      mcu_write_t_q.push_back(t.data);
      `uvm_info(get_type_name(),
                $sformatf("pushed mcu_write_t_q <= 0x%0h", t.data), UVM_HIGH)
      ecc_write_cfg_q.push_back(ecc_sel);
    end
    else begin
      mcu_read_t_q.push_back(t.data);
      `uvm_info(get_type_name(),
                $sformatf("pushed mcu_read_t_q <= 0x%0h", t.data), UVM_HIGH)
      ecc_read_cfg_q.push_back(ecc_sel);
    end
    
  endfunction

  virtual function void write_sb(sideband_seq_item t);
    // TODO: collect the sideband (mode-select) transaction.
    ecc_sel = t.wdata;
  endfunction

  virtual function void write_sram0(sram_seq_item t);
    if (t.op == SRAM_WRITE) begin
      sram0_write_t_q.push_back(t.data);
      `uvm_info(get_type_name(),
                $sformatf("pushed sram0_write_t_q <= 0x%0h", t.data), UVM_HIGH)
    end
    else begin
      sram0_read_t_q.push_back(t.data);
      `uvm_info(get_type_name(),
                $sformatf("pushed sram0_read_t_q <= 0x%0h", t.data), UVM_HIGH)
    end
  endfunction

  virtual function void write_sram1(sram_seq_item t);
    if (t.op == SRAM_WRITE) begin
      sram1_write_t_q.push_back(t.data);
      `uvm_info(get_type_name(),
                $sformatf("pushed sram1_write_t_q <= 0x%0h", t.data), UVM_HIGH)
    end
    else begin
      sram1_read_t_q.push_back(t.data);
      `uvm_info(get_type_name(),
                $sformatf("pushed sram1_read_t_q <= 0x%0h", t.data), UVM_HIGH)
    end
  endfunction

  // ---- End-of-test checking -------------------------------------------------
  function void check_phase(uvm_phase phase);
    sel_t                     cfg;
    bit [SRAM_DATA_WIDTH-1:0] mcu_d, s0_d, s1_d;
    logic [15:0]              enc;
    logic [7:0]               dec;

    super.check_phase(phase);

    // ---- Queue-size consistency ---------------------------------------------
    assert (mcu_write_t_q.size() == sram0_write_t_q.size() &&
            mcu_write_t_q.size() == sram1_write_t_q.size() &&
            mcu_write_t_q.size() == ecc_write_cfg_q.size())
      else `uvm_error(get_type_name(),
        $sformatf("WRITE queue size mismatch: mcu=%0d sram0=%0d sram1=%0d cfg=%0d",
                  mcu_write_t_q.size(), sram0_write_t_q.size(),
                  sram1_write_t_q.size(), ecc_write_cfg_q.size()))

    assert (mcu_read_t_q.size() == sram0_read_t_q.size() &&
            mcu_read_t_q.size() == sram1_read_t_q.size() &&
            mcu_read_t_q.size() == ecc_read_cfg_q.size())
      else `uvm_error(get_type_name(),
        $sformatf("READ queue size mismatch: mcu=%0d sram0=%0d sram1=%0d cfg=%0d",
                  mcu_read_t_q.size(), sram0_read_t_q.size(),
                  sram1_read_t_q.size(), ecc_read_cfg_q.size()))

    // ---- WRITE path: MCU data vs what landed in the SRAMs -------------------
    while (ecc_write_cfg_q.size() > 0) begin
      cfg   = ecc_write_cfg_q.pop_front();
      case (cfg)
        BYPASS_UP: begin
          mcu_d = mcu_write_t_q.pop_front();
          s0_d  = sram0_write_t_q.pop_front();
          s1_d  = sram1_write_t_q.pop_front();
          `uvm_info(get_type_name(),
                    $sformatf("WRITE BYPASS_UP: comparing mcu=0x%0h vs sram0=0x%0h",
                              mcu_d[7:0], s0_d[7:0]), UVM_HIGH)
          assert (mcu_d[7:0] == s0_d[7:0])
            else `uvm_error(get_type_name(),
              $sformatf("WRITE BYPASS_UP mismatch: mcu=0x%0h sram0=0x%0h",
                        mcu_d[7:0], s0_d[7:0]))
        end
        BYPASS_DOWN: begin
          mcu_d = mcu_write_t_q.pop_front();
          s0_d  = sram0_write_t_q.pop_front();
          s1_d  = sram1_write_t_q.pop_front();
          `uvm_info(get_type_name(),
                    $sformatf("WRITE BYPASS_DOWN: comparing mcu=0x%0h vs sram1=0x%0h",
                              mcu_d[7:0], s1_d[7:0]), UVM_HIGH)
          assert (mcu_d[7:0] == s1_d[7:0])
            else `uvm_error(get_type_name(),
              $sformatf("WRITE BYPASS_DOWN mismatch: mcu=0x%0h sram1=0x%0h",
                        mcu_d[7:0], s1_d[7:0]))
        end
        TBEC_RSC: begin
          mcu_d = mcu_write_t_q.pop_front();
          s0_d  = sram0_write_t_q.pop_front();
          s1_d  = sram1_write_t_q.pop_front();
          enc   = enc_tbec_rsc_sel(mcu_d[7:0]);
          `uvm_info(get_type_name(),
                    $sformatf("WRITE TBEC_RSC: enc(mcu=0x%0h)=0x%0h; comparing msb=0x%0h vs sram0=0x%0h, lsb=0x%0h vs sram1=0x%0h",
                              mcu_d[7:0], enc, enc[15:8], s0_d[7:0], enc[7:0], s1_d[7:0]),
                    UVM_HIGH)
          assert (enc[15:8] == s0_d[7:0])
            else `uvm_error(get_type_name(),
              $sformatf("WRITE TBEC_RSC up mismatch: enc_msb=0x%0h sram0=0x%0h",
                        enc[15:8], s0_d[7:0]))
          assert (enc[7:0] == s1_d[7:0])
            else `uvm_error(get_type_name(),
              $sformatf("WRITE TBEC_RSC down mismatch: enc_lsb=0x%0h sram1=0x%0h",
                        enc[7:0], s1_d[7:0]))
        end
        MRSC: begin
          // @TODO: MRSC write check.
        end
      endcase
    end

    // ---- READ path: SRAM contents (decoded) vs MCU read data ----------------
    while (ecc_read_cfg_q.size() > 0) begin
      cfg   = ecc_read_cfg_q.pop_front();
      case (cfg)
        BYPASS_UP: begin
          mcu_d = mcu_read_t_q.pop_front();
          s0_d  = sram0_read_t_q.pop_front();
          s1_d  = sram1_read_t_q.pop_front();
          `uvm_info(get_type_name(),
                    $sformatf("READ BYPASS_UP: comparing mcu=0x%0h vs sram0=0x%0h",
                              mcu_d[7:0], s0_d[7:0]), UVM_HIGH)
          assert (mcu_d[7:0] == s0_d[7:0])
            else `uvm_error(get_type_name(),
              $sformatf("READ BYPASS_UP mismatch: mcu=0x%0h sram0=0x%0h",
                        mcu_d[7:0], s0_d[7:0]))
        end
        BYPASS_DOWN: begin
          mcu_d = mcu_read_t_q.pop_front();
          s0_d  = sram0_read_t_q.pop_front();
          s1_d  = sram1_read_t_q.pop_front();
          `uvm_info(get_type_name(),
                    $sformatf("READ BYPASS_DOWN: comparing mcu=0x%0h vs sram1=0x%0h",
                              mcu_d[7:0], s1_d[7:0]), UVM_HIGH)
          assert (mcu_d[7:0] == s1_d[7:0])
            else `uvm_error(get_type_name(),
              $sformatf("READ BYPASS_DOWN mismatch: mcu=0x%0h sram1=0x%0h",
                        mcu_d[7:0], s1_d[7:0]))
        end
        TBEC_RSC: begin
          mcu_d = mcu_read_t_q.pop_front();
          s0_d  = sram0_read_t_q.pop_front();
          s1_d  = sram1_read_t_q.pop_front();
          dec   = dec_tbec_rsc_sel({s0_d[7:0], s1_d[7:0]});
          `uvm_info(get_type_name(),
                    $sformatf("READ TBEC_RSC: dec({sram0=0x%0h,sram1=0x%0h})=0x%0h; comparing vs mcu=0x%0h",
                              s0_d[7:0], s1_d[7:0], dec, mcu_d[7:0]), UVM_HIGH)
          assert (dec == mcu_d[7:0])
            else `uvm_error(get_type_name(),
              $sformatf("READ TBEC_RSC mismatch: dec=0x%0h mcu=0x%0h",
                        dec, mcu_d[7:0]))
        end
        MRSC: begin
          // @TODO: MRSC read check.
        end
      endcase
    end
  endfunction

  // ---- Reference models -----------------------------------------------------
  // Software mirror of NASCERR/rtl/tbec_rsc_encoder.sv: 8-bit data in, 16-bit
  // codeword out.
  // @TODO: This is a RTL mirror what is not ideal, but we do not have the 
  // documentation yet for 8 bits. There is probaly a issue with this model. When
  // we have, adapt this methos
  function logic [15:0] enc_tbec_rsc(logic [7:0] data_in);
    logic [1:0] Di, P, Cb0, Cb1;

    Di  = {data_in[1] ^ data_in[3] ^ data_in[4] ^ data_in[6],
           data_in[0] ^ data_in[2] ^ data_in[5] ^ data_in[7]};
    P   = {data_in[2] ^ data_in[3] ^ data_in[6] ^ data_in[7],
           data_in[0] ^ data_in[1] ^ data_in[4] ^ data_in[5]};
    Cb1 = {data_in[5] ^ data_in[7], data_in[1] ^ data_in[3]};
    Cb0 = {data_in[4] ^ data_in[6], data_in[0] ^ data_in[2]};

    return {Cb1, Cb0, P, Di, data_in};
  endfunction

  // Software mirror of NASCERR/rtl/tbec_rsc_decoder.sv: 16-bit codeword in,
  // 8-bit corrected data out.
  // @TODO: This is a RTL mirror what is not ideal, but we do not have the 
  // documentation yet for 8 bits. There is probaly a issue with this model. When
  // we have, adapt this methos
  function logic [7:0] dec_tbec_rsc(logic [15:0] data_in);
    logic [7:0] signal, red;
    logic [1:0] linsin [0:1];
    logic [1:0] SP, SDi;
    logic [2:0] sumSL;
    logic [1:0] sumSP, sumSDi;

    {red, signal} = data_in;

    linsin[1] = {signal[5] ^ signal[7] ^ red[7], signal[4] ^ signal[6] ^ red[6]};
    linsin[0] = {signal[1] ^ signal[3] ^ red[5], signal[0] ^ signal[2] ^ red[4]};

    SP  = {signal[2] ^ signal[3] ^ signal[6] ^ signal[7] ^ red[3],
           signal[0] ^ signal[1] ^ signal[4] ^ signal[5] ^ red[2]};
    SDi = {signal[1] ^ signal[3] ^ signal[4] ^ signal[6] ^ red[1],
           signal[0] ^ signal[2] ^ signal[5] ^ signal[7] ^ red[0]};

    sumSP  = {1'b0, SP[0]}  + {1'b0, SP[1]};
    sumSDi = {1'b0, SDi[0]} + {1'b0, SDi[1]};
    sumSL  = {2'b0, linsin[0][0]} + {2'b0, linsin[0][1]}
           + {2'b0, linsin[1][0]} + {2'b0, linsin[1][1]};

    if (((SP != '0 && SDi != '0) || sumSL > 1) &&
        !(sumSDi == 0 && sumSP == 1 && sumSL >= 2)) begin
      if (SP[0] > SP[1]) begin
        for (int i = 0; i < 2; i++) begin
          if (linsin[i] != '0) begin
            signal[i]   ^= linsin[i][0];
            signal[i+4] ^= linsin[i][1];
          end
        end
      end else if (SP[0] < SP[1]) begin
        for (int i = 2; i < 4; i++) begin
          if (linsin[i-2] != '0) begin
            signal[i]   ^= linsin[i-2][0];
            signal[i+4] ^= linsin[i-2][1];
          end
        end
      end else if (SP[0] == SP[1] && {SDi, SP} != '0) begin
        for (int i = 1; i < 3; i++) begin
          if (linsin[i-1] != '0) begin
            signal[i]   ^= linsin[i-1][1];
            signal[i+4] ^= linsin[i-1][0];
          end
        end
      end
    end

    return signal;
  endfunction

  // Software model of the 8-bit MRSC encoder, from
  // doc/mrsc-8bit-matrix-architecture.md (sections 2 and 6).
  //
  // Data maps to a 2x4 matrix: M[0]={D7,D6,D5,D4}, M[1]={D3,D2,D1,D0}.
  // 12 redundancy bits are generated: Cb (horizontal, stride 2), Di (diagonal),
  // P (per-column parity). Returns the 20-bit codeword {data, Cb, Di, P} with
  // group bit b holding subscript b (cb[0]=Cb_0 .. cb[3]=Cb_3, etc.).
  function logic [19:0] enc_mrsc(logic [7:0] data_in);
    logic [3:0] cb, di, p;

    // Check bits: Cb[r,k] = M[r,k] ^ M[r,k+2]
    cb[0] = data_in[7] ^ data_in[5]; // Cb0 = D7 ^ D5
    cb[1] = data_in[6] ^ data_in[4]; // Cb1 = D6 ^ D4
    cb[2] = data_in[3] ^ data_in[1]; // Cb2 = D3 ^ D1
    cb[3] = data_in[2] ^ data_in[0]; // Cb3 = D2 ^ D0

    // Diagonal bits (two per 2x2 half).
    di[0] = data_in[7] ^ data_in[2]; // Di0 = D7 ^ D2
    di[1] = data_in[6] ^ data_in[3]; // Di1 = D6 ^ D3
    di[2] = data_in[5] ^ data_in[0]; // Di2 = D5 ^ D0
    di[3] = data_in[4] ^ data_in[1]; // Di3 = D4 ^ D1

    // Column parity: P[c] = M[0,c] ^ M[1,c]
    p[0]  = data_in[7] ^ data_in[3]; // P0 = D7 ^ D3
    p[1]  = data_in[6] ^ data_in[2]; // P1 = D6 ^ D2
    p[2]  = data_in[5] ^ data_in[1]; // P2 = D5 ^ D1
    p[3]  = data_in[4] ^ data_in[0]; // P3 = D4 ^ D0

    return {data_in, cb, di, p};
  endfunction

  // Software model of the 8-bit MRSC decoder, from
  // doc/mrsc-8bit-matrix-architecture.md (sections 3 and 6). Takes the 20-bit
  // codeword {data, Cb, Di, P} (same layout enc_mrsc produces) and returns the
  // 8-bit corrected data word.
  function logic [7:0] dec_mrsc(logic [19:0] code_in);
    logic [7:0] d, data_out;
    logic [3:0] cb, di, p;
    logic       SL00, SL01, SL10, SL11;      // check syndrome matrix (2x2)
    logic       SDi0, SDi1, SDi2, SDi3;      // diagonal syndromes
    logic       SP0, SP1, SP2, SP3;          // column-parity syndromes
    logic [2:0] sl_weight, q1, q2;
    logic       acionar;

    {d, cb, di, p} = code_in;

    // Check syndromes: SL[r,k] = Cb'[r,k] ^ (M'[r,k] ^ M'[r,k+2])
    SL00 = cb[0] ^ (d[7] ^ d[5]);
    SL01 = cb[1] ^ (d[6] ^ d[4]);
    SL10 = cb[2] ^ (d[3] ^ d[1]);
    SL11 = cb[3] ^ (d[2] ^ d[0]);

    // Diagonal syndromes.
    SDi0 = di[0] ^ (d[7] ^ d[2]);
    SDi1 = di[1] ^ (d[6] ^ d[3]);
    SDi2 = di[2] ^ (d[5] ^ d[0]);
    SDi3 = di[3] ^ (d[4] ^ d[1]);

    // Column-parity syndromes.
    SP0  = p[0] ^ (d[7] ^ d[3]);
    SP1  = p[1] ^ (d[6] ^ d[2]);
    SP2  = p[2] ^ (d[5] ^ d[1]);
    SP3  = p[3] ^ (d[4] ^ d[0]);

    // Activation: (SP != 0 AND SDi != 0) OR weight(SL) > 1.
    sl_weight = {2'b0, SL00} + {2'b0, SL01} + {2'b0, SL10} + {2'b0, SL11};
    acionar   = ((SP0 | SP1 | SP2 | SP3) & (SDi0 | SDi1 | SDi2 | SDi3)) |
                (sl_weight > 1);

    // Regional voting tallies.
    q1 = {2'b0, SP0} + {2'b0, SP1} + {2'b0, SDi0} + {2'b0, SDi1};
    q2 = {2'b0, SP2} + {2'b0, SP3} + {2'b0, SDi2} + {2'b0, SDi3};

    data_out = d;
    if (acionar) begin
      if (q1 > q2) begin
        // Region 1: columns 0 & 1 (D7, D6, D3, D2).
        data_out[7] = d[7] ^ SL00;
        data_out[6] = d[6] ^ SL01;
        data_out[3] = d[3] ^ SL10;
        data_out[2] = d[2] ^ SL11;
      end else if (q1 < q2) begin
        // Region 2: columns 2 & 3 (D5, D4, D1, D0).
        data_out[5] = d[5] ^ SL00;
        data_out[4] = d[4] ^ SL01;
        data_out[1] = d[1] ^ SL10;
        data_out[0] = d[0] ^ SL11;
      end else if (q1 != 3'b000) begin
        // Region 3: center boundary, columns 1 & 2 with SL columns swapped.
        data_out[6] = d[6] ^ SL01;
        data_out[5] = d[5] ^ SL00;
        data_out[2] = d[2] ^ SL11;
        data_out[1] = d[1] ^ SL10;
      end
    end

    return data_out;
  endfunction

  // ===========================================================================
  //  TBEC-RSC-8 "no-LUT" variants, modelled strictly from NASCERR/docs/*:
  //    - TBEC-RSC-8_2D2P4X.pdf  (2 diagonals D + 2 parities P + 4 cross-checks X)
  //    - TBEC-RSC-8_4D4X.pdf    (4 diagonals D + 4 cross-checks X)
  //
  //  Physical 16-bit word (both docs, Figure 1), positions 1..16:
  //    pos:  1  2  3  4  5  6  7  8 | 9  10 11 12 | 13   14   15   16
  //          A1 B1 A2 B2 A3 B3 A4 B4| D1 D2 P1 P2 | XA13 XA24 XB13 XB24  (2D2P4X)
  //          A1 B1 A2 B2 A3 B3 A4 B4| D1 D2 D3 D4 | XA13 XA24 XB13 XB24  (4D4X)
  //
  //  The data form a 2x4 logical matrix (row A: A1..A4, row B: B1..B4), stored
  //  physically column by column. The 8-bit data word is carried MSB-first in
  //  physical order, so for data_in[7:0]:
  //    data_in[7]=A1 [6]=B1 [5]=A2 [4]=B2 [3]=A3 [2]=B3 [1]=A4 [0]=B4.
  //  (Checked against the docs' worked example d=11100101 = "A1 B1 A2 B2 A3 B3
  //   A4 B4", which the string spells out directly.)
  //
  //  Codeword packing used here (16-bit value = {up byte, down byte}):
  //    code[15:8] = the 8 data bits (physical positions 1..8), i.e. == data_in;
  //    code[7:4]  = the D/P (or D) controls (positions 9..12);
  //    code[3:0]  = the four X cross-checks (positions 13..16).
  //  Thus bit index i of the 16-bit value maps to physical position (16-i), so
  //  bit adjacency == physical adjacency (needed by the burst-3 window test).
  // ===========================================================================

  // Unpack an 8-bit data/mask word into the 8 named cells (A1..B4), physical
  // column order. data[7]=A1 ... data[0]=B4 (see layout note above).
  // {D1,D2,P1,P2} for the 2D2P4X code (doc 2D2P4X, sections 2.1 and 2.2).
  function logic [3:0] ctrl_2d2p(logic [7:0] data);
    logic A1,B1,A2,B2,A3,B3,A4,B4;
    {A1,B1,A2,B2,A3,B3,A4,B4} = data;
    return { A2 ^ A3 ^ B4,        // D1 = A2 (+) A3 (+) B4
             A1 ^ A2 ^ B2 ^ A4,   // D2 = A1 (+) A2 (+) B2 (+) A4
             A1 ^ B1 ^ A2 ^ B2,   // P1 = A1 (+) B1 (+) A2 (+) B2
             A3 ^ B3 ^ A4 ^ B4 }; // P2 = A3 (+) B3 (+) A4 (+) B4
  endfunction

  // {D1,D2,D3,D4} for the 4D4X code (doc 4D4X, section 1.1).
  function logic [3:0] ctrl_4d(logic [7:0] data);
    logic A1,B1,A2,B2,A3,B3,A4,B4;
    {A1,B1,A2,B2,A3,B3,A4,B4} = data;
    return { A1 ^ B2 ^ A3,   // D1 = A1 (+) B2 (+) A3
             A2 ^ B1 ^ A4,   // D2 = A2 (+) B1 (+) A4
             A3 ^ B4 ^ B1,   // D3 = A3 (+) B4 (+) B1
             A4 ^ B3 ^ B2 }; // D4 = A4 (+) B3 (+) B2
  endfunction

  // {X_A13,X_A24,X_B13,X_B24}: the four cross-checks, identical in both docs
  // (2D2P4X section 3.3; 4D4X section 1.2).
  function logic [3:0] ctrl_x(logic [7:0] data);
    logic A1,B1,A2,B2,A3,B3,A4,B4;
    {A1,B1,A2,B2,A3,B3,A4,B4} = data;
    return { A1 ^ A3,   // X_A13 = A1 (+) A3
             A2 ^ A4,   // X_A24 = A2 (+) A4
             B1 ^ B3,   // X_B13 = B1 (+) B3
             B2 ^ B4 }; // X_B24 = B2 (+) B4
  endfunction

  // Geometric burst-3 test (2D2P4X section 3.3; 4D4X section 3):
  //   valid(E) <=> E != 0 AND (i_max(E) - i_min(E) + 1 <= 3),
  // i.e. all set bits fit inside a window of at most three positions. Because
  // bit adjacency equals physical adjacency in our packing, scanning the 16 bit
  // indices is equivalent to the window test over physical positions.
  function bit burst3(logic [15:0] E);
    int lo, hi;
    if (E == '0) return 1'b0;
    lo = -1; hi = -1;
    for (int i = 0; i < 16; i++) begin
      if (E[i]) begin
        if (lo == -1) lo = i;
        hi = i;
      end
    end
    return ((hi - lo + 1) <= 3);
  endfunction

  // Three candidate data-error masks m1/m2/m3 generated directly from the X
  // syndrome sX = {u,v,w,z} (u=sX_A13, v=sX_A24, w=sX_B13, z=sX_B24). Same in
  // both docs (2D2P4X section 3.1; 4D4X section 2). Masks are 8-bit data masks
  // in the [A1 B1 A2 B2 A3 B3 A4 B4] order:
  //   m1 = [u w v z 0 0 0 0]  (R1: columns 1,2)
  //   m2 = [0 0 0 0 u w v z]  (R2: columns 3,4)
  //   m3 = [0 0 v z u w 0 0]  (R3: columns 2,3 - note the swapped alignment)
  function void gen_hyp(input logic [3:0] sX,
                        output logic [7:0] m1, m2, m3);
    logic u, v, w, z;
    {u, v, w, z} = sX;
    m1 = {u, w, v, z, 4'b0000};
    m2 = {4'b0000, u, w, v, z};
    m3 = {2'b00, v, z, u, w, 2'b00};
  endfunction

  // --- 2D2P4X encoder --------------------------------------------------------
  // 8-bit data in -> 16-bit codeword {data, D1D2P1P2, X}.
  function logic [15:0] enc_tbec_rsc_2d2p4x(logic [7:0] data_in);
    return {data_in, ctrl_2d2p(data_in), ctrl_x(data_in)};
  endfunction

  // --- 2D2P4X decoder (doc 2D2P4X, section 3, Figure 3) ----------------------
  // 16-bit codeword in -> 8-bit corrected data out.
  function logic [7:0] dec_tbec_rsc_2d2p4x(logic [15:0] code_in);
    logic [7:0]  data;
    logic [3:0]  sDP, sX, eDP;
    logic [7:0]  m [1:3];
    logic [15:0] E;

    data = code_in[15:8];
    // Syndrome s = [sDP | sX]: residual of the D/P controls and the X checks
    // recomputed over the received data.
    sDP = code_in[7:4] ^ ctrl_2d2p(data);
    sX  = code_in[3:0] ^ ctrl_x(data);

    // s = 0: no error visible, keep the data.
    if (sDP == '0 && sX == '0) return data;

    // s itself confined to a <=3 window in the redundancy field (positions
    // 9..16): the burst never touched the data, so preserve it (section 3.4).
    if (burst3({8'b0, sDP, sX})) return data;

    // Otherwise test the three regional hypotheses, in order R1, R2, R3, and
    // accept the first whose full reconstructed error mask passes burst3.
    gen_hyp(sX, m[1], m[2], m[3]);
    for (int j = 1; j <= 3; j++) begin
      if (m[j] == '0) continue;
      eDP = sDP ^ ctrl_2d2p(m[j]);        // residual the burst left on D/P
      E   = {m[j], eDP, 4'b0000};         // [m_j | eDP_j | 0000]
      if (burst3(E)) return data ^ m[j];  // correction applied
    end

    // No valid hypothesis ("nao classificada"): leave the data unchanged.
    return data;
  endfunction

  // --- 4D4X encoder ----------------------------------------------------------
  // 8-bit data in -> 16-bit codeword {data, D1D2D3D4, X}.
  function logic [15:0] enc_tbec_rsc_4d4p(logic [7:0] data_in);
    return {data_in, ctrl_4d(data_in), ctrl_x(data_in)};
  endfunction

  // --- 4D4X decoder (doc 4D4X, sections 2-4, Figure 3) -----------------------
  // 16-bit codeword in -> 8-bit corrected data out.
  function logic [7:0] dec_tbec_rsc_4d4p(logic [15:0] code_in);
    logic [7:0]  data;
    logic [3:0]  sD, sX, eD;
    logic [7:0]  m [1:3];
    logic [15:0] E;

    data = code_in[15:8];
    // Syndrome s = [sD | sX].
    sD = code_in[7:4] ^ ctrl_4d(data);
    sX = code_in[3:0] ^ ctrl_x(data);

    // s = 0: SEM_SINDROME, keep data (pseudocode line 2).
    if (sD == '0 && sX == '0) return data;

    // APENAS_REDUNDANCIA: s fits a <=3 window inside the redundancy field,
    // preserve data (pseudocode line 3).
    if (burst3({8'b0, sD, sX})) return data;

    // Regional hypotheses R1, R2, R3 (pseudocode lines 4-9).
    gen_hyp(sX, m[1], m[2], m[3]);
    for (int j = 1; j <= 3; j++) begin
      if (m[j] == '0) continue;           // line 6
      eD = sD ^ ctrl_4d(m[j]);            // line 7: eD_j = sD (+) fD(m_j)
      E  = {m[j], eD, 4'b0000};           // line 8: [m_j | eD_j | 0000]
      if (burst3(E)) return data ^ m[j];  // line 9: correction applied
    end

    // NAO_CLASSIFICADA (line 10): preserve data.
    return data;
  endfunction

  // --- Algorithm dispatch ----------------------------------------------------
  // Select the TBEC-RSC reference model according to TBEC_RSC_ALGORITHM
  // (dyn_ecc_verif_param_pkg), matching the DUT's elaboration-time choice in
  // NASCERR/rtl/control.sv:
  //   0 = 2D2P4X, 1 = 4D4X, any other value = current (RTL-mirror) model.
  function logic [15:0] enc_tbec_rsc_sel(logic [7:0] data_in);
    case (TBEC_RSC_ALGORITHM)
      0:       return enc_tbec_rsc_2d2p4x(data_in);
      1:       return enc_tbec_rsc_4d4p(data_in);
      default: return enc_tbec_rsc(data_in);
    endcase
  endfunction

  function logic [7:0] dec_tbec_rsc_sel(logic [15:0] code_in);
    case (TBEC_RSC_ALGORITHM)
      0:       return dec_tbec_rsc_2d2p4x(code_in);
      1:       return dec_tbec_rsc_4d4p(code_in);
      default: return dec_tbec_rsc(code_in);
    endcase
  endfunction

endclass
