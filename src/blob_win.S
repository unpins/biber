/* COFF/PE variant of blob.S: embed the @INC ZIP blob as rodata. On x86_64
 * mingw, C identifiers carry no leading underscore, so the asm labels match
 * `extern ... incblob_start[]` in vfs_miniz.c's _WIN32 branch directly. PE has
 * no GNU-stack note concept (ELF-only), so it's just the incbin between labels. */
    .section .rodata
    .global incblob_start
    .global incblob_end
incblob_start:
    .incbin "incblob"
incblob_end:
