; demo.asm - a self-contained showcase ROM for dot-matrix-deck.
;
; The ROM turns on the LCD, draws the "DOT MATRIX / DECK" title with a
; dot-matrix font, scrolls the background, and bounces a bright dot.
; It prints "PASS" over the serial port after 64 frames so the headless
; runner can verify the core. Regenerate demo.gb with `zig build fixtures`.

    ORG $0000

    ORG $0100
    NOP
    JP init

    ORG $0134
    DB "DOT MATRIX DECK"    ; cartridge title
    ORG $0143
    DB $80                  ; CGB flag
    ORG $0144
    DB $00                  ; licensee
    ORG $0147
    DB $00                  ; ROM only
    ORG $0148
    DB $00                  ; 32KB ROM
    ORG $0149
    DB $00                  ; no external RAM
    ORG $014C
    DB $33                  ; header checksum
    ORG $014E
    DB $00, $00             ; version
    ORG $0150

init:
    ; Disable the LCD while writing video memory.
    LD A,$00
    LDH ($40),A

    ; Copy the tile set into VRAM. Each tile is 8 data bytes followed by
    ; eight zero bytes; the loop interleaves the hi bytes.
    LD HL,tile_data
    LD DE,$8000
    LD B,$78                ; 15 tiles * 8 bytes
copy_tiles:
    LD A,(HL+)
    LD (DE),A
    INC DE
    LD A,$00
    LD (DE),A
    INC DE
    DEC B
    JR NZ,copy_tiles

    ; Fill the background map with the checker tile. Keep the fill value
    ; in E because A is clobbered by the loop counter check.
    LD HL,$9800
    LD E,$01
    LD BC,$0400             ; 32 * 32 cells
fill_map:
    LD A,E
    LD (HL),A
    INC HL
    DEC BC
    LD A,B
    OR C
    JR NZ,fill_map

    ; Draw the two title lines from encoded text rows.
    LD HL,text_row1
    CALL draw_text
    LD HL,text_row2
    CALL draw_text

    ; Seed the bouncing dot and enable the LCD.
    LD A,$0A
    LD ($C001),A            ; dot_x
    LD ($C006),A            ; prev_x
    LD A,$09
    LD ($C002),A            ; dot_y
    LD ($C007),A            ; prev_y
    LD A,$01
    LD ($C003),A            ; dot_dx
    LD ($C004),A            ; dot_dy
    LD A,$91
    LDH ($40),A

    LD HL,msg_title
    CALL print_string

frame_loop:
    ; Wait for the vertical blank to pace one step per frame.
wait_vblank:
    LDH A,($44)
    CP $90
    JR NZ,wait_vblank

    ; Scroll the background one pixel down.
    LD A,($C000)
    INC A
    LD ($C000),A
    LDH ($42),A

    ; Erase the previous dot position.
    LD A,($C006)
    LD E,A
    LD A,($C007)
    LD D,A
    CALL map_addr
    LD A,$01
    LD (HL),A

    ; Flip the X direction at the left and right edges.
    LD A,($C001)
    CP $13
    JR C,no_flip_x
    LD A,$FF
    LD ($C003),A
    JR move_dot_x
no_flip_x:
    LD A,($C001)
    OR A
    JR NZ,move_dot_x
    LD A,$01
    LD ($C003),A
move_dot_x:
    LD A,($C003)
    LD B,A
    LD A,($C001)
    ADD A,B
    LD ($C001),A

    ; Flip the Y direction at the top and bottom edges.
    LD A,($C002)
    CP $11
    JR C,no_flip_y
    LD A,$FF
    LD ($C004),A
    JR move_dot_y
no_flip_y:
    LD A,($C002)
    OR A
    JR NZ,move_dot_y
    LD A,$01
    LD ($C004),A
move_dot_y:
    LD A,($C004)
    LD B,A
    LD A,($C002)
    ADD A,B
    LD ($C002),A

    ; Draw the dot at its new position.
draw_dot:
    LD A,($C002)
    LD D,A
    LD A,($C001)
    LD E,A
    CALL map_addr
    LD A,$02
    LD (HL),A

    ; Remember the new position so the next frame can erase it.
    LD A,($C001)
    LD ($C006),A
    LD A,($C002)
    LD ($C007),A

    ; After 64 frames print the verdict once and keep animating.
    LD A,($C005)
    INC A
    LD ($C005),A
    CP $40
    JP NZ,frame_loop
    LD A,($C008)
    OR A
    JP NZ,frame_loop
    LD A,$01
    LD ($C008),A
    LD HL,msg_pass
    CALL print_string
    JP frame_loop

; Converts a map cell coordinate in (D=row, E=col) to an address in HL.
map_addr:
    LD H,$00
    LD L,D
    ADD HL,HL
    ADD HL,HL
    ADD HL,HL
    ADD HL,HL
    ADD HL,HL
    LD A,E
    ADD A,L
    LD L,A
    LD A,H
    ADD A,$98
    LD H,A
    RET

; Draws an encoded text row. The row starts with row and column bytes,
; then tile indices, and ends with a zero byte.
draw_text:
    LD A,(HL+)
    LD D,A
    LD A,(HL+)
    LD E,A
    PUSH HL
    CALL map_addr
    POP DE
draw_char_loop:
    LD A,(DE)
    OR A
    JR Z,draw_done
    LD (HL),A
    INC HL
    INC DE
    JR draw_char_loop
draw_done:
    RET

; Prints a zero-terminated string pointed to by HL over the serial port.
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

text_row1:
    DB $03, $05, $03, $04, $05, $00, $06, $07, $05, $08, $09, $0A, $00

text_row2:
    DB $06, $08, $03, $0B, $0C, $0D, $00

msg_title:
    DB "DOT MATRIX DECK", $0D, $0A, $00

msg_pass:
    DB "PASS", $0D, $0A, $00

; Tile 0 is blank, tile 1 is the checker, tile 2 is the dot, and tiles
; 3 through 14 are the dot-matrix font glyphs for the title.
tile_data:
    DB $00, $00, $00, $00, $00, $00, $00, $00    ; tile 0 blank
    DB $AA, $55, $AA, $55, $AA, $55, $AA, $55    ; tile 1 checker
    DB $00, $00, $18, $3C, $3C, $18, $00, $00    ; tile 2 dot
    DB $F0, $88, $88, $88, $88, $88, $F0, $00    ; tile 3 'D'
    DB $70, $88, $88, $88, $88, $88, $70, $00    ; tile 4 'O'
    DB $F8, $20, $20, $20, $20, $20, $20, $00    ; tile 5 'T'
    DB $88, $D8, $A8, $A8, $88, $88, $88, $00    ; tile 6 'M'
    DB $70, $88, $88, $F8, $88, $88, $88, $00    ; tile 7 'A'
    DB $F0, $88, $88, $F0, $A0, $90, $88, $00    ; tile 8 'R'
    DB $F8, $20, $20, $20, $20, $20, $F8, $00    ; tile 9 'I'
    DB $88, $88, $50, $20, $50, $88, $88, $00    ; tile 10 'X'
    DB $F8, $80, $80, $F0, $80, $80, $F8, $00    ; tile 11 'E'
    DB $70, $88, $80, $80, $80, $88, $70, $00    ; tile 12 'C'
    DB $88, $90, $A0, $C0, $A0, $90, $88, $00    ; tile 13 'K'
    DB $00, $00, $00, $00, $00, $00, $00, $00    ; tile 14 space

    PAD $8000
