SECTIONS
{
    .sound 0x02068f98 : { *(.sound) }
    remaining_samples = 0x020690e8;
    .divide 0x0207f3f4 : { *(.divide) }
    apply_sign = 0x0207f4f0;
}
