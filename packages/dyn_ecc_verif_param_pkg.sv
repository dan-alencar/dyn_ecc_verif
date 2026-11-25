`ifndef DYN_ECC_VERIF_PARAM_PKG_SV
`define DYN_ECC_VERIF_PARAM_PKG_SV

package dyn_ecc_verif_param_pkg;

  parameter DEC_WORD_WIDTH    = 8;
  parameter ENC_WORD_WIDTH    = 2*DEC_WORD_WIDTH;
  // TBEC-RSC algorithm select passed to the NASCERR DUT:
  //   0 = 2D2P4X, 1 = 4D4X, any other value = current implementation.
  parameter TBEC_RSC_ALGORITHM = 1;

endpackage : dyn_ecc_verif_param_pkg

`endif // DYN_ECC_VERIF_PARAM_PKG_SV
