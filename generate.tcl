# Run with quartus_sh -t generate.tcl

# Load Quartus II Tcl Project package
package require ::quartus::project

# Required for compilation
package require ::quartus::flow

if { $argc != 1 } {
  puts "Exactly 1 argument required"
  exit
}

# One column per synthesis knob, one row per bitstream variant. A new knob is
# added once here instead of once per variant block, and a new variant is one
# row instead of a copied block. A knob lists one parameter/entity pair per
# entity it configures, so a single cell cannot leave the entities
# half-enabled. Every knob is set on every run because set_parameter values
# persist in the .qsf, where a stale manual experiment would otherwise leak
# into the next build.
set param_defs {
  {{PAL_PLL     core_top}}
  {{SAVE_STATES core_top} {USE_SS MAIN_SNES}}
  {{USE_CX4     MAIN_SNES}}
  {{USE_SDD1    MAIN_SNES}}
  {{USE_GSU     MAIN_SNES}}
  {{USE_SA1     MAIN_SNES}}
  {{USE_DSPn    MAIN_SNES}}
  {{USE_SPC7110 MAIN_SNES}}
  {{USE_BSX     MAIN_SNES}}
  {{USE_MSU     MAIN_SNES}}
  {{USE_SUFAMI  MAIN_SNES}}
}

#                                 PLL SS  CX4 SDD1 GSU SA1 DSPn 7110 BSX MSU SUF
set variants(ntsc)               {0   1   0   0    1   0   1    0    0   0   0}
set variants(ntsc_sa1cx4)        {0   1   1   0    0   1   0    0    0   0   0}
set variants(pal)                {1   1   0   0    1   0   1    0    0   0   0}
set variants(pal_sa1cx4)         {1   1   1   0    0   1   0    0    0   0   0}
set variants(ntsc_spc)           {0   0   0   1    0   0   0    1    1   0   0}
set variants(none)               {0   0   0   0    0   0   0    0    0   0   0}
set variants(none_pal)           {1   0   0   0    0   0   0    0    0   0   0}

set labels(ntsc)        "NTSC"
set labels(ntsc_sa1cx4) "NTSC SA1 CX4"
set labels(pal)         "PAL"
set labels(pal_sa1cx4)  "PAL SA1 CX4"
set labels(ntsc_spc)    "NTSC SPC"
set labels(none)        "NONE"
set labels(none_pal)    "NONE PAL"

project_open projects/snes_pocket.qpf

set name [lindex $argv 0]
if { ![info exists variants($name)] } {
  puts "Unknown bitstream type $name"
  project_close
  exit 1
}

puts $labels($name)
foreach def $param_defs val $variants($name) {
  foreach pair $def {
    set_parameter -name [lindex $pair 0] -entity [lindex $pair 1] '$val
  }
}

execute_flow -compile

project_close