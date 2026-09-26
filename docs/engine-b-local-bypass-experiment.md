# EBO5: optional B with redundant local A drawing disabled

Private experiment on EBO3. The ARM helper already draws complete matched frames, both with B On and A-only Off. This image stops unused local FPGA A drawing and extended-palette refills in that configuration. Register readback, palette/OAM initialization, LCD phases, DMA, CPU execution and the ARM event stream remain active. Scanout ownership and ACK handling remain the tested EBO3 implementation. The exact b2d94849 helper is unchanged.

NSM1 tested this gating alone and saved about 4,500 ALMs, but did not fix the NSMB regression. EBO5 combines it with the measured cache-invalidation fix and the working optional-B policy. It does not include the unqualified NSM4 DMA-overlap experiment. Hardware speed and compatibility must be checked before packaging; resource savings alone are not a gameplay gain.
