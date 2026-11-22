/* ARM9 joint code and SDK helpers move independently between releases. */
PROVIDE(joint_delta = 0);
PROVIDE(sdk_delta = 0);
ENTRY(mix_previous)
mix_continue = (0x0207a6dc + joint_delta);
copy_direction = (0x02046160 + sdk_delta);
geometry_mult3 = (0x0203df90 + sdk_delta);
mix_position = (0x0207a714 + joint_delta);
next_joint = (0x0207a898 + joint_delta);
weighted_position = (0x0207a724 + joint_delta);
position_done = (0x0207a870 + joint_delta);
submit_direction = (0x0207aa14 + joint_delta);
SECTIONS {
 .mix (0x0207a53c + joint_delta) : { *(.text.mix) }
 .request (0x0207a6f4 + joint_delta) : { *(.text.request) }
 .weight (0x0207a714 + joint_delta) : { *(.text.weight) }
 .finish (0x0207a888 + joint_delta) : { *(.text.finish) }
 .final (0x0207a8a8 + joint_delta) : { *(.text.final) }
 ASSERT(SIZEOF(.weight) <= 0x15c, "position and pair code exceeds original position loop")
 ASSERT(SIZEOF(.final) <= 0x16c, "blend code exceeds original direction loop")
 ASSERT(SIZEOF(.mix) <= 0x1a0, "joint code exceeds the replaced blend block")
}
