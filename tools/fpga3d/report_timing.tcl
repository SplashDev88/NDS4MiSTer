package require ::quartus::project
package require ::quartus::sta
project_open NDS4MiSTer
create_timing_netlist
read_sdc
set regs [get_registers {*|fpga3d|* *|fpga3d_control_mux|*}]
puts "FPGA3D_REGISTERS [get_collection_size $regs]"
set corner 0
foreach_in_collection oc [get_available_operating_conditions] {
    incr corner
    set_operating_conditions $oc
    update_timing_netlist
    report_timing -setup -from $regs -npaths 20 -nworst 1 -detail full_path -file ../../build-fpga3d/quartus/accelerator-from-$corner.txt
    report_timing -setup -to $regs -npaths 20 -nworst 1 -detail full_path -file ../../build-fpga3d/quartus/accelerator-to-$corner.txt
    report_timing -hold -from $regs -npaths 5 -nworst 1 -detail full_path -file ../../build-fpga3d/quartus/accelerator-hold-$corner.txt
    report_timing -setup -npaths 10 -nworst 1 -detail full_path -file ../../build-fpga3d/quartus/global-setup-$corner.txt
    report_timing -hold -npaths 10 -nworst 1 -detail full_path -file ../../build-fpga3d/quartus/global-hold-$corner.txt
    report_timing -recovery -npaths 10 -nworst 1 -detail full_path -file ../../build-fpga3d/quartus/global-recovery-$corner.txt
    report_timing -removal -npaths 10 -nworst 1 -detail full_path -file ../../build-fpga3d/quartus/global-removal-$corner.txt
}
delete_timing_netlist
project_close
