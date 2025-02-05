/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    VALIDATE INPUTS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

def summary_params = NfcoreSchema.paramsSummaryMap(workflow, params)

// Validate input parameters
WorkflowRaredisease.initialise(params, log)

// Check input path parameters to see if they exist
def checkPathParamList = [
    params.bwamem2_index,
    params.fasta,
    params.fasta_fai,
    params.gnomad,
    params.input,
    params.multiqc_config,
    params.sentieonbwa_index,
    params.svdb_query_dbs,
    params.vcfanno_resources,
    params.vep_cache
]

for (param in checkPathParamList) { if (param) { file(param, checkIfExists: true) } }

// Check mandatory parameters
if (params.input) { ch_input = file(params.input) } else { exit 1, 'Input samplesheet not specified!' }
ch_ml_model        = params.ml_model      ? file(params.ml_model)      : []
ch_call_interval   = params.call_interval ? file(params.call_interval) : []

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CONFIG FILES
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

ch_multiqc_config        = file("$projectDir/assets/multiqc_config.yml", checkIfExists: true)
ch_multiqc_custom_config = params.multiqc_config ? Channel.fromPath(params.multiqc_config) : Channel.empty()

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT LOCAL MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// SUBWORKFLOW: Consisting of a mix of local and nf-core/modules
//
include { CHECK_INPUT                  } from '../subworkflows/local/check_input'
include { PREPARE_REFERENCES           } from '../subworkflows/local/prepare_references'
include { ANNOTATE_STRUCTURAL_VARIANTS } from '../subworkflows/local/annotate_structural_variants'
include { ALIGN                        } from '../subworkflows/local/align'
include { CALL_SNV                     } from '../subworkflows/local/call_snv'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT NF-CORE MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// MODULE: Installed directly from nf-core/modules
//

include { FASTQC                      } from '../modules/nf-core/modules/fastqc/main'
include { MULTIQC                     } from '../modules/nf-core/modules/multiqc/main'
include { CUSTOM_DUMPSOFTWAREVERSIONS } from '../modules/nf-core/modules/custom/dumpsoftwareversions/main'

//
// SUBWORKFLOW: Consists entirely of nf-core/modules
//

include { CALL_REPEAT_EXPANSIONS       } from '../subworkflows/nf-core/call_repeat_expansions'
include { QC_BAM                       } from '../subworkflows/nf-core/qc_bam'
include { ANNOTATE_VCFANNO             } from '../subworkflows/nf-core/annotate_vcfanno'
include { CALL_STRUCTURAL_VARIANTS     } from '../subworkflows/nf-core/call_structural_variants'
include { PREPARE_MT_ALIGNMENT         } from '../subworkflows/local/prepare_MT_alignment'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

// Info required for completion email and summary
def multiqc_report = []

workflow RAREDISEASE {

    ch_versions = Channel.empty()

    //
    // SUBWORKFLOW: Read in samplesheet, validate and stage input files
    //
    CHECK_INPUT (
        ch_input
    )
    ch_versions = ch_versions.mix(CHECK_INPUT.out.versions)

    // STEP 0: QUALITY CHECK.
    FASTQC (
        CHECK_INPUT.out.reads
    )
    ch_versions = ch_versions.mix(FASTQC.out.versions.first())

    // STEP 0: PREPARE GENOME REFERENCES AND INDICES.
    PREPARE_REFERENCES (
        params.aligner,
        params.bwamem2_index,
        params.fasta,
        params.fasta_fai,
        params.gnomad,
        params.known_dbsnp,
        params.known_dbsnp_tbi,
        params.sentieonbwa_index,
        params.target_bed,
        params.variant_catalog,
        params.vcfanno_resources
    )
    .set { ch_references }
    ch_versions = ch_versions.mix(ch_references.versions)

    // STEP 1: ALIGNING READS, FETCH STATS, AND MERGE.
    ALIGN (
        params.aligner,
        CHECK_INPUT.out.reads,
        ch_references.genome_fasta,
        ch_references.genome_fai,
        ch_references.aligner_index,
        ch_references.known_dbsnp,
        ch_references.known_dbsnp_tbi
    )
    .set { ch_mapped }
    ch_versions   = ch_versions.mix(ALIGN.out.versions)

    // STEP 1.5: BAM QUALITY CHECK
    QC_BAM (
        ch_mapped.marked_bam,
        ch_mapped.marked_bai,
        ch_references.genome_fasta,
        ch_references.genome_fai,
        ch_references.bait_intervals,
        ch_references.target_intervals,
        ch_references.chrom_sizes
    )
    ch_versions = ch_versions.mix(QC_BAM.out.versions.ifEmpty(null))

    // STEP 1.6: EXPANSIONHUNTER AND STRANGER
    CALL_REPEAT_EXPANSIONS (
        ch_mapped.bam_bai,
        ch_references.genome_fasta,
        ch_references.variant_catalog
    )
    ch_versions = ch_versions.mix(CALL_REPEAT_EXPANSIONS.out.versions.ifEmpty(null))

    // STEP 2: VARIANT CALLING
    // TODO: There should be a conditional to execute certain variant callers (e.g. sentieon, gatk, deepvariant) defined by the user and we need to think of a default caller.
    CALL_SNV (
        params.variant_caller,
        ch_mapped.bam_bai,
        ch_references.genome_fasta,
        ch_references.genome_fai,
        ch_references.known_dbsnp,
        ch_references.known_dbsnp_tbi,
        ch_call_interval,
        ch_ml_model,
        CHECK_INPUT.out.case_info
    )
    ch_versions = ch_versions.mix(CALL_SNV.out.versions)

    CALL_STRUCTURAL_VARIANTS (
        ch_mapped.marked_bam,
        ch_mapped.marked_bai,
        ch_references.genome_fasta,
        ch_references.genome_fai,
        CHECK_INPUT.out.case_info,
        ch_references.target_bed,
        params.cnvpytor_binsizes
    )
    ch_versions = ch_versions.mix(CALL_STRUCTURAL_VARIANTS.out.versions)

    ch_sv_annotate = Channel.empty()
    if (params.annotate_sv_switch) {
        ANNOTATE_STRUCTURAL_VARIANTS (
            CALL_STRUCTURAL_VARIANTS.out.vcf,
            params.svdb_query_dbs,
            params.genome,
            params.vep_cache_version,
            params.vep_cache,
            ch_references.genome_fasta,
            ch_references.sequence_dict
        ).set {ch_sv_annotate}

        ch_versions = ch_versions.mix(ch_sv_annotate.versions)
    }

    // STEP 2.1: MT CALLING

    PREPARE_MT_ALIGNMENT (
        ch_mapped.bam_bai
    )
    ch_versions = ch_versions.mix(PREPARE_MT_ALIGNMENT.out.versions)

    // STEP 3: VARIANT ANNOTATION
    ch_dv_vcf = CALL_SNV.out.vcf.join(CALL_SNV.out.tabix, by: [0])

    ANNOTATE_VCFANNO (
        params.vcfanno_toml,
        ch_dv_vcf,
        ch_references.vcfanno_resources
    )
    ch_versions = ch_versions.mix(ANNOTATE_VCFANNO.out.versions)

    //
    // MODULE: Pipeline reporting
    //
    CUSTOM_DUMPSOFTWAREVERSIONS (
        ch_versions.unique().collectFile(name: 'collated_versions.yml')
    )

    //
    // MODULE: MultiQC
    //
    workflow_summary    = WorkflowRaredisease.paramsSummaryMultiqc(workflow, summary_params)
    ch_workflow_summary = Channel.value(workflow_summary)

    ch_multiqc_files = Channel.empty()
    ch_multiqc_files = ch_multiqc_files.mix(Channel.from(ch_multiqc_config))
    ch_multiqc_files = ch_multiqc_files.mix(ch_multiqc_custom_config.collect().ifEmpty([]))
    ch_multiqc_files = ch_multiqc_files.mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(CUSTOM_DUMPSOFTWAREVERSIONS.out.mqc_yml.collect())
    ch_multiqc_files = ch_multiqc_files.mix(FASTQC.out.zip.collect{it[1]}.ifEmpty([]))

    MULTIQC (
        ch_multiqc_files.collect()
    )
    multiqc_report = MULTIQC.out.report.toList()
    ch_versions    = ch_versions.mix(MULTIQC.out.versions)
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    COMPLETION EMAIL AND SUMMARY
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow.onComplete {
    if (params.email || params.email_on_fail) {
        NfcoreTemplate.email(workflow, params, summary_params, projectDir, log, multiqc_report)
    }
    NfcoreTemplate.summary(workflow, params, log)
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
