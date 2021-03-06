#!/usr/bin/env Rscript



####################
# Import libraries #
####################

suppressPackageStartupMessages({
library(optparse)
library(data.table)
library(tidyverse)
library(jsonlite)
    })

options(warn=-1)

##########################################################
# Parse arguments                                        
##########################################################

option_list = list(
  make_option(c("--input_cb_data"), action="store", default='data/cohort_data_phenos_v4.csv', type='character',
              help="String containing input Cohort Browser data."),
  make_option(c("--input_meta_data"), action="store", default='assets/Metadata phenotypes - Mapping file.csv', type='character',
              help="String containing input metadata for columns in Cohort Browser output."),
  make_option(c("--phenoCol"), action="store", default='None', type='character',
              help="String representing phenotype that will be used for GWAS comparison(s)."),
  make_option(c("--continuous_var_transformation"), action="store", default='log10', type='character',
              help="String representing the type of transformation desired for input data"),
  make_option(c("--continuous_var_aggregation"), action="store", default='mean', type='character',
              help="String representing the type of aggregation desired for input data"),
  make_option(c("--outdir"), action="store", default='.', type='character',
              help="String containing the output directory"),
  make_option(c("--outprefix"), action="store", default='CB', type='character',
              help="String containing the prefix to be used in the output files")
 
)

args = parse_args(OptionParser(option_list=option_list))

input_cb_data                 = args$input_cb_data
input_meta_data               = args$input_meta_data
phenoCol                      = args$phenoCol
transformation                = args$continuous_var_transformation
aggregation                   = args$continuous_var_aggregation
outprefix                     = paste0(args$outprefix, "_")
outdir                        = sub("/$","",args$outdir)

system(paste0("mkdir -p ", outdir), intern=T)

out_path = paste0(outdir, "/", outprefix)



if (!(aggregation %in% c('mean', 'max', 'min', 'median'))){
    stop('Selected aggregation for continuous variables not supported.')
}

##########################################################
# Import cohort browser (cb) data and contrast phenotype 
##########################################################

cb_data = fread(input_cb_data) %>% as.tibble

# Remove columns full of NAs (empty string in CSV)
cb_data = cb_data %>% select_if(~!all(is.na(.)))

##################################################
# Keep only participants for which we have a VCF #
##################################################

cb_data = cb_data %>% filter(!`Platekey in aggregate VCF-0.0`== "")

################################
# Re-encode cb_data phenotypes #
################################

# Trim suffix that denotes multiple entries of columns and replace spaces by "-"
#colnames(cb_data) = colnames(cb_data) %>% str_replace("-[^-]+$", "")
colnames(cb_data) = colnames(cb_data) %>% 
        str_replace_all(" ", "_") %>% 
        str_replace_all("\\(","") %>%
        str_replace_all("\\)","") %>%
        str_to_lower()

# Use phenotype metadata (data dictionary) to determine the type of each phenotype -> This will be given by CB
pheno_dictionary = fread(input_meta_data) %>%
        as.tibble # Change by metadata input var
pheno_dictionary$'Field Name' = str_replace_all(pheno_dictionary$'Field Name'," ", "_") %>%
        str_replace_all("\\(","") %>%
        str_replace_all("\\)","") %>% 
        str_to_lower()

#Compress multiple measures into a single measurement


encode_pheno_values = function(column, data, pheno_dictionary, transformation, aggregation){
    
    #Clean column name
    pheno_cols = data[, str_detect(colnames(data), column)]

    pheno_dtype = filter(pheno_dictionary, str_detect(pheno_dictionary$`Field Name`, column)) %>% 
            pull(`FieldID Type`)
    ################################
    # Individual ID                #
    ################################
    if (column == "individual_id"){

        pheno_cols = data[[column]]
        return(as.vector(pheno_cols))
    }
    ################################
    # Categorical               #
    ################################
    if (str_detect(pheno_dtype, "Categorical") == TRUE){
        if (str_detect(column, 'platekey')){
            pheno_cols = pheno_cols[[1]] %>% as.vector
            return(pheno_cols)
        }
        if (str_detect(column, 'icd|hpo')){
            pheno_cols = pheno_cols[[1]] %>% as.vector
            return(pheno_cols)
        }
        # Fill the gaps and get list of unique values
        pheno_cols[pheno_cols == ''] = "UNKNOWN"
        pheno_values = pheno_cols %>% unlist() %>% sort() %>% unique()
        # Decide aggregation behaviour for samples with paired measures
        if (dim(pheno_cols)[2] > 1) {
            # Arbitrary : get the first column
            # Adds variable called query match that is specific for the column 
            pheno_cols = apply(pheno_cols, 1, function(x) x[1])
        }
        # Encode unique values and create mapping list
        encoding = as.list(1:length(pheno_values))
        names(encoding) = pheno_values
        # Store .json with encoding mappings, will be used later on.
        #csv
        encoding_csv = data.frame(code = 1:length(pheno_values),
                                  original = pheno_values)
        write.csv(encoding_csv, file.path(column, ".csv", fsep = ""), quote=TRUE, row.names=FALSE)
        #json
        encoding_json = toJSON(encoding,keep_vec_names=TRUE)
        write(encoding_json, file = file.path(column, ".json", fsep = ""))
        #Use mapping list on aggregated columns to get
        encoded_col = lapply(pheno_cols, function(x) encoding[x]) %>% unlist() %>% as.vector
        return(encoded_col)
    }
    ################################
    # Year of Birth                #
    ################################   
    if ((str_detect(column,"birth") == TRUE)){
        # Transform year of birth into age
        current_year = format(Sys.time(), "%Y") %>% as.integer
        age = current_year - data[[column]] %>% as.vector
        return(age)
    }
    ################################
    # Integers and Continuous      #
    ################################ 
    if (str_detect(pheno_dtype, 'Integer|Continuous')){
        
        # pick transformation function - tried a case_when but it seems... 
        # ...I cannot make it give back functions
        if (aggregation == 'mean'){
            aggregation_fun = function(x) mean(x, na.rm=TRUE)
        }
        if (aggregation == 'median') {
            aggregation_fun = function(x) median(x, na.rm=TRUE)
        }
        if (aggregation == 'max') {
            aggregation_fun = function(x) max(x, na.rm=TRUE)
        }
        if (aggregation == 'min'){
            aggregation_fun = function(x) min(x, na.rm=TRUE)
        }

        #Apply aggregation & transformation
        ## Get unique sets of measurements
        if (dim(pheno_cols)[2] > 1){
            #Finds group of instances
            sets_measures = str_extract(colnames(pheno_cols), "-[:digit:]") %>% unique()
            ## Group by the same group of arrays
            ##Merge arrays per instances
            pheno_cols = sapply(sets_measures, function(value) apply(pheno_cols[, str_detect(colnames(pheno_cols), value)], 1, function(x) aggregation_fun(x)))
            #Group by instances
            pheno_cols = apply(pheno_cols, 1, function(x) aggregation_fun(x))
        }
        if (is.vector(pheno_cols) && length(dim(pheno_cols)) == 1) {
            pheno_cols = lapply(pheno_cols, function(x) aggregation_fun(x))
        }
        pheno_cols = pheno_cols %>% as.vector

        if (transformation == 'log'){
            pheno_cols = log(pheno_cols)
        }
        if (transformation == 'log10'){
            pheno_cols = log(pheno_cols, 10)
        }
        if (transformation == 'log2') {
            pheno_cols = log2(pheno_cols)
        } 
        if (transformation == 'zscore') {
            pheno_cols = (pheno_cols - mean(pheno_cols, na.rm=TRUE)) / sd(pheno_cols, na.rm=TRUE)
        }
        if (transformation == 'None'){
            pheno_cols = pheno_cols
        }

        return(pheno_cols)

    }
    ################################
    # Dates                        #
    ################################ 
    if (str_detect(pheno_dtype, 'Time|Date')){
        # Transform - turns it into a big integer
        # Fill empty gaps with current date
        pheno_cols[pheno_cols == ''] = format(Sys.time(), "%d/%m/%Y")
        ## Multiple array support
        if (dim(pheno_cols)[2] > 1) {
            # Turns the dates into a big integer
            pheno_cols = apply(pheno_cols, 1, function(x) format(as.Date(x, "%d/%m/%Y"), "%Y%m%d") %>% as.integer)
            # Aggregate - gets the first column - arbitrary
            pheno_cols = apply(pheno_cols, 1, function(x) x[1])
        }
        if (is.vector(pheno_cols) && length(dim(pheno_cols)) == 1) {
            # If only one array, applies directly the transformation
            pheno_cols = lapply(pheno_cols, function(x) format(as.Date(x, "%d/%m/%Y"), "%Y%m%d") %>% as.integer) %>% as.vector
        }
        return(pheno_cols[[1]])
    }
    ################################
    # Free text              #
    ################################ 
    if (str_detect(pheno_dtype, 'Text')){
        ## Sets text to NA
        return(rep(NA, dim(pheno_cols)[1]))
    }

}

# Run across all columns
# encode_pheno_values('specimen_type', cb_data, pheno_dictionary, transformation)
columns_to_transform = colnames(cb_data) %>%
        str_replace("-[^-]+$", "") %>%
        unique
cb_data_transformed = sapply(columns_to_transform, function(x) encode_pheno_values(x, cb_data, pheno_dictionary, transformation, aggregation), simplify=FALSE) %>% as.data.frame

#####################
# Make final output #
#####################

#TODO: Add more covariates
column_to_PHE = phenoCol %>% str_replace_all("\\(","") %>%
        str_replace_all("\\)","") %>%
        str_replace("-[^-]+$", "") %>% 
        str_replace(' ','_') %>% 
        str_to_lower
cb_data_transformed = as_tibble(cb_data_transformed)

##Build the .phe file format
cb_data_transformed$FID = cb_data_transformed[['platekey_in_aggregate_vcf']]
cb_data_transformed$IID = cb_data_transformed[['platekey_in_aggregate_vcf']]
cb_data_transformed$PAT = 0
cb_data_transformed$MAT = 0
cb_data_transformed$SEX = cb_data_transformed[str_detect(colnames(cb_data_transformed), 'sex')][[1]]
cb_data_transformed[str_detect(colnames(cb_data_transformed), 'sex')] = NULL
# This should be provided either by default from the CB output or as an argument or calculated from the VCF data
colnames(cb_data_transformed) = colnames(cb_data_transformed) %>% str_replace_all("\\.", "-")

cb_data_transformed$PHE = cb_data_transformed[str_detect(colnames(cb_data_transformed), column_to_PHE)][[1]]

cb_data_transformed[['individual_id']] = NULL


##################################################
# Write both files                               #
##################################################
#Create wide code_df
code_df = cb_data_transformed[, str_detect(colnames(cb_data_transformed), 'FID|icd|hpo|doid')]

remove_cols = colnames(cb_data_transformed)[str_detect(colnames(cb_data_transformed), 'icd|hpo|doid')]
old_pheno_col = colnames(cb_data_transformed)[str_detect(colnames(cb_data_transformed), column_to_PHE)]
cb_data_transformed = cb_data_transformed %>% select(FID, IID, MAT, PAT, PHE, SEX, everything(), -`platekey`, -`platekey_in_aggregate_vcf`, -all_of(remove_cols), -all_of(old_pheno_col))
write.table(cb_data_transformed, paste0(out_path,'prep_phe_file.phe'), sep='\t',  quote=FALSE, row.names=FALSE)


# Generate id_icd_count.csv
code_df = code_df %>% pivot_longer(!FID, names_to = "vocabulary", values_to = "code") %>% drop_na() %>% select(-vocabulary)
code_df$count = 3 # Do research about this column in particular
names(code_df)[1]="id"
write.table(code_df, paste0(out_path,'id_code_count.csv'), sep=',',  quote=FALSE, row.names=FALSE)




