; link-a.asm - one endpoint for the serial link demonstration.

    ORG $0000

    ORG $0100
    NOP
    JP init

    ORG $0134
    DB "LINK A"
    ORG $0147
    DB $00
    ORG $0148
    DB $00
    ORG $0149
    DB $00
    ORG $0150

init:
    LD A,$41
    LDH ($01),A
    LD A,$81
    LDH ($02),A

wait_transfer:
    LDH A,($02)
    AND $80
    JR NZ,wait_transfer

    LDH A,($01)
    LD ($C001),A
    LD HL,message

print:
    LD A,(HL+)
    OR A
    JR Z,done
    LDH ($01),A
    LD A,$81
    LDH ($02),A
wait_print:
    LDH A,($02)
    AND $80
    JR NZ,wait_print
    JR print

done:
    JR done

message:
    DB "PASS",$00
