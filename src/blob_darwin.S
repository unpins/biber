/* Mach-O variant of blob.S: embed the @INC ZIP blob with controlled symbols.
 * macOS has no --wrap, so the VFS reader (vfs_miniz.c) references the blob as
 * incblob_{start,end} (C names; asm symbols carry the leading underscore). */
.section __TEXT,__const
.global _incblob_start
.global _incblob_end
_incblob_start:
.incbin "incblob"
_incblob_end:
