#!/bin/bash

# Modified by Hang Le
# The original copyright is appended below
# --
# Copyright 2019 Kyoto University (Hirofumi Inaguma)
# Apache 2.0  (http://www.apache.org/licenses/LICENSE-2.0)


. ./path.sh || exit 1;
. ./cmd.sh || exit 1;

# general configuration
backend=pytorch     # chainer or pytorch
stage=              # start from -1 if you need to start from data download
stop_stage=
ngpu=               # number of gpus ("0" uses cpu, otherwise use gpu)
nj=                 # number of parallel jobs for decoding
debugmode=4
N=0                 # number of minibatches to be used (mainly for debugging). 
                    # "0" uses all minibatches.
verbose=1           # verbose option
resume=             # Resume the training from snapshot
seed=1              # seed to generate random number
do_delta=false      # feature configuration

# paths to data, features, etc.
dataset=             # path to dataset
dumpdir=dump        # directory to dump full features
datadir=            # directory where multilingual data is saved
expdir=exp          # directory to save experiment folders
tensorboard_dir=tensorboard
train_config_dir=./conf/training   # directory where training configs are saved
decode_config_dir=./conf/tuning  # directory where decode confis are saved

# target language(s)
tgt_langs=en
# you can choose from de, es, fr, it, nl, pt, ro, ru
# To train the multilingual model, segment languages with _ as follows:
# e.g., tgt_lang="de_es_fr"
use_lid=true #if false then not use language id (for bilingual models)

# pre-training related
asr_model=
st_model=
init_from_decoder_asr=
init_from_decoder_mt=

# training related
preprocess_config=
do_st=                       # if false, train ASR model
do_mt=                       # if true then train MT model
use_adapters=                # if true, use adapter for fine-tuning
train_adapters=false              # if true, train adapter from scratch
use_adapters_for_asr=        # if true, then add adapters for transcription
use_adapters_in_enc=         # if true, use adapters in encoder
early_stop_criterion=validation/main/acc

# text-preprocessing
src_case=lc.rm      # lc.rm: lowercase with punctuation removal
wrsrc_case=lc.rm      # lc.rm: lowercase with punctuation removal
tgt_case=tc         # tc: truecase
use_joint_dict=true # if true, use joint dictionaey for source and target,
                    # else use separate dictionaries for source and target.
use_multi_dict=     # if true, use dictionary for all languages

# bpemode (unigram or bpe)
bpemode=bpe
nbpe=             # for target dictionary or joint source and target dictionary
nbpe_src=         # for source dictionary only
nbpe_wrsrc=         # for written source dictionary only

# decoding related
decode_config=    # configuration for decoding
trans_model=      # set a model to be used for decoding e.g. 'model.acc.best'
trans_set=        # data set to decode
max_iter_eval=    # get best model up to this iteration
min_iter_eval=    # get best model from this iteration
remove_non_verbal_eval=true  # if true, then remove non-verbal tokens in evaluation
eval_no_adapters=

# model average related (only for transformer)
n_average=5                  # the number of ST models to be averaged,
                             # 1: disable model averaging and choose best model.
use_valbest_average=true     # if true, use models with best validation.
                             # if false, use last `n_average` models.

# exp tag
tag="" # tag for managing experiments.

. utils/parse_options.sh || exit 1;

# path to training configuration
train_config=${train_config_dir}/${tag}.yaml

# get language pairs
tgt_langs=$(echo "$tgt_langs" | tr '_' '\n' | sort | tr '\n' '_')
tgt_langs=$(echo ${tgt_langs::-1})
lang_pairs=""
lang_count=0
for lang in $(echo ${tgt_langs} | tr '_' ' '); do
	lang_pairs+="ja-${lang},"
	lang_count=$((lang_count + 1))
done
lang_pairs=$(echo ${lang_pairs::-1})

# use language ID if there is more than 1 target language
if (( $lang_count != 1  )); then
	use_lid=true
fi

# prefix for dictionaries
dprefix="dict1"
if [[ ${use_joint_dict} != "true" ]]; then
    dprefix="dict2"
fi

echo "*** General parameters ***"
echo "| ngpu: ${ngpu}"
echo "| experiment name: ${tag}"
echo "| target language(s): ${tgt_langs}"
echo "| number of target languages: ${lang_count}"
echo "| language pairs: ${lang_pairs}"

echo "*** Training-related parameters ***"
echo "| nbpe: ${nbpe}"
echo "| nbpe_src: ${nbpe_src}"
echo "| nbpe_wrsrc: ${nbpe_wrsrc}"
echo "| dictionary prefix: ${dprefix}"
echo "| use language ID: ${use_lid}"
echo "| use adapters: ${use_adapters}"
echo "| use_multi_dict: ${use_multi_dict}"
echo "| train adapters: ${train_adapters}"
echo "| train_config: ${train_config}"
echo "| preprocess_config: ${preprocess_config}"
echo "| pre-trained weights for encoder: ${asr_model}"
echo "| pre-trained weights for decoder: ${st_model}"

echo "*** Decoding-related parameters ***"
echo "| max_iter_eval: ${max_iter_eval}"
echo "| decode_config: ${decode_config}"
echo "| trans_model: ${trans_model}"

# Set bash to 'debug' mode, it will exit on :
# -e 'error', -u 'undefined variable', -o ... 'error in pipeline', -x 'print commands',
set -e
set -u
set -o pipefail

# Train, dev, and trans sets
train_set=train_sp
train_dev=dev

train_set_dict=${train_set}

num_trans_set=1
trans_set="test.en"
echo "| trans sets: ${trans_set}"
echo "| number of trans sets: ${num_trans_set}"

if [[ ${stage} -le 0 ]] && [[ ${stop_stage} -ge 0 ]]; then
    ### Task dependent. You have to make data the following preparation part by yourself.
    ### But you can utilize Kaldi recipes in most cases
    echo "***** stage 0: Data Preparation *****"
    local/data_prep.sh ${dataset}
fi


if [[ ${stage} -le 1 ]] && [[ ${stop_stage} -ge 1 ]]; then
    ### Task dependent. You have to design training and dev sets by yourself.
    ### But you can utilize Kaldi recipes in most cases
    echo "***** stage 1: Feature Generation *****"

	fbankdir="fbank"
        train_set_lg=train_sp.en
        train_dev_lg=dev.en
        feat_tr_dir_lg=${dumpdir}/${train_set_lg}/delta${do_delta}; mkdir -p ${feat_tr_dir_lg}
        feat_dt_dir_lg=${dumpdir}/${train_dev_lg}/delta${do_delta}; mkdir -p ${feat_dt_dir_lg}
        # Generate the fbank features; by default 80-dimensional fbanks with pitch on each frame
        for x in train dev test; do
            steps/make_fbank_pitch.sh --cmd "$train_cmd" --nj 32 --write_utt2num_frames true \
                data/${x} exp/make_fbank/${x} ${fbankdir}
        done

        # speed-perturbed
        utils/perturb_data_dir_speed.sh 0.9 data/train data/temp1.en
        utils/perturb_data_dir_speed.sh 1.0 data/train data/temp2.en
        utils/perturb_data_dir_speed.sh 1.1 data/train data/temp3.en
        utils/combine_data.sh --extra-files utt2uniq data/train_sp \
            data/temp1.en data/temp2.en data/temp3.en
        rm -r data/temp1.en data/temp2.en data/temp3.en

        steps/make_fbank_pitch.sh --cmd "$train_cmd" --nj 32 --write_utt2num_frames true \
            data/train_sp exp/make_fbank/train_sp ${fbankdir}

        for lg in sp en wr; do
            awk -v p="sp0.9-" '{printf("%s %s%s\n", $1, p, $1);}' data/train/utt2spk > data/train_sp/utt_map
            utils/apply_map.pl -f 1 data/train_sp/utt_map <data/train/text.tc.${lg} >data/train_sp/text.tc.${lg}
            utils/apply_map.pl -f 1 data/train_sp/utt_map <data/train/text.lc.${lg} >data/train_sp/text.lc.${lg}
            utils/apply_map.pl -f 1 data/train_sp/utt_map <data/train/text.lc.rm.${lg} >data/train_sp/text.lc.rm.${lg}
            awk -v p="sp1.0-" '{printf("%s %s%s\n", $1, p, $1);}' data/train/utt2spk > data/train_sp/utt_map
            utils/apply_map.pl -f 1 data/train_sp/utt_map <data/train/text.tc.${lg} >>data/train_sp/text.tc.${lg}
            utils/apply_map.pl -f 1 data/train_sp/utt_map <data/train/text.lc.${lg} >>data/train_sp/text.lc.${lg}
            utils/apply_map.pl -f 1 data/train_sp/utt_map <data/train/text.lc.rm.${lg} >>data/train_sp/text.lc.rm.${lg}
            awk -v p="sp1.1-" '{printf("%s %s%s\n", $1, p, $1);}' data/train/utt2spk > data/train_sp/utt_map
            utils/apply_map.pl -f 1 data/train_sp/utt_map <data/train/text.tc.${lg} >>data/train_sp/text.tc.${lg}
            utils/apply_map.pl -f 1 data/train_sp/utt_map <data/train/text.lc.${lg} >>data/train_sp/text.lc.${lg}
            utils/apply_map.pl -f 1 data/train_sp/utt_map <data/train/text.lc.rm.${lg} >>data/train_sp/text.lc.rm.${lg}
        done

        # Divide into source and target languages
        for x in train_sp dev test; do
            local/divide_lang.sh ${x}
        done

        for x in train_sp dev; do
            # remove utt having more than 6000 frames
            # remove utt having more than 400 characters
            for lg in sp en wr; do
                remove_longshortdata.sh --maxframes 6000 --maxchars 400 data/${x}.${lg} data/${x}.${lg}.tmp
            done

            # Match the number of utterances between source and target languages
            # extract common lines
            cut -f 1 -d " " data/${x}.sp.tmp/text > data/${x}.en.tmp/reclist1
            cut -f 1 -d " " data/${x}.en.tmp/text > data/${x}.en.tmp/reclist2
            cut -f 1 -d " " data/${x}.wr.tmp/text > data/${x}.en.tmp/reclist3
            comm -12 data/${x}.en.tmp/reclist1 data/${x}.en.tmp/reclist2 > data/${x}.en.tmp/reclist12
            comm -12 data/${x}.en.tmp/reclist12 data/${x}.en.tmp/reclist3 > data/${x}.sp.tmp/reclist

            for lg in sp en wr; do
                reduce_data_dir.sh data/${x}.${lg}.tmp data/${x}.sp.tmp/reclist data/${x}.${lg}
                utils/fix_data_dir.sh --utt_extra_files "text.tc text.lc text.lc.rm" data/${x}.${lg}
            done
            rm -rf data/${x}.*.tmp
        done

        # compute global CMVN
        compute-cmvn-stats scp:data/${train_set_lg}/feats.scp data/${train_set_lg}/cmvn.ark

        # dump features for training
        dump.sh --cmd "$train_cmd" --nj 80 --do_delta $do_delta \
            data/${train_set_lg}/feats.scp data/${train_set_lg}/cmvn.ark exp/dump_feats/${train_set_lg} ${feat_tr_dir_lg}
        dump.sh --cmd "$train_cmd" --nj 32 --do_delta $do_delta \
            data/${train_dev_lg}/feats.scp data/${train_set_lg}/cmvn.ark exp/dump_feats/${train_dev_lg} ${feat_dt_dir_lg}

        trans_set_lg="test.en"
        for ttask in ${trans_set_lg}; do
            feat_trans_dir=${dumpdir}/${ttask}/delta${do_delta}; mkdir -p ${feat_trans_dir}
            dump.sh --cmd "$train_cmd" --nj 32 --do_delta $do_delta \
                data/${ttask}/feats.scp data/${train_set_lg}/cmvn.ark exp/dump_feats/trans/${ttask} ${feat_trans_dir}
    done
fi


if [[ ${stage} -le 2 ]] && [[ ${stop_stage} -ge 2 ]]; then
    dname=${train_set}_${bpemode}${nbpe}_${tgt_case}
    bpemodel=data/lang_1spm/use_${dprefix}/${dname}
    nlsyms=data/lang_1spm/use_${dprefix}/${train_set}_non_lang_syms_${tgt_case}
    nlsyms_tmp=${nlsyms}_tmp

    ### Task dependent. You have to check non-linguistic symbols used in the corpus.
    echo "***** stage 2: Dictionary *****"
    mkdir -p data/lang_1spm/use_${dprefix}

    # Create joint dictionary for both source and target languages
    if [[ ${use_joint_dict} == "true" ]]; then
        echo "*** Create a JOINT dictionary for source and target languages ***"
        dict=${bpemodel}.txt
        nlsyms=${nlsyms}.txt
        nlsyms_tmp=${nlsyms_tmp}.txt
        echo "| source and target dictionary: ${dict}"

        echo "make a non-linguistic symbol list for all languages"
        if [ -f ${nlsyms_tmp} ]; then
            echo "remove existing non-lang files"
            rm ${nlsyms_tmp}
        fi
        grep sp1.0 data/train_sp.en/text.${tgt_case} | cut -f 2- -d' ' | grep -o -P '&[^;]*;' >> ${nlsyms_tmp}
#        grep sp1.0 data/train_sp.sp/text.${src_case} | cut -f 2- -d' ' | grep -o -P '&[^;]*;' >> ${nlsyms_tmp}
#        grep sp1.0 data/train_sp.wr/text.${wrsrc_case} | cut -f 2- -d' ' | grep -o -P '&[^;]*;' >> ${nlsyms_tmp}
        
        cat ${nlsyms_tmp} | sort | uniq > ${nlsyms}
        rm ${nlsyms_tmp}
        cat ${nlsyms}

        special_symbols="<unk> 1" # <unk> must be 1, 0 will be used for "blank" in CTC
	if [[ ${use_lid} == "true" ]]; then
            i=2
            if [[ ${do_mt} == "true" ]]; then
                all_langs=$(echo "${tgt_langs}" | tr '_' ' ')
            else
                all_langs=$(echo "${tgt_langs}_ja" | tr '_' ' ')
            fi
            all_langs_sorted=$(echo ${all_langs[*]}| tr " " "\n" | sort -n | tr "\n" " ")
            echo "| all langs sorted: ${all_langs_sorted}"
            for lang in $(echo "${all_langs_sorted}" | tr '_' ' '); do
                special_symbols+="; <2${lang}> ${i}"
                i=$((i + 1))
            done
        fi

        sed "s/; /\n/g" <<< ${special_symbols} > ${dict}
        echo "special symbols"
        cat ${dict}

        offset=$(wc -l < ${dict})
        input_path=data/lang_1spm/use_${dprefix}/input_${dprefix}_${bpemode}${nbpe}_${tgt_case}.txt
        if [ -f ${input_path} ]; then
            echo "remove existing input text file"
            rm ${input_path}
        fi

	grep sp1.0 data/train_sp.en/text.${tgt_case} | cut -f 2- -d' ' | grep -v -e '^\s*$' >> ${input_path}
        grep sp1.0 data/train_sp.sp/text.${src_case} | cut -f 2- -d' ' | grep -v -e '^\s*$' >> ${input_path}
        grep sp1.0 data/train_sp.wr/text.${wrsrc_case} | cut -f 2- -d' ' | grep -v -e '^\s*$' >> ${input_path}
        spm_train --user_defined_symbols="$(tr "\n" "," < ${nlsyms})" --input=${input_path} --vocab_size=${nbpe} --model_type=${bpemode} --model_prefix=${bpemodel} --input_sentence_size=100000000 --character_coverage=1.0
        spm_encode --model=${bpemodel}.model --output_format=piece < ${input_path} | tr ' ' '\n' | sort | uniq | awk -v offset=${offset} '{print $0 " " NR+offset}' >> ${dict}
        echo "| Number of tokens in dictionary: $(wc -l ${dict})"

    # Create separate dictionaries: 1 for source transcription, 1 joint for all target langs
    else
        echo "*** Create SEPARATE dictionaries for source and target languages ***"
	echo "NOT IMPLEMENTED"
	exit 1
    fi
fi

if [[ ${stage} -le 3 ]] && [[ ${stop_stage} -ge 3 ]]; then
    dname=${train_set}_${bpemode}${nbpe}_${tgt_case}
    bpemodel=data/lang_1spm/use_${dprefix}/${dname}
    nlsyms=data/lang_1spm/use_${dprefix}/${train_set}_non_lang_syms_${tgt_case}
    nlsyms_tmp=${nlsyms}_tmp
    dict=${bpemodel}.txt
    nlsyms=${nlsyms}.txt
    nlsyms_tmp=${nlsyms_tmp}.txt
    
    echo "***** stage 3: Make json files *****"
	for lang in $(echo ${tgt_langs} | tr '_' ' '); do
            train_set_lg=train_sp.en
            train_dev_lg=dev.en
            feat_tr_dir_lg=${dumpdir}/${train_set_lg}/delta${do_delta}
            feat_dt_dir_lg=${dumpdir}/${train_dev_lg}/delta${do_delta}
            jname=data_${dprefix}_${bpemode}${nbpe}_${tgt_case}.json

            data2json.sh --nj 16 --feat ${feat_tr_dir_lg}/feats.scp --text data/${train_set_lg}/text.${tgt_case} --bpecode ${bpemodel}.model --lang ${lang} \
                data/${train_set_lg} ${dict} > ${feat_tr_dir_lg}/${jname}
            data2json.sh --feat ${feat_dt_dir_lg}/feats.scp --text data/${train_dev_lg}/text.${tgt_case} --bpecode ${bpemodel}.model --lang ${lang} \
                data/${train_dev_lg} ${dict} > ${feat_dt_dir_lg}/${jname}
            
            trans_set_lang="test.en"
            for ttask in ${trans_set_lang}; do
                feat_trans_dir=${dumpdir}/${ttask}/delta${do_delta}
                data2json.sh --feat ${feat_trans_dir}/feats.scp --text data/${ttask}/text.${tgt_case} --bpecode ${bpemodel}.model --lang ${lang} \
                    data/${ttask} ${dict} > ${feat_trans_dir}/${jname}
            done

            # update json (add spoken source references)
            trans_sets="${train_set_lg} ${train_dev_lg} ${trans_set_lang}"
            for x in ${trans_sets}; do
                echo "add source references to ${x}"
                feat_dir=${dumpdir}/${x}/delta${do_delta}
		data_dir=data/$(echo ${x} | cut -f 1 -d ".").sp
                update_json.sh --text ${data_dir}/text.${src_case} --bpecode ${bpemodel}.model \
                    ${feat_dir}/${jname} ${data_dir} ${dict}
            done
	    # update json (add written source references)
            trans_sets="${train_set_lg} ${train_dev_lg} ${trans_set_lang}"
            for x in ${trans_sets}; do
                echo "add source references to ${x}"
                feat_dir=${dumpdir}/${x}/delta${do_delta}
		data_dir=data/$(echo ${x} | cut -f 1 -d ".").wr
                update_json.sh --text ${data_dir}/text.${wrsrc_case} --bpecode ${bpemodel}.model \
                    ${feat_dir}/${jname} ${data_dir} ${dict}
            done
    done
fi
 

# Experiment name and data directory
if [ -z ${tag} ]; then
    expname=${train_set}_${tgt_case}_${backend}_$(basename ${train_config%.*})_${bpemode}${nbpe}
    if ${do_delta}; then
        expname=${expname}_delta
    fi
    if [ -n "${preprocess_config}" ]; then
        expname=${expname}_$(basename ${preprocess_config%.*})
    fi
    if [ -n "${asr_model}" ]; then
        expname=${expname}_asrtrans
    fi
    if [ -n "${st_model}" ]; then
        expname=${expname}_sttrans
    fi
else
    expname=${tag} # use tag for experiment name
fi

# Experiment and tensorboard directories
expdir=${expdir}/${expname}
tensorboard_dir=${tensorboard_dir}/${expname}
mkdir -p ${expdir}
mkdir -p ${tensorboard_dir}
echo "| expdir: ${expdir}"
echo "| tensorboard_dir: ${tensorboard_dir}"

# path to data for training
datadir=${datadir}/use_${dprefix}/src${nbpe_src}_wrsrc${nbpe_wrsrc}_tgt${nbpe}

if [[ ${train_adapters} == "false" ]]; then
    train_json_dir=${datadir}/train_sp/ja-en.json
    val_json_dir=${datadir}/dev/ja-en.json 
else
    train_json_dir=${datadir}/train_sp
    val_json_dir=${datadir}/dev
fi

dpath=data/lang_1spm/use_${dprefix}
if [[ ${use_joint_dict} == "true" ]]; then
    dname=${train_set_dict}_${bpemode}${nbpe}_${tgt_case}
    dict_tgt=${dpath}/${dname}.txt
    dict_src=${dict_tgt}
    dict_wrsrc=${dict_tgt}
    bpemodel_tgt=${dpath}/${dname}
    bpemodel_src=${dpath}/${dname}
    bpemodel_wrsrc=${dpath}/${dname}
else
    echo "NNOT IMPLEMENTED: separate dictionaries"
    exit 1
    dname=${train_set_dict}_${bpemode}_src${nbpe_src}${src_case}_tgt${nbpe}${tgt_case}
    dpath=${dpath}/${dname}
    dict_tgt=${dpath}.tgt.txt
    dict_src=${dpath}.src.txt
    bpemodel_tgt=${dpath}.tgt
    bpemodel_src=${dpath}.src
fi

echo "*** Paths to training data and dictionary ***"
echo "| train_json_dir: ${train_json_dir}"
echo "| val_json_dir: ${val_json_dir}"
echo "| source dictionary: ${dict_src}"
echo "| source dictionary: ${dict_wrsrc}"
echo "| target dictionary: ${dict_tgt}"

# Find the latest snapshot (if it exists)
resume_dir=$expdir/results
exist_snaphots=false
for i in $resume_dir/snapshot.ep.*; do test -f "$i" && exist_snaphots=true && break; done
if [ "${exist_snaphots}" = true ]; then
    ckpt_nums=$(ls $resume_dir | grep snapshot | sed 's/[^0-9]*//g' | sed 's/\n/" "/g')
    last_ep=$(echo "${ckpt_nums[*]}" | sort -nr | head -n1)
    resume=${resume_dir}/snapshot.ep.${last_ep}
    echo "Last snapshot: snapshot.ep.${last_ep}"
fi

if [[ ${stage} -le 4 ]] && [[ ${stop_stage} -ge 4 ]]; then
    echo "***** stage 4: Network Training *****"

    # Resume training
    if [[ -z ${resume} ]]; then
        echo "Training from scratch!"
	echo ${train_json_dir}
    else
        echo "Resume training from ${resume}"
    fi

    # Run training
    ${cuda_cmd} --gpu ${ngpu} ${expdir}/train.log \
        st_train_tri.py \
		--lang-pairs ja-en \
                --config ${train_config} \
                --preprocess-conf ${preprocess_config} \
                --ngpu ${ngpu} \
                --backend ${backend} \
                --outdir ${expdir}/results \
                --tensorboard-dir ${tensorboard_dir} \
                --debugmode ${debugmode} \
                --dict-src ${dict_src} \
                --dict-wrsrc ${dict_wrsrc} \
                --dict-tgt ${dict_tgt} \
                --debugdir ${expdir} \
                --minibatches ${N} \
                --seed ${seed} \
                --verbose ${verbose} \
                --resume ${resume} \
                --train-json ${train_json_dir} \
                --valid-json ${val_json_dir} \
                --use-lid ${use_lid}

    echo "Log output is saved in ${expdir}/train.log"
fi


if [[ ${stage} -le 5 ]] && [[ ${stop_stage} -ge 5 ]]; then
    echo "***** stage 5: Decoding *****"
    if [[ $(get_yaml.py ${train_config} model-module) = *transformer* ]]; then
        # Average ST models
        if [[ -z ${trans_model} ]]; then
            # model used to translate
            if ${use_valbest_average}; then
                trans_model=model.val${n_average}.avg.best.bleu
                opt="--log ${expdir}/results/log"
            else
                trans_model=model.last${n_average}.avg.best.bleu
                opt="--log"
            fi
            if [[ ! -f ${expdir}/results/${trans_model} ]]; then
                echo "*** Get trans_model ***"
                local/average_checkpoints_st_bleu.py \
                    ${opt} \
                    --backend ${backend} \
                    --snapshots ${expdir}/results/snapshot.ep.* \
                    --out ${expdir}/results/${trans_model} \
                    --num ${n_average}        
            else
                echo "| trans_model ${expdir}/results/${trans_model} existed."
            fi
        fi
    fi

    # Use all threads available
    nj=`grep -c ^processor /proc/cpuinfo`
    nj=$(( nj / num_trans_set  ))
    # nj=80 # for testing

    if [[ $tag == *"debug"* ]]; then
        nj=1 # for debug
    fi
    echo "| njobs = ${nj}"
    pids=() # initialize pids

    for ttask in ${trans_set}; do
        split=test
        lg_pair=ja-en
        lg_tgt=en
        echo "| split: ${split}"
        echo "| language pair: ${lg_pair}"
        echo "| target language: ${lg_tgt}"
    
    (
        decode_config_lg_pair=${decode_config_dir}/${decode_config}.yaml
        decode_dir=decode_$(basename ${train_config%.*})_$(basename ${decode_config})_${split}_${lg_pair}_${trans_model}
        feat_trans_dir=${datadir}/${split}
        echo "| decode_dir: ${decode_dir}"
        echo "| feat_trans_dir: ${feat_trans_dir}"

        # split data
        if [ ! -f "${feat_trans_dir}/split${nj}utt_${tgt_langs}/${lg_pair}.${nj}.json" ]; then
            splitjson.py --parts ${nj} --tgt_lang ${tgt_langs} ${feat_trans_dir}/${lg_pair}.json
            echo "Finished splitting json file."
        else
            echo "json file has been already split."
        fi

        #### use CPU for decoding
        ngpu=0

        if [[ ! -f "${expdir}/${decode_dir}/data.json" ]]; then
            echo "Start decoding..."
            ${decode_cmd} JOB=1:${nj} ${expdir}/${decode_dir}/log/decode.JOB.log \
                st_trans_tri.py \
                --config ${decode_config_lg_pair} \
                --ngpu ${ngpu} \
                --backend ${backend} \
                --batchsize 0 \
                --trans-json ${feat_trans_dir}/split${nj}utt_${tgt_langs}/${lg_pair}.JOB.json \
                --result-label ${expdir}/${decode_dir}/data.JOB.json \
                --model ${expdir}/results/${trans_model} \
                --verbose ${verbose} \
	    	--recog-conv-and-trans True
        fi

        # Compute BLEU
        if [[ $tag != *"asr_model"* ]] && [[ $decode_config != *"asr"* ]]; then
            echo "Compute BLEU..."
            chmod +x local/score_bleu_st.sh
            local/score_bleu_st.sh --case ${tgt_case} \
                                   --bpe ${nbpe} --bpemodel ${bpemodel_tgt}.model \
                                   ${expdir}/${decode_dir} ${lg_tgt} ${dict_tgt} ${dict_src} \
                                   ${remove_non_verbal_eval}
            cat ${expdir}/${decode_dir}/result.tc.txt
        fi

        # Compute WER
#            echo "Compute WER score..."
#            idx=1
#            local/score_sclite_st.sh --case ${src_case} --wer true \
#                                     --bpe ${nbpe_src} --bpemodel ${bpemodel_src}.model \
#                                     ${expdir}/${decode_dir} ${dict_src} ${idx}
#            cat ${expdir}/${decode_dir}/result.wrd.wer.txt
    ) &
    pids+=($!) # store background pids
    done
    i=0; for pid in "${pids[@]}"; do wait ${pid} || ((++i)); done
    [ ${i} -gt 0 ] && echo "$0: ${i} background jobs are failed." && false
    echo "Finished decoding."
fi

if [[ ${stage} -le 6 ]] && [[ ${stop_stage} -ge 6 ]]; then
    echo "***** stage 6: Validation *****"

    for i in {1..75}; do
	    ${cuda_cmd} --gpu ${ngpu} ${expdir}/eval$i.log \
		st_eval_tri.py \
			--lang-pairs ja-en \
			--config ${train_config} \
			--preprocess-conf ${preprocess_config} \
			--ngpu ${ngpu} \
			--backend ${backend} \
			--outdir ${expdir}/results \
			--tensorboard-dir ${tensorboard_dir} \
			--debugmode ${debugmode} \
			--dict-src ${dict_src} \
			--dict-wrsrc ${dict_wrsrc} \
			--dict-tgt ${dict_tgt} \
			--debugdir ${expdir} \
			--minibatches ${N} \
			--seed ${seed} \
			--verbose ${verbose} \
			--resume ${resume} \
			--train-json ${train_json_dir} \
			--valid-json ${val_json_dir} \
			--use-lid ${use_lid} \
			--index ${i}
   		echo "Log output is saved in ${expdir}/eval$i.log"
		mv ${expdir}/results/log ${expdir}/results/log$i
	done
fi

