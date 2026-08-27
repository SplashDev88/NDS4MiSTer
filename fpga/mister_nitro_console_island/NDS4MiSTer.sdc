derive_pll_clocks
derive_clock_uncertainty

# The retained 60 MHz shell/DDR PLL and the separate 1x/2x/3x Nitro PLL have
# no phase relationship.  All paths between them terminate in explicit toggle
# synchronizers or the Gray-pointer pixel FIFO.
set_clock_groups -asynchronous \
    -group [get_clocks { *|pll|pll_inst|altera_pll_i|*[*].*|divclk}] \
    -group [get_clocks { *|island_pll|pll_inst|altera_pll_i|*[*].*|divclk}]
