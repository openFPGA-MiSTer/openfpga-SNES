#
# user core constraints
#
# put your clock groups in here as well as any net assignments
#

set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|mp1|mf_pllbase*_inst|altera_pll_i|*[0].*|divclk \
          ic|mp1|mf_pllbase*_inst|altera_pll_i|*[1].*|divclk } \
 -group { ic|mp1|mf_pllbase*_inst|altera_pll_i|*[2].*|divclk } \
 -group { ic|mp1|mf_pllbase*_inst|altera_pll_i|*[3].*|divclk } \
 -group { ic|audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk }

derive_clock_uncertainty

set mem_clk [get_clocks {ic|mp1|mf_pllbase*_inst|altera_pll_i|*[1].*|divclk}]
foreach mem {sdram wram aram} {
  set_multicycle_path -from "ic|snes|$mem|*" -to $mem_clk -start -setup 2
  set_multicycle_path -from "ic|snes|$mem|*" -to $mem_clk -start -hold 1

  set_multicycle_path -from $mem_clk -to "ic|snes|$mem|*" -setup 2
  set_multicycle_path -from $mem_clk -to "ic|snes|$mem|*" -hold 1
}

# The ROM_Q hold registers sit in the same sdram-data-to-console path and
# their consumers sample at the same CE pace, so they get the same
# relaxation as the sdram registers above. Their value can only change
# while the console is frozen or between a completed access and the next
# CE sample point.
set_multicycle_path -from "ic|snes|ss_transport.rom_q_hold[*]" -to $mem_clk -start -setup 2
set_multicycle_path -from "ic|snes|ss_transport.rom_q_hold[*]" -to $mem_clk -start -hold 1
set_multicycle_path -from "ic|snes|ss_transport.hold_rom_q" -to $mem_clk -start -setup 2
set_multicycle_path -from "ic|snes|ss_transport.hold_rom_q" -to $mem_clk -start -hold 1

# save_state_mem crosses clk_sys <-> clk_mem with toggle handshakes
# (cmd_go / cmd_done through synch_3): the payload registers are stable
# for several destination-clock cycles before the toggle is observed, so
# the direct data paths between the domains carry no timing requirement.
set ss_clk_mem_85_9 [get_clocks {ic|mp1|mf_pllbase*_inst|altera_pll_i|*[0].*|divclk}]
set ss_clk_sys_21_48 [get_clocks {ic|mp1|mf_pllbase*_inst|altera_pll_i|*[1].*|divclk}]
set_false_path -from [get_registers {*|save_state_mem:*|cmd_qaddr[*] \
                                     *|save_state_mem:*|cmd_data[*] \
                                     *|save_state_mem:*|cmd_be[*] \
                                     *|save_state_mem:*|cmd_we}] -to $ss_clk_mem_85_9
set_false_path -from [get_registers {*|save_state_mem:*|rsp_data[*]}] -to $ss_clk_sys_21_48
