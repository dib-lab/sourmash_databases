import os, sys
import pandas as pd
import glob

configfile: "defaults.yml"
configfile: "index_config.yml"

out_dir = config["output_dir"]
logs_dir = os.path.join(out_dir, "logs")
benchmarks_dir = os.path.join(out_dir, "benchmarks")
data_dir = config['data_dir'].rstrip('/')
basename = config["basename"]

def sanitize_path(path):
    # expand `~`, get absolute path
    path = os.path.expanduser(path)
    path = os.path.abspath(path)
    return path

## this file must have at least two columns: accession,filename
def read_samples(samples_file, data_dir):
    samples = pd.read_csv(samples_file, dtype=str, sep=",", header=0)
    if "signame" not in samples.columns:
        if "species" in samples.columns:
            samples['signame'] = samples["accession"] + " " + samples["species"]
        else:
            samples['signame'] = samples["accession"]
    samples.set_index("accession", inplace=True)
    
    # Now, verify that all genome files exist
    data_dir = sanitize_path(data_dir)
    sample_list = samples["filename"].tolist()
    for filename in sample_list:
        fullpath = os.path.join(data_dir, filename)
        if not os.path.exists(fullpath):
            print(f'** ERROR: genome file {filename} does not exist in {data_dir}')
    return samples

genome_info = read_samples(config["genomes_csv"], data_dir)
sample_names = genome_info.index.tolist()
if config.get("proteins_csv"):
    protein_info = read_samples(config["proteins_csv"], data_dir)
elif any(alpha in ["protein", "dayhoff", "hp"] for alpha in alphabet_info):
    print("Error: protein alphabets found in the desired sbt alphabets. Please provide a csv with protein input.")
    sys.exit(-1)

onstart:
    print("------------------------------")
    print("    Build SBTs from csv")
    print("------------------------------")

onsuccess:
    print("\n--- Workflow executed successfully! ---\n")

onerror:
    print("Alas!\n")

alphabet_info = config["alphabet_info"]
sbt_info= []

wildcard_constraints:
    alphabet="\w+",
    ksize="\d+"

for alphabet, info in alphabet_info.items():
    aks = expand("{alpha}-k{ksize}-scaled{scaled}", alpha=alphabet, ksize=info["ksizes"], scaled=info["scaled"])
    sbt_info.extend(aks)


rule all:
    input: 
        expand(os.path.join(out_dir, "dna-input", "{basename}.signatures.txt"), basename=basename),
        expand(os.path.join(out_dir, "protein-input", "{basename}.signatures.txt"), basename=basename),
        expand(os.path.join(out_dir, "index", "{basename}.{sbtinfo}.sbt.zip"), basename=basename, sbtinfo=sbt_info),


## sketching rules ##
def build_sketch_params(output_type):
    sketch_cmd = ""
    if output_type == "nucleotide":
        ksizes = config["alphabet_info"]["nucleotide"].get("ksizes", config["alphabet_defaults"]["nucleotide"]["ksizes"])
        scaled = config["alphabet_info"]["nucleotide"].get("scaled", config["alphabet_defaults"]["nucleotide"]["scaled"])
        # maybe don't track abundance?
        sketch_cmd = "k=" + ",k=".join(map(str, ksizes)) + f",scaled={str(scaled)}" + ",abund"
        return sketch_cmd
    elif output_type == "protein":
        for alpha in ["protein", "dayhoff", "hp"]:
            if alpha in config["alphabet_info"].keys():
                ## if ksizes aren't given, sketch protein, dayhoff, hp at the ksizes from default config
                ksizes = config["alphabet_info"][alpha].get("ksizes", config["alphabet_defaults"][alpha]["ksizes"])
                scaled = config["alphabet_info"][alpha].get("scaled", config["alphabet_defaults"][alpha]["scaled"])
            else:
                ksizes = config["alphabet_defaults"][alpha]["ksizes"]
                scaled = config["alphabet_defaults"][alpha]["scaled"]
            sketch_cmd += " -p " + alpha + ",k=" + ",k=".join(map(str, ksizes)) + f",scaled={str(scaled)}" + ",abund"
    return sketch_cmd

rule sourmash_sketch_nucleotide_input:
    input: 
        lambda w: os.path.join(data_dir, genome_info.at[w.sample, 'filename'])
    output:
        os.path.join(out_dir, "dna-input", "signatures", "{sample}.sig"),
    params:
        sketch_params = build_sketch_params("nucleotide"),
        signame = lambda w: genome_info.at[w.sample, 'signame'],
    threads: 1
    resources:
        mem_mb=lambda wildcards, attempt: attempt *1000,
        runtime=1200,
    group: "sigs"
    log: os.path.join(logs_dir, "sourmash_sketch_nucl_input", "{sample}.sketch.log")
    benchmark: os.path.join(benchmarks_dir, "sourmash_sketch_nucl_input", "{sample}.sketch.benchmark")
    conda: "envs/sourmash-dev.yml"
    shell:
        """
        sourmash sketch dna -p {params.sketch_params} -o {output} --name {params.signame:q} {input}  2> {log}
        """
    
rule sourmash_sketch_protein_input:
    input: lambda w: os.path.join(data_dir, protein_info.at[w.sample, 'filename'])
    output:
        os.path.join(out_dir, "protein-input", "signatures", "{sample}.sig"),
    params:
        sketch_params = build_sketch_params("protein"),
        signame = lambda w: protein_info.at[w.sample, 'signame'],
    threads: 1
    resources:
        mem_mb=lambda wildcards, attempt: attempt *1000,
        runtime=1200,
    group: "sigs"
    log: os.path. join(logs_dir, "sourmash_sketch_prot_input", "{sample}.sketch.log")
    benchmark: os.path.join(benchmarks_dir, "sourmash_sketch_prot_input", "{sample}.sketch.benchmark")
    conda: "envs/sourmash-dev.yml"
    shell:
        """
        sourmash sketch protein {params.sketch_params} -o {output} --name {params.signame:q} {input} 2> {log}
        """

localrules: signames_to_file

rule signames_to_file:
    input:  expand(os.path.join(out_dir, "{{input_type}}", "signatures", "{sample}.sig"), sample=sample_names),
    output: os.path.join(out_dir, "{input_type}", "{basename}.signatures.txt")
    group: "sigs"
    run:
        with open(str(output), "w") as outF:
            for inF in input:
                outF.write(str(inF) + "\n")


def get_siglist(w):
    if w.alphabet in ["protein", "dayhoff", "hp"]:
        return os.path.join(out_dir, "protein-input", "{basename}.signatures.txt")
    else:
        return os.path.join(out_dir, "dna-input", "{basename}.signatures.txt")


rule index_sbt:
    input: get_siglist 
    output: os.path.join(out_dir, "index", "{basename}.{alphabet}-k{ksize}-scaled{scaled}.sbt.zip"),
    threads: 1
    params:
        alpha_cmd = lambda w: alphabet_defaults[w.alphabet]["alpha_cmd"],
        ksize = lambda w: int(w.ksize)*int(alphabet_defaults[w.alphabet]["ksize_multiplier"]),
    resources:
        mem_mb=lambda wildcards, attempt: attempt *50000,
        runtime=6000,
    log: os.path.join(logs_dir, "index", "{basename}.{alphabet}-k{ksize}-scaled{scaled}.index-sbt.log")
    benchmark: os.path.join(benchmarks_dir, "index", "{basename}.{alphabet}-k{ksize}-scaled{scaled}.index-sbt.benchmark")
    conda: "envs/sourmash-dev.yml"
    shell:
        """
        sourmash index {output} --ksize {params.ksize} \
        --scaled {wildcards.scaled} {params.alpha_cmd}  \
        --from-file {input}  2> {log}
        """