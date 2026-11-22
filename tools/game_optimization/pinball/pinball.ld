PROVIDE(code_delta = 0);
SECTIONS
{
    .sound (0x02068f98 + code_delta) : { *(.sound) }
    remaining_samples = (0x020690e8 + code_delta);
    .divide (0x0207f3f4 + code_delta) : { *(.divide) }
    apply_sign = (0x0207f4f0 + code_delta);
}
