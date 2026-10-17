; timer.asm - verifies the timer overflow interrupt path.
;
; The ROM enables TIMA, waits for an overflow, and checks IF bit 2.
; Regenerate timer.gb with `zig build fixtures`.

    ORG $0000

    ORG $0100
    NOP
    JP init

    ORG $0134
    DB "TIMER TEST"
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
    ; Clear old requests and configure a fast timer.
    LD A,$00
    LDH ($0F),A
    LD A,$42
    LDH ($06),A
    LD A,$FF
    LDH ($05),A
    LD A,$05
    LDH ($07),A

    ; The timer must overflow before this short delay ends.
    LD B,$03
wait:
    NOP
    DEC B
    JR NZ,wait

    LDH A,($0F)
    AND $04
    CP $04
    JR NZ,fail

    LD HL,msg_pass
    CALL print_string
    JR done

fail:
    LD HL,msg_fail
    CALL print_string
done:
    JR done

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
