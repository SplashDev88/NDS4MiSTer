.syntax unified
.arch armv5te
.arm
.text
.global old_clamp
.type old_clamp,%function
old_clamp:
 push {r4-r6,fp,lr}
 mov r6,r0
 mov ip,r1
 mov r5,r2
 mov r0,#31
 cmp r6,#0
 movmi r4,#0
 bmi 1f
 cmp r6,#255
 movgt r4,r0
 movle r4,r6,asr #3
1: cmp ip,#0
 ble 2f
 cmp ip,#255
 movgt r6,r0
 movle r6,ip,asr #3
 orr r4,r4,r6,lsl #5
2: cmp r5,#0
 ble 3f
 cmp r5,#255
 movgt r5,r0
 movle r5,r5,asr #3
 orr r4,r4,r5,lsl #10
3: mov r0,r4
 pop {r4-r6,fp,pc}
.global new_clamp
.type new_clamp,%function
new_clamp:
 push {r4-r6,fp,lr}
 mov r6,r0
 mov ip,r1
 mov r5,r2
 orr r4,r6,ip
 orr r4,r4,r5
 cmp r4,#255
 adr fp,done
 bhi slow
 mov r4,r6,lsr #3
 and r6,ip,#248
 orr r4,r4,r6,lsl #2
 and r5,r5,#248
 orr r4,r4,r5,lsl #7
 b done
slow:
 cmp r6,#255
 movgt r6,#255
 bic r6,r6,r6,asr #31
 mov r4,r6,lsr #3
 cmp ip,#255
 movgt ip,#255
 bic ip,ip,ip,asr #31
 and ip,ip,#248
 orr r4,r4,ip,lsl #2
 cmp r5,#255
 movgt r5,#255
 bic r5,r5,r5,asr #31
 and r5,r5,#248
 orr r4,r4,r5,lsl #7
 bx fp
done:
 mov r0,r4
 pop {r4-r6,fp,pc}
.section .note.GNU-stack,"",%progbits
