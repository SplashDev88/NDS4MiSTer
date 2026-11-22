ENTRY(mix_previous)
mix_continue = 0x0207a6dc;
copy_direction = 0x02046160;
geometry_mult3 = 0x0203df90;
mix_position = 0x0207a714;
next_joint = 0x0207a898;
weighted_position = 0x0207a724;
position_done = 0x0207a870;
submit_direction = 0x0207aa14;
SECTIONS {
 .mix 0x0207a53c : { *(.text.mix) }
 .request 0x0207a6f4 : { *(.text.request) }
 .weight 0x0207a714 : { *(.text.weight) }
 .finish 0x0207a888 : { *(.text.finish) }
 .final 0x0207a8a8 : { *(.text.final) }
 ASSERT(SIZEOF(.weight) <= 0x15c, "position and pair code exceeds original position loop")
 ASSERT(SIZEOF(.final) <= 0x16c, "blend code exceeds original direction loop")
 ASSERT(SIZEOF(.mix) <= 0x1a0, "joint code exceeds the replaced blend block")
}
