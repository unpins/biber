/* Embed the @INC ZIP blob as data with controlled symbols + keep the stack
 * non-exec. (Mach-O variant in blob_darwin.S.) Mirrors unpins/perl's blob.S. */
.section .rodata
.global _binary_incblob_start
.global _binary_incblob_end
_binary_incblob_start:
.incbin "incblob"
_binary_incblob_end:
#if defined(__arm__)
.section .note.GNU-stack,"",%progbits
#else
.section .note.GNU-stack,"",@progbits
#endif
