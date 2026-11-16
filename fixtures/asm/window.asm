; window.asm - verifies window layer rendering and the internal line counter.
;
; The ROM sets WY=72, maps two window rows, and waits for visible frames.
; Regenerate window.gb with `zig build fixtures`.

    ORG $0000

    ORG $0100
    NOP
    JP init

    ORG $0134
    DB "WINDOW TEST"
    ORG $0143
    DB $80
    ORG $0144
    DB $00
    ORG $0147
    DB $00
    ORG $0148
    DB $00
    ORG $0149
    DB $00
    ORG $014C
    DB $0F
    ORG $014E
    DB $00, $00
    ORG $0150

init:
    CALL wait_vblank

    ; Tile 1: solid color 3. Tile 0: color 0.
    LD HL,$8000
    LD BC,$0020
clear_tiles:
    LD (HL),$00
    INC HL
    DEC BC
    LD A,B
    OR C
    JR NZ,clear_tiles

    LD A,$FF
    LD HL,$8010
    LD B,$08
fill_dark:
    LD (HL),A
    INC HL
    LD (HL),A
    INC HL
    DEC B
    JR NZ,fill_dark

    ; Window map at $9800: row 0 -> tile 1, row 1 -> tile 0.
    LD HL,$9800
    LD A,$01
    LD B,$20
fill_row0:
    LD (HL),A
    INC HL
    DEC B
    JR NZ,fill_row0

    XOR A
    LD B,$20
fill_row1:
    LD (HL),A
    INC HL
    DEC B
    JR NZ,fill_row1

    LD A,$91
    LDH ($40),A          ; LCD on, unsigned tiles, bg map $9800.
    LD A,$B1
    LDH ($40),A          ; Enable window and select the $9800 window map.
    LD A,$48
    LDH ($4A),A          ; WY=72: window starts on scanline 72.
    LD A,$07
    LDH ($4B),A          ; WX=7: window starts at screen x=0.

    LD B,$02
frame_loop:
    CALL wait_vblank
    DEC B
    JR NZ,frame_loop

    LD HL,msg_pass
    CALL print_string
    JR done

done:
    JR done

wait_vblank:
    LDH A,($44)
    CP $90
    JR NZ,wait_vblank
    RET

print_string:
    LD A,(HL+)
    OR A
    RET Z
    CALL print_char
    JR print_string

print_char:
    LDH ($01),A
    LD A,$81
    LDH ($02),A
    RET

msg_pass:
    DB "PASS", $0D, $0A, $00