# JasperGold FPV entry point for the compositional Euler-Maclaurin demo.
#
#   env ZETA_KIND=<kind> [ZETA_JOB=<name>] ... jg -batch formal/em_compositional/run.tcl -proj <dir>
#
# One source of this script runs one case. ZETA_KIND selects it:
#   ctrl       controller of euler_maclaurin_top, datapath units black-boxed
#   unit_mul   handshake contract of mpf_mul
#   unit_add   handshake contract of mpf_add
#   unit_npow  handshake contract of npow_s_kernel
#   mag        magnitude checker against the exact reference
#   e2e        full RTL on an input domain, a sign box, or an offline tile
#
# Not run by its author: JasperGold was not available where this was written.
# Commands that may differ between Jasper releases are wrapped so that a
# rejected reporting command cannot hide the proof results in the log.

proc zeta_env {name default} {
    if {[info exists ::env($name)] && $::env($name) ne ""} {
        return $::env($name)
    }
    return $default
}

proc zeta_int_env {name default} {
    set value [zeta_env $name $default]
    if {![regexp {^-?(0|[1-9][0-9]*)$} $value] ||
        $value < -2147483648 || $value > 2147483647} {
        error "$name must be a signed 32-bit decimal integer, got '$value'"
    }
    return $value
}

proc zeta_hex_value {name literal bits} {
    if {![regexp [format {^%d'h([0-9a-fA-F][0-9a-fA-F_]*)$} $bits] $literal -> digits]} {
        error "$name must be a $bits-bit hex literal, got '$literal'"
    }
    set hex [string map {_ ""} $digits]
    if {[expr 0x$hex] >= (1 << $bits)} {
        error "$name must fit in $bits bits, got '$literal'"
    }
    return [expr 0x$hex]
}

set proofgrid_tcl [zeta_env ZETA_PROOFGRID_TCL ""]
if {$proofgrid_tcl ne ""} {
    set proofgrid_tcl [file normalize $proofgrid_tcl]
    if {![file isfile $proofgrid_tcl]} {
        error "ProofGrid setup file does not exist: $proofgrid_tcl"
    }
}
set results_dir [file normalize [zeta_env ZETA_RESULTS_DIR \
    [file join [file dirname [info script]] ../../sim_build/zeta_compositional/results]]]
cd [file normalize [file join [file dirname [info script]] ../..]]

set kind [zeta_env ZETA_KIND ""]
if {$kind ni {ctrl unit_mul unit_add unit_npow mag e2e}} {
    error "ZETA_KIND must be ctrl, unit_mul, unit_add, unit_npow, mag or e2e, got '$kind'"
}
set job [zeta_env ZETA_JOB $kind]
if {![regexp {^[A-Za-z0-9_.-]+$} $job]} {
    error "ZETA_JOB must be a plain file name, got '$job'"
}

set rtl {
    rtl/common/prim/lzc.sv
    rtl/common/prim/skid_buffer.sv
    rtl/arch/generic-sim/mul_tile.sv
    rtl/common/mp/limb_mul.sv
    rtl/common/mp/limb_shift.sv
    rtl/common/mp/limb_addsub.sv
    rtl/common/mp/mpf_mul.sv
    rtl/common/mp/mpf_add.sv
    rtl/common/fx/fx_mul_mod1.sv
    rtl/common/fn/exp_mpf.sv
    rtl/common/fn/cexp_turns.sv
    rtl/common/zeta/npow_s_kernel.sv
    rtl/common/zeta/euler_maclaurin_top.sv
}
set here formal/em_compositional
set defines {}
set extra_sources {}
set elaborate_options {}
set clock_command {clock clk}
set reset_command {reset -expression {!rst_n}}

switch -- $kind {
    ctrl {
        set n_bound [zeta_int_env ZETA_CTRL_N_BOUND 0]
        set m_bound [zeta_int_env ZETA_CTRL_M_BOUND 0]
        if {$n_bound < 0 || $n_bound > 16777215 || $m_bound < 0 || $m_bound > 4095} {
            error "Controller bounds must fit the unsigned N and M input widths"
        }
        lappend defines +define+ZETA_CTRL_N_BOUND=$n_bound +define+ZETA_CTRL_M_BOUND=$m_bound
        lappend extra_sources $here/ctrl/em_ctrl_checker.sv $here/ctrl/em_ctrl_top.sv
        set top em_ctrl_top
        set elaborate_options {-bbox_m {npow_s_kernel mpf_mul mpf_add}}
    }
    unit_mul - unit_add - unit_npow {
        lappend extra_sources $here/units/em_unit_contract.sv
        set top em_${kind}_top
    }
    mag {
        lappend defines "+define+ZETA_EPS_EXP=[zeta_int_env ZETA_EPS_EXP -16]"
        set assume_normalized [zeta_int_env ZETA_MAG_ASSUME_NORMALIZED 1]
        if {$assume_normalized ni {0 1}} {
            error "ZETA_MAG_ASSUME_NORMALIZED must be 0 or 1, got '$assume_normalized'"
        }
        lappend defines +define+ZETA_MAG_ASSUME_NORMALIZED=$assume_normalized
        set rtl {}
        lappend extra_sources formal/euler_maclaurin/mpf_magnitude.sv $here/mag/mag_equiv.sv
        set top mag_equiv
        set reset_command {reset -none}
    }
    e2e {
        foreach rom {entries_released inv_np2 bern} {
            if {![file isfile sim_build/zeta_formal/$rom.mem]} {
                error "Missing $rom.mem. Run python3 formal/euler_maclaurin/gen_tables.py first."
            }
        }
        foreach rom {expln_w64_exp cexp_w64} {
            if {![file isfile rtl/common/fn/tables/$rom.mem]} {
                error "Missing DUT ROM rtl/common/fn/tables/$rom.mem."
            }
        }
        set sign_box [zeta_int_env ZETA_SIGN_BOX 0]
        set symbolic_box [zeta_int_env ZETA_SYMBOLIC_BOX 0]
        set certify_offline [zeta_int_env ZETA_CERTIFY_OFFLINE 0]
        foreach {name value} [list ZETA_SIGN_BOX $sign_box ZETA_SYMBOLIC_BOX $symbolic_box \
                                   ZETA_CERTIFY_OFFLINE $certify_offline] {
            if {$value ni {0 1}} {
                error "$name must be 0 or 1, got '$value'"
            }
        }
        if {$sign_box + $symbolic_box + $certify_offline > 1} {
            error "Select only one of ZETA_SIGN_BOX, ZETA_SYMBOLIC_BOX, and ZETA_CERTIFY_OFFLINE"
        }
        if {$symbolic_box} {
            foreach name {
                ZETA_SIGMA_LO ZETA_SIGMA_HI ZETA_T_LO ZETA_T_HI ZETA_ENTRY_ROWS
                ZETA_EXPECT_RE ZETA_EXPECT_IM ZETA_BOX_EXPECT_RE ZETA_BOX_EXPECT_IM
            } {
                if {[zeta_env $name ""] ne ""} {
                    error "$name cannot be set with ZETA_SYMBOLIC_BOX=1"
                }
            }
            lappend defines +define+ZETA_SYMBOLIC_BOX=1
        }
        if {$certify_offline} {
            foreach name {ZETA_SIGMA_LO ZETA_SIGMA_HI ZETA_T_LO ZETA_T_HI} {
                if {[zeta_env $name ""] eq ""} {
                    error "$name is required with ZETA_CERTIFY_OFFLINE=1"
                }
            }
            foreach name {
                ZETA_ENTRY_ROWS ZETA_EXPECT_RE ZETA_EXPECT_IM ZETA_BOX_EXPECT_RE ZETA_BOX_EXPECT_IM
            } {
                if {[zeta_env $name ""] ne ""} {
                    error "$name cannot be set with ZETA_CERTIFY_OFFLINE=1"
                }
            }
            lappend defines +define+ZETA_CERTIFY_OFFLINE=1
        }
        foreach name {ZETA_CERT_COMPONENT ZETA_CERT_NEGATIVE ZETA_CERT_RTL_LO ZETA_CERT_RTL_HI ZETA_CERT_ERROR} {
            set literal [zeta_env $name ""]
            if {!$certify_offline} {
                if {$literal ne ""} {
                    error "$name needs ZETA_CERTIFY_OFFLINE=1"
                }
                continue
            }
            if {$name in {ZETA_CERT_COMPONENT ZETA_CERT_NEGATIVE}} {
                if {$literal ni {0 1}} {
                    error "$name must be 0 or 1 with ZETA_CERTIFY_OFFLINE=1"
                }
            } else {
                set word [zeta_hex_value $name $literal 87]
                if {$word >= (1 << 84) || ($word & (1 << 63)) == 0} {
                    error "$name must encode a positive finite normalized Z64 word"
                }
            }
            lappend defines "+define+$name=$literal"
        }
        set eps_exp [zeta_int_env ZETA_EPS_EXP -16]
        lappend defines "+define+ZETA_EPS_EXP=$eps_exp"
        lappend defines "+define+ZETA_EPS_FROM_RE_ONEHALF_EXP=[zeta_int_env ZETA_EPS_FROM_RE_ONEHALF_EXP $eps_exp]"
        set entry_rows [zeta_env ZETA_ENTRY_ROWS ""]
        if {$entry_rows ne ""} {
            set entry_rows [zeta_int_env ZETA_ENTRY_ROWS 0]
            if {$entry_rows < 1 || $entry_rows > 9119} {
                error "ZETA_ENTRY_ROWS must be between 1 and 9119"
            }
            if {![file isfile sim_build/zeta_compositional/rom/entries_$entry_rows.mem]} {
                error "Missing ROM slice entries_$entry_rows.mem. Run gen_jobs.py first."
            }
            lappend defines +define+ZETA_ENTRY_ROWS=$entry_rows
        }
        if {!$symbolic_box} {
            set bounds {}
            foreach {name default} {
                ZETA_SIGMA_LO 32'h00000001 ZETA_SIGMA_HI 32'h0000ffff
                ZETA_T_LO 32'h00000000 ZETA_T_HI 32'h7fffffff
            } {
                set literal [zeta_env $name $default]
                lappend bounds [zeta_hex_value $name $literal 32]
                lappend defines "+define+$name=$literal"
            }
            lassign $bounds sigma_lo sigma_hi t_lo t_hi
            if {$sigma_lo < 1 || $sigma_lo > $sigma_hi || $sigma_hi > 65535 ||
                $t_lo > $t_hi || $t_hi > 2147483647} {
                error "The input box must lie in the legal Q16.16 domain with ordered bounds"
            }
        }
        if {$sign_box} {
            if {$sigma_lo >= $sigma_hi || $t_lo >= $t_hi || ($sigma_lo + $sigma_hi) % 2} {
                error "ZETA_SIGN_BOX needs ZETA_SIGMA_LO < ZETA_SIGMA_HI with an even sum and ZETA_T_LO < ZETA_T_HI"
            }
            if {[zeta_env ZETA_EXPECT_RE ""] ne "" || [zeta_env ZETA_EXPECT_IM ""] ne ""} {
                error "Use ZETA_BOX_EXPECT_RE/IM, not ZETA_EXPECT_RE/IM, with ZETA_SIGN_BOX"
            }
            lappend defines +define+ZETA_SIGN_BOX=1
            if {([zeta_env ZETA_BOX_EXPECT_RE ""] eq "") != ([zeta_env ZETA_BOX_EXPECT_IM ""] eq "")} {
                error "Set both ZETA_BOX_EXPECT_RE and ZETA_BOX_EXPECT_IM, or neither"
            }
            foreach name {ZETA_BOX_EXPECT_RE ZETA_BOX_EXPECT_IM} {
                set literal [zeta_env $name ""]
                if {$literal eq ""} continue
                zeta_hex_value $name $literal 522
                lappend defines "+define+$name=$literal"
            }
        } elseif {[zeta_env ZETA_BOX_EXPECT_RE ""] ne "" || [zeta_env ZETA_BOX_EXPECT_IM ""] ne ""} {
            error "ZETA_BOX_EXPECT_RE/IM need ZETA_SIGN_BOX=1"
        }
        if {([zeta_env ZETA_EXPECT_RE ""] eq "") != ([zeta_env ZETA_EXPECT_IM ""] eq "")} {
            error "Set both ZETA_EXPECT_RE and ZETA_EXPECT_IM, or neither"
        }
        foreach name {ZETA_EXPECT_RE ZETA_EXPECT_IM} {
            set literal [zeta_env $name ""]
            if {$literal eq ""} continue
            zeta_hex_value $name $literal 87
            lappend defines "+define+$name=$literal"
        }
        lappend extra_sources formal/euler_maclaurin/mpf_magnitude.sv $here/e2e/zeta_em_e2e.sv
        set top zeta_em_e2e
        if {[zeta_int_env ZETA_RESET_ZERO 0]} {
            set reset_command {reset -expression {!rst_n} -non_resettable_regs 0}
        }
    }
}

set max_trace_length [zeta_env ZETA_MAX_TRACE_LENGTH ""]
set engine_mode [zeta_env ZETA_ENGINE_MODE ""]
set prove_time_limit [zeta_env ZETA_PROVE_TIME_LIMIT ""]

# Fail before the proof, not after it, if the results cannot be stored.
file mkdir $results_dir
close [open [file join $results_dir $job.tsv.[pid].tmp] w]
file delete [file join $results_dir $job.tsv.[pid].tmp]

puts "zeta job $job (kind $kind): $defines"
clear -all
analyze -sv12 {*}$defines {*}$rtl {*}$extra_sources
elaborate -top $top -disable_auto_bbox {*}$elaborate_options {*}[zeta_env ZETA_ELABORATE_OPTIONS ""]
{*}$clock_command
{*}$reset_command

if {$proofgrid_tcl ne ""} {
    puts "Loading ProofGrid setup [file tail $proofgrid_tcl]"
    uplevel #0 [list source $proofgrid_tcl]
}
# In simulation out_valid follows the accepted request after 6598 + 55*N
# cycles: 8,908 at N = 42 (zero 1) and 10,888 at N = 78 (zero 50).
# Formal trace length also depends on reset and sampling in Jasper.
if {$max_trace_length ne ""} {
    set_max_trace_length $max_trace_length
}
if {$engine_mode ne ""} {
    set_engine_mode $engine_mode
}
set prove_options {}
if {$prove_time_limit ni {"" none}} {
    set prove_options [list -time_limit $prove_time_limit]
}
prove -all {*}$prove_options

# ---- results -----------------------------------------------------------------
# One line per property: job, property, type, status, trace length, time.
proc zeta_property_field {property field} {
    if {[catch {get_property_info -property $property -list $field} value] &&
        [catch {get_property_info $property -list $field} value]} {
        return "?"
    }
    # The answer need not be a well-formed Tcl list.
    if {![catch {llength $value} length] && $length == 2 && [lindex $value 0] eq $field} {
        set value [lindex $value 1]
    }
    return [string map [list "\t" " " "\n" " "] $value]
}

if {[catch {
    set properties [get_property_list]
    set tsv [file join $results_dir $job.tsv]
    set temp_tsv $tsv.[pid].tmp
    set out [open $temp_tsv w]
    foreach property $properties {
        puts $out [join [list $job $property \
            [zeta_property_field $property type] \
            [zeta_property_field $property status] \
            [zeta_property_field $property min_length] \
            [zeta_property_field $property time]] "\t"]
    }
    close $out
    file rename -force $temp_tsv $tsv
} message]} {
    puts "zeta: could not write [file join $results_dir $job.tsv]: $message"
}
if {[catch {report} message]} {
    puts "zeta: report failed: $message"
}
if {[catch {report -csv -include_type -file [file join $results_dir $job.csv] -force} message]} {
    puts "zeta: report -csv failed: $message"
}
