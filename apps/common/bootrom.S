# Minimal bootrom loader

  .section .bootcode
  .global _start
  
_start:
  la      a0, __l2_start # load the address to the entry point
  
  nop
  nop
  nop
  nop
  nop
  nop
  nop
  nop

  jr      a0
