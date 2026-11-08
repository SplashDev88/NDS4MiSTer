package require ::quartus::project
package require ::quartus::sta
project_open NDS4MiSTer
create_timing_netlist
read_sdc
set regs [get_registers {*|fpga3d|*}]
puts "FPGA3D_REGISTERS [get_collection_size $regs]"
set corner 0
foreach_in_collection oc [get_available_operating_conditions] {
    incr corner
    set_operating_conditions $oc
    update_timing_netlist
    report_timing -setup -from $regs -npaths 20 -nworst 1 -detail full_path -file ../../build-fpga3d/quartus/accelerator-from-$corner.txt
    report_timing -setup -to $regs -npaths 20 -nworst 1 -detail full_path -file ../../build-fpga3d/quartus/accelerator-to-$corner.txt
    report_timing -hold -from $regs -npaths 5 -nworst 1 -detail full_path -file ../../build-fpga3d/quartus/accelerator-hold-$corner.txt
}
delete_timing_netlist
project_close
