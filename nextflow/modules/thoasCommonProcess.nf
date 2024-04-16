process GenerateThoasConfigFile {
    /*
      Description: Generate Thoas loading config ini file with general and genome information
    */

    debug "${params.debug}"
    label 'mem4GB'
    tag 'thoasConfig'
    publishDir "${params.thoas_data_location}", mode: 'copy', overWrite: true


    input:
    path genome_info

    output:
    path "${params.thoas_config_filename}"

    """
    #Script to prepare thoas load-<ENS_VERSION>.conf file
    ${params.nf_py_script_path}/generate_thoas_conf.py \
     -i $genome_info \
     -o ${params.thoas_config_filename} \
     --release ${params.release} \
     --thoas_code_location ${params.thoas_code_location} \
     --thoas_data_location ${params.thoas_data_location} \
     --base_data_path ${params.base_data_path} \
     --grch37_data_path ${params.grch37_data_path} \
     --classifier_path ${params.classifier_path} \
     --chr_checksums_path ${params.chr_checksums_path} \
     --xref_lod_mapping_file ${params.xref_lod_mapping_file} \
     --core_db_host ${params.core_db_host} \
     --core_db_port ${params.core_db_port} \
     --core_db_user ${params.core_db_user} \
     --metadata_db_host ${params.metadata_db_host} \
     --metadata_db_port ${params.metadata_db_port} \
     --metadata_db_user ${params.metadata_db_user}  \
     --metadata_db_dbname ${params.metadata_db_dbname}  \
     --taxonomy_db_host ${params.metadata_db_host} \
     --taxonomy_db_port ${params.metadata_db_port} \
     --taxonomy_db_user ${params.metadata_db_user}  \
     --taxonomy_db_dbname ${params.taxonomy_db_dbname}  \
     --mongo_db_host ${params.mongo_db_host} \
     --mongo_db_port ${params.mongo_db_port} \
     --mongo_db_dbname ${params.mongo_db_dbname} \
     --mongo_db_user ${params.mongo_db_user} \
     --mongo_db_password ${params.mongo_db_password} \
     --mongo_db_schema ${params.mongo_db_schema}
     """
}


process CreateCollectionAndIndex {
    /*
      Description: Create Collection Per Genomic Feature And Its Indexes; shard the data before load
    */

    debug "${params.debug}"
    label 'mem2GB'
    cpus '2'
    tag 'createIndex'

    publishDir "${params.thoas_data_location}", mode: 'copy', overWrite: true

    input:
    path thoas_config_file

    output:
    val thoas_config_file.name

    """
    pyenv local production-pipeline-env
    export META_CLASSIFIER_PATH=${params.thoas_code_location}/metadata_documents/metadata_classifiers/
    python ${params.thoas_code_location}/src/ensembl/mongodb_scripts/create_indexes.py --config ${params.thoas_data_location}/${thoas_config_file}
    """
}


process ShardCollectionData {
    /*
      Description: Shard the mongoDB collection before loading the data
    */

    debug "${params.debug}"
    label 'mem2GB'
    cpus '2'
    tag 'shard_collections'

    publishDir "${params.thoas_data_location}", mode: 'copy', overWrite: true

    input:
    val thoas_config_file
    val mongo_db_shard_uri
    val mongo_dbname

    output:
    val thoas_config_file

    """
    pyenv local production-pipeline-env
    export META_CLASSIFIER_PATH=${params.thoas_code_location}/metadata_documents/metadata_classifiers/
    python ${params.thoas_code_location}/src/ensembl/mongodb_scripts/shard_collections.py --uri "${mongo_db_shard_uri}" --db_name "${mongo_dbname}"
    """
}





process LoadThoasMetadata {
    /*
      Description: Create Collection Per Genomic Feature And Load genome data into those collection
    */

    debug "${params.debug}"  
    label 'mem2GB'
    cpus '2'
    tag 'thoasmetadataloading'

    publishDir "${params.thoas_data_location}", mode: 'copy', overWrite: true

    input:
    path thoas_config_file
    val thoas_config_file_name // used to make processor wait for shard

    output:
    val thoas_config_file.name

    """
    pyenv local production-pipeline-env
    export META_CLASSIFIER_PATH=${params.thoas_code_location}/metadata_documents/metadata_classifiers/
    python ${params.nf_py_script_path}/thoas_load.py -c ${params.thoas_code_location} -i ${params.thoas_data_location}/${thoas_config_file} --load_base_data
    """
}

process ExtractCoreDbDataCDS {
    /*
      Description: Extract  genomic feature from ensembl core databases 
    */

    debug "${params.debug}"  
    label 'mem16GB'
    cpus '4'
    tag "${genome_info[1]}#${genome_info[2]}#${genome_info[0]}"

    publishDir "${params.thoas_data_location}", mode: 'copy', overWrite: true

    input:
      val genome_info

    script:
      genome_uuid  = genome_info[0]
      species      = genome_info[1]
      assembly     = genome_info[2]
      dataset_uuid = genome_info[3]
      thoas_conf   = genome_info[4]
    
    """
     echo Extract genomic feature for species $species 
     echo $genome_uuid
     pyenv local production-pipeline-env
     export META_CLASSIFIER_PATH=${params.thoas_code_location}/metadata_documents/metadata_classifiers/    
     python ${params.nf_py_script_path}/thoas_load.py \
     -s $species -c ${params.thoas_code_location}/src/ensembl/ -i ${params.thoas_data_location}/$thoas_conf \
     --load_species \
     --extract_genomic_features \
     --extract_genomic_features_type cds 
    """

    output:
      tuple val("${species}"), val(thoas_conf), val(genome_uuid), val(dataset_uuid), path("${species}.extract.cds.log"),
       path("${species}_${assembly}_attrib.csv"), path("${species}_${assembly}.csv"), path("${species}_${assembly}_phase.csv")
}

process ExtractCoreDbDataGeneName {
    /*
      Description: Extract  genomic feature from ensembl core databases 
    */

    debug "${params.debug}"  
    label 'mem16GB'
    cpus '4'
    tag "${genome_info[1]}#${genome_info[2]}#${genome_info[0]}"

    publishDir "${params.thoas_data_location}", mode: 'copy', overWrite: true

    input:
      val genome_info

    script:
      genome_uuid  = genome_info[0]
      species      = genome_info[1]
      assembly     = genome_info[2]
      dataset_uuid = genome_info[3]
      thoas_conf   = genome_info[4]
    
    """
     echo Extract genomic feature for species $species 
     echo $genome_uuid
     pyenv local production-pipeline-env
     export META_CLASSIFIER_PATH=${params.thoas_code_location}/metadata_documents/metadata_classifiers/    
     python ${params.nf_py_script_path}/thoas_load.py \
     -s $species -c ${params.thoas_code_location}/src/ensembl/ -i ${params.thoas_data_location}/$thoas_conf \
     --load_species \
     --extract_genomic_features \
     --extract_genomic_features_type genes
    """

    output:
      tuple val("${species}"), val(thoas_conf), val(genome_uuid), val(dataset_uuid), path("${species}.extract.genes.log"),
       path("${species}_${assembly}_gene_names.json")
}

process ExtractCoreDbDataProteins {
    /*
      Description: Extract  genomic feature from ensembl core databases 
    */

    debug "${params.debug}"  
    label 'mem16GB'
    cpus '4'
    tag  "${genome_info[1]}#${genome_info[2]}#${genome_info[0]}"

    publishDir "${params.thoas_data_location}", mode: 'copy', overWrite: true

    input:
      val genome_info

    script:
      genome_uuid  = genome_info[0]
      species      = genome_info[1]
      assembly     = genome_info[2]
      dataset_uuid = genome_info[3]
      thoas_conf   = genome_info[4]
    
    """
     echo Extract genomic feature for species $species 
     echo $genome_uuid
     pyenv local production-pipeline-env
     export META_CLASSIFIER_PATH=${params.thoas_code_location}/metadata_documents/metadata_classifiers/    
     python ${params.nf_py_script_path}/thoas_load.py \
     -s $species -c ${params.thoas_code_location}/src/ensembl/ -i ${params.thoas_data_location}/$thoas_conf \
     --load_species \
     --extract_genomic_features \
     --extract_genomic_features_type proteins 
    """

    output:
      tuple val("${species}"), val(thoas_conf), val(genome_uuid), val(dataset_uuid), path("${species}.extract.proteins.log"),
      path("${species}_${assembly}_translations.json")
}

process LoadGeneIntoThoas {
    /*
      Description: Load  genomic feature into mongo
    */

    debug "${params.debug}"  
    label 'mem32GB'
    cpus '8'
    tag "${genome_info[0]}#${genome_info[3]}"
    
    publishDir "${params.thoas_data_location}", mode: 'copy', overWrite: true

    input:
      val genome_info

    script:
      species     = genome_info[0]
      thoas_conf  = genome_info[1]
      genome_uuid = genome_info[2]
      dataset_uuid = genome_info[3]
          

    """
    echo $species
    echo Load genes for  $species in  $thoas_conf
    pyenv local production-pipeline-env
    export META_CLASSIFIER_PATH=${params.thoas_code_location}/metadata_documents/metadata_classifiers/   
    cd  ${params.thoas_data_location}/
    python ${params.nf_py_script_path}/thoas_load.py \
    -s $species -c ${params.thoas_code_location}/src/ensembl/ -i ${params.thoas_data_location}/$thoas_conf \
    --load_species \
    --load_genomic_features \
    --load_genomic_features_type genes
    """
    // removed load genome --load_genomic_features_type genome genes regions
    output:
      tuple val("${species}"), val(thoas_conf), val(genome_uuid), val(dataset_uuid)

}

process LoadRegionIntoThoas {
    /*
      Description: Load  genomic feature into mongo
    */

    debug "${params.debug}"  
    label 'mem16GB'
    cpus '8'
    tag "${genome_info[0]}#${genome_info[3]}"
    
    publishDir "${params.thoas_data_location}", mode: 'copy', overWrite: true

    input:
      val genome_info

    script:
      species = genome_info[0]
      thoas_conf = genome_info[1]
      genome_uuid = genome_info[2]
      dataset_uuid = genome_info[3]
          

    """
    echo $species
     echo Load regions for  $species in $thoas_conf
     pyenv local production-pipeline-env
     export META_CLASSIFIER_PATH=${params.thoas_code_location}/metadata_documents/metadata_classifiers/   
     cd  ${params.thoas_data_location}/
     python ${params.nf_py_script_path}/thoas_load.py \
     -s $species -c ${params.thoas_code_location}/src/ensembl/ -i ${params.thoas_data_location}/$thoas_conf \
     --load_species \
     --load_genomic_features \
     --load_genomic_features_type regions
    """
    // removed load genome --load_genomic_features_type genome genes regions
    output:
      tuple val("${species}"), val(thoas_conf), val(genome_uuid), val(dataset_uuid)
}

process Validate {
    /*
      Description: Create MongoDB Index for gene genome and regions 
    */

    debug "${params.debug}"  
    label 'mem8GB'
    cpus '8'
    tag "${genome_info[0]}#${genome_info[2]}"
    
    publishDir "${params.thoas_data_location}", mode: 'copy', overWrite: true

    input:
      val genome_info

    script:
      species = genome_info[0]
      thoas_conf = genome_info[1]
      genome_uuid = genome_info[2]
      dataset_uuid = genome_info[3]


    """
      echo Index in progress 
      pyenv local production-pipeline-env
      export META_CLASSIFIER_PATH=${params.thoas_code_location}/metadata_documents/metadata_classifiers/
      python ${params.nf_py_script_path}/validate_thoas.py --config ${params.thoas_data_location}/$thoas_conf --species $species
    """
    output:
        tuple val("${species}"), val(thoas_conf), val(genome_uuid), val(dataset_uuid), path("${species}_count.txt")
}