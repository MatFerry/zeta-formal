# A variable that is set but empty counts as unset, as in run_jasper.sh.
foreach name {ZETA_PROOFGRID_TCL ZETA_CASE ZETA_EPS_EXP ZETA_EPS_FROM_RE_ONEHALF_EXP
              ZETA_REPORT_DIR} {
    if {[info exists ::env($name)] && $::env($name) eq ""} {
        unset ::env($name)
    }
}
set proofgrid_tcl ""
if {[info exists ::env(ZETA_PROOFGRID_TCL)]} {
    set proofgrid_tcl [file normalize $::env(ZETA_PROOFGRID_TCL)]
    if {![file isfile $proofgrid_tcl]} {
        error "ProofGrid setup file does not exist: $proofgrid_tcl"
    }
}
cd [file normalize [file join [file dirname [info script]] ../..]]

set case_names {half neighbor released}
set cases {0 1 2}
if {[info exists ::env(ZETA_CASE)]} {
    set cases [list $::env(ZETA_CASE)]
}
set eps_exp -16
if {[info exists ::env(ZETA_EPS_EXP)]} {
    set eps_exp $::env(ZETA_EPS_EXP)
}
set sigma_eps_exp $eps_exp
if {[info exists ::env(ZETA_EPS_FROM_RE_ONEHALF_EXP)]} {
    set sigma_eps_exp $::env(ZETA_EPS_FROM_RE_ONEHALF_EXP)
}
foreach {name exponent} [list ZETA_EPS_EXP $eps_exp ZETA_EPS_FROM_RE_ONEHALF_EXP $sigma_eps_exp] {
    if {![regexp {^-?(0|[1-9][0-9]*)$} $exponent] ||
        $exponent < -2147483648 || $exponent > 2147483647} {
        error "$name must be a signed 32-bit decimal integer"
    }
}
foreach rom {entries_directed entries_released inv_np2 bern} {
    if {![file isfile sim_build/zeta_formal/$rom.mem]} {
        error "Missing $rom.mem. Run python3 formal/euler_maclaurin/gen_tables.py first."
    }
}
foreach rom {expln_w64_exp cexp_w64} {
    if {![file isfile rtl/common/fn/tables/$rom.mem]} {
        error "Missing DUT ROM rtl/common/fn/tables/$rom.mem."
    }
}

set prove_options {}
if {[info exists ::env(ZETA_PROVE_TIME_LIMIT)] &&
    $::env(ZETA_PROVE_TIME_LIMIT) ni {"" none}} {
    set prove_options [list -time_limit $::env(ZETA_PROVE_TIME_LIMIT)]
}
set sources {
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
    formal/euler_maclaurin/mpf_magnitude.sv
    formal/euler_maclaurin/zeta_em_formal.sv
}

foreach case_id $cases {
    if {$case_id ni {0 1 2}} {
        error "ZETA_CASE must be 0 (half), 1 (neighbor), or 2 (released)"
    }
    set case_name [lindex $case_names $case_id]
    puts "Euler-Maclaurin $case_name, EPS = 2^$eps_exp, eps_from_re_onehalf = 2^$sigma_eps_exp"
    clear -all
    analyze -sv12 +define+ZETA_CASE=$case_id +define+ZETA_EPS_EXP=$eps_exp \
        +define+ZETA_EPS_FROM_RE_ONEHALF_EXP=$sigma_eps_exp {*}$sources
    elaborate -top zeta_em_formal -disable_auto_bbox
    clock clk
    reset -expression {!rst_n}
    if {$proofgrid_tcl ne ""} {
        puts "Loading ProofGrid setup from $proofgrid_tcl"
        source $proofgrid_tcl
    }
    # Jasper FPV runs the cover property along with the assertions.
    prove -all {*}$prove_options
    # A rejected reporting command must not stop the remaining cases.
    if {[catch {report} message]} {
        puts "report failed: $message"
    }
    if {[info exists ::env(ZETA_REPORT_DIR)]} {
        set csv [file join $::env(ZETA_REPORT_DIR) properties-$case_name.csv]
        if {[catch {report -csv -include_type -file $csv -force} message]} {
            puts "report -csv failed for $case_name: $message"
        }
    }
}
