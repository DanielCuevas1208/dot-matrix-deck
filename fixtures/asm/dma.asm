; dma.asm - verifies OAM DMA for the headless runner.
;
; The ROM fills WRAM page C0 with a known pattern, starts a DMA transfer
; into OAM, and compares the result. It prints PASS or FAIL over the
; serial port. Regenerate dma.gb with `zig build fixtures`.

    ORG $0000

    ORG $0100
    NOP
    JP init

    ORG $0134
    DB "DMA TEST"           ; cartridge title
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
    DB $0F                  ; header checksum
    ORG $014E
    DB $00, $00             ; version
    ORG $0150

init:
    ; Fill WRAM C000-C09F with the values 00..9F.
    LD HL,$C000
    LD B,$A0
    XOR A
fill:
    LD (HL),A
    INC HL
    INC A
    DEC B
    JR NZ,fill

    ; Start a DMA transfer from page C0 into OAM.
    LD A,$C0
    LDH ($46),A

    ; Wait for the 160-cycle transfer to finish.
    LD B,$40
wait:
    NOP
    NOP
    NOP
    DEC B
    JR NZ,wait

    ; Compare each OAM byte against the WRAM pattern.
    LD HL,$FE00
    LD DE,$C000
    LD B,$A0
verify:
    LD A,(DE)
    LD C,A
    LD A,(HL)
    CP C
    JR NZ,fail
    INC HL
    INC DE
    DEC B
    JR NZ,verify

    LD HL,msg_pass
    CALL print_string
    JR done

fail:
    LD HL,msg_fail
    CALL print_string
done:
    JR done

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

msg_pass:
    DB "PASS", $0D, $0A, $00

msg_fail:
    DB "FAIL", $0D, $0A, $00

    PAD $8000
