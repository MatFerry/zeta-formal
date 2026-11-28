# Run each case in this Jasper session. ProofGrid schedules its engines.
# A case that stops with an error is reported and the remaining cases still
# run; the script then ends with an error that names the failed cases.
set suite_script_dir [file normalize [file dirname [info script]]]
set suite_input_dir [file normalize [file join $suite_script_dir ../../sim_build/zeta_compositional]]
set suite_keys {
    ZETA_KIND ZETA_JOB ZETA_CTRL_N_BOUND ZETA_CTRL_M_BOUND ZETA_MAG_ASSUME_NORMALIZED
    ZETA_SIGMA_LO ZETA_SIGMA_HI ZETA_T_LO ZETA_T_HI ZETA_ENTRY_ROWS
    ZETA_EPS_EXP ZETA_EPS_FROM_RE_ONEHALF_EXP ZETA_EXPECT_RE ZETA_EXPECT_IM
    ZETA_SIGN_BOX ZETA_SYMBOLIC_BOX ZETA_BOX_EXPECT_RE ZETA_BOX_EXPECT_IM
}
set suite_manifest [file join $suite_input_dir jobs.tsv]
set suite_expected [file join $suite_input_dir expected.tsv]
if {![file isfile $suite_manifest] || ![file isfile $suite_expected]} {
    error "Run python3 formal/em_compositional/gen_jobs.py before sourcing the suite"
}

set suite_input [open $suite_manifest r]
set suite_jobs {}
while {[gets $suite_input line] >= 0} {
    if {$line eq ""} continue
    set options {}
    foreach field [split $line "\t"] {
        if {![regexp {^([^=]+)=(.+)$} $field -> name value] ||
            $name ni $suite_keys || [dict exists $options $name]} {
            close $suite_input
            error "Invalid suite field '$field'"
        }
        dict set options $name $value
    }
    if {![dict exists $options ZETA_KIND] || ![dict exists $options ZETA_JOB]} {
        close $suite_input
        error "Every suite case needs ZETA_KIND and ZETA_JOB"
    }
    set name [dict get $options ZETA_JOB]
    if {[dict exists $suite_jobs $name]} {
        close $suite_input
        error "Duplicate suite case '$name'"
    }
    dict set suite_jobs $name $options
}
close $suite_input
if {[dict size $suite_jobs] == 0} {
    error "The suite manifest contains no cases"
}

if {[info exists ::env(ZETA_RESULTS_DIR)] && $::env(ZETA_RESULTS_DIR) ne ""} {
    set suite_results [file normalize $::env(ZETA_RESULTS_DIR)]
} else {
    set suite_results [file join $suite_input_dir results-[pid]]
}
if {[file exists $suite_results]} {
    error "The suite requires a fresh results directory: $suite_results"
}
file mkdir $suite_results
file copy $suite_manifest $suite_expected $suite_results
set ::env(ZETA_RESULTS_DIR) $suite_results
puts "Euler-Maclaurin suite results: $suite_results"

proc zeta_suite_run_case {script keys options} {
    set saved {}
    foreach key $keys {
        if {[info exists ::env($key)]} {
            dict set saved $key $::env($key)
            unset ::env($key)
        }
    }
    dict for {key value} $options {
        set ::env($key) $value
    }
    set original_dir [pwd]
    set code [catch {source $script} message result]
    cd $original_dir
    foreach key $keys {
        unset -nocomplain ::env($key)
    }
    dict for {key value} $saved {
        set ::env($key) $value
    }
    if {$code != 0} {
        return -options $result $message
    }
}

set suite_failed {}
dict for {name options} $suite_jobs {
    if {[catch {
        zeta_suite_run_case [file join $suite_script_dir run.tcl] $suite_keys $options
    } suite_message]} {
        puts "zeta suite: case '$name' FAILED: $suite_message"
        lappend suite_failed $name
    }
}
puts "zeta suite: [expr {[dict size $suite_jobs] - [llength $suite_failed]}] of\
    [dict size $suite_jobs] cases ran to completion"
if {[llength $suite_failed]} {
    error "Suite cases failed to run: $suite_failed"
}
