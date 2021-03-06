#!/bin/bash

# Copyright 2015  Yajie Miao    (Carnegie Mellon University)
#           2015  Hang Su
#           2016  Mohammad Gowayyed
# Apache 2.0

# This script trains acoustic models based on CTC and using SGD. 

## Begin configuration section
train_tool=train-ctc-parallel  # the command for training; by default, we use the
                # parallel version which processes multiple utterances at the same time 

# configs for multiple sequences
num_sequence=5           # during training, how many utterances to be processed in parallel
valid_num_sequence=10    # number of parallel sequences in validation
frame_num_limit=1000000  # the number of frames to be processed at a time in training; this config acts to
         # to prevent running out of GPU memory if #num_sequence very long sequences are processed;the max
         # number of training examples is decided by if num_sequence or frame_num_limit is reached first. 

# learning rate
learn_rate=4e-5          # learning rate
final_learn_rate=1e-6    # final learning rate
momentum=0.9             # momentum

# learning rate schedule
max_iters=25             # max number of iterations
min_iters=               # min number of iterations
start_epoch_num=1        # start from which epoch, used for resuming training from a break point

start_halving_inc=0.5    # start halving learning rates when the accuracy improvement falls below this amount
end_halving_inc=0.1      # terminate training when the accuracy improvement falls below this amount
halving_factor=0.5       # learning rate decay factor
halving_after_epoch=1    # halving becomes enabled after this many epochs
force_halving_epoch=     # force halving after this epoch

# logging
report_step=1000         # during training, the step (number of utterances) of reporting objective and accuracy
verbose=1

# feature configs
sort_by_len=true         # whether to sort the utterances by their lengths
min_len=0                # minimal length of utterances to consider

splice_feats=false       # whether to splice neighboring frams
subsample_feats=false    # whether to subsample features
norm_vars=true           # whether to apply variance normalization when we do cmn
add_deltas=true          # whether to add deltas
copy_feats=true          # whether to copy features into a local dir (on the GPU machine)
feats_tmpdir=""          # the tmp dir to save the copied features, when copy_feats=true

# status of learning rate schedule; useful when training is resumed from a break point
cvacc=0
halving=0

# Multi-GPU training
nj=1
utts_per_avg=700

## End configuration section

echo "$0 $@"  # Print the command line for logging

[ -f ./path.sh ] && . ./path.sh; 
[ -f ./cmd.sh ] && . ./cmd.sh; 

. utils/parse_options.sh || exit 1;

if [ $# != 3 ]; then
  echo "Usage: $0 <data-tr> <data-cv> <exp-dir>"
  echo " e.g.: $0 data/train_tr data/train_cv exp/train_phn"
  exit 1;
fi

data_tr=$1
data_cv=$2
dir=$3

mkdir -p $dir/log $dir/nnet

for f in $data_tr/feats.scp $data_cv/feats.scp $dir/labels.tr.gz $dir/labels.cv.gz $dir/nnet.proto; do
  [ ! -f $f ] && echo "train_ctc_parallel.sh: no such file $f" && exit 1;
done

## Read the training status for resuming
[ -f $dir/.epoch ] && start_epoch_num=`cat $dir/.epoch 2>/dev/null`
[ -f $dir/.cvacc ] && cvacc=`cat $dir/.cvacc 2>/dev/null`
[ -f $dir/.halving ] && halving=`cat $dir/.halving 2>/dev/null`
[ -f $dir/.lrate ] && learn_rate=`cat $dir/.lrate 2>/dev/null`

## Set up labels  
labels_tr="ark:gunzip -c $dir/labels.tr.gz|"
labels_cv="ark:gunzip -c $dir/labels.cv.gz|"
# Compute the occurrence counts of labels in the label sequences. These counts will be used to derive prior probabilities of
# the labels.
gunzip -c $dir/labels.tr.gz | awk '{line=$0; gsub(" "," 0 ",line); print line " 0";}' | \
  analyze-counts --verbose=1 --binary=false ark:- $dir/label.counts >& $dir/log/compute_label_counts.log || exit 1
##

## Set up features
# output feature configs which will be used in decoding
echo $norm_vars > $dir/norm_vars
echo $add_deltas > $dir/add_deltas
echo $splice_feats > $dir/splice_feats
echo $subsample_feats > $dir/subsample_feats

if $sort_by_len; then
  feat-to-len scp:$data_tr/feats.scp ark,t:- | awk '{print $2}' | \
    paste -d " " $data_tr/feats.scp - | sort -k3 -n - | awk -v m=$min_len '{ if ($3 >= m) {print $1 " " $2} }' > $dir/train.scp || exit 1;
  feat-to-len scp:$data_cv/feats.scp ark,t:- | awk '{print $2}' | \
    paste -d " " $data_cv/feats.scp - | sort -k3 -n - | awk '{print $1 " " $2}' > $dir/cv.scp || exit 1;
else
  cat $data_tr/feats.scp | utils/shuffle_list.pl --srand ${seed:-777} > $dir/train.scp
  cat $data_cv/feats.scp | utils/shuffle_list.pl --srand ${seed:-777} > $dir/cv.scp
fi

feats_tr="ark,s,cs:apply-cmvn --norm-vars=$norm_vars --utt2spk=ark:$data_tr/utt2spk scp:$data_tr/cmvn.scp scp:$dir/train.scp ark:- |"
feats_cv="ark,s,cs:apply-cmvn --norm-vars=$norm_vars --utt2spk=ark:$data_cv/utt2spk scp:$data_cv/cmvn.scp scp:$dir/cv.scp ark:- |"

if $splice_feats; then
  feats_tr="$feats_tr splice-feats --left-context=1 --right-context=1 ark:- ark:- |"
  feats_cv="$feats_cv splice-feats --left-context=1 --right-context=1 ark:- ark:- |"
fi

if $subsample_feats; then
  #Subsample feats 3-fold, implies using a local directory
  tmpdir=$(mktemp -dp "$feats_tmpdir");

  copy-feats "$feats_tr" "ark:-" | tee     $tmpdir/tr.tmp.ark | \
      subsample-feats --n=3 --offset=0 ark:-                  ark,scp:$tmpdir/train0.ark,$tmpdir/train0local.scp || exit 1;
      subsample-feats --n=3 --offset=1 ark:$tmpdir/tr.tmp.ark ark,scp:$tmpdir/train1.ark,$tmpdir/train1local.scp || exit 1;
      subsample-feats --n=3 --offset=2 ark:$tmpdir/tr.tmp.ark ark,scp:$tmpdir/train2.ark,$tmpdir/train2local.scp || exit 1;  
  copy-feats "$feats_cv" "ark:-" | tee     $tmpdir/cv.tmp.ark | \
      subsample-feats --n=3 --offset=0 ark:-                  ark,scp:$tmpdir/cv0.ark,$tmpdir/cv0local.scp || exit 1;
      subsample-feats --n=3 --offset=1 ark:$tmpdir/cv.tmp.ark ark,scp:$tmpdir/cv1.ark,$tmpdir/cv1local.scp || exit 1;
      subsample-feats --n=3 --offset=2 ark:$tmpdir/cv.tmp.ark ark,scp:$tmpdir/cv2.ark,$tmpdir/cv2local.scp || exit 1;
  rm $tmpdir/tr.tmp.ark $tmpdir/cv.tmp.ark
  
  # this code is experimental - we may need to sort the data more carefully
  sed 's/^/0x/' $tmpdir/train0local.scp        > $tmpdir/train_local.scp
  sed 's/^/0x/' $tmpdir/cv0local.scp           > $tmpdir/cv_local.scp
  sed 's/^/1x/' $tmpdir/train1local.scp | tac >> $tmpdir/train_local.scp
  sed 's/^/1x/' $tmpdir/cv1local.scp    | tac >> $tmpdir/cv_local.scp
  sed 's/^/2x/' $tmpdir/train2local.scp       >> $tmpdir/train_local.scp
  sed 's/^/2x/' $tmpdir/cv2local.scp          >> $tmpdir/cv_local.scp

  gzip -cd $dir/labels.tr.gz | sed 's/^/0x/'  > $tmpdir/labels.tr
  gzip -cd $dir/labels.cv.gz | sed 's/^/0x/'  > $tmpdir/labels.cv
  gzip -cd $dir/labels.tr.gz | sed 's/^/1x/' >> $tmpdir/labels.tr
  gzip -cd $dir/labels.cv.gz | sed 's/^/1x/' >> $tmpdir/labels.cv
  gzip -cd $dir/labels.tr.gz | sed 's/^/2x/' >> $tmpdir/labels.tr
  gzip -cd $dir/labels.cv.gz | sed 's/^/2x/' >> $tmpdir/labels.cv
  labels_tr="ark:cat $tmpdir/labels.tr|"
  labels_cv="ark:cat $tmpdir/labels.cv|"

  utils/prep_scps.sh --nj $nj --cmd "run.pl" ${seed:+ --seed=$seed} \
    $tmpdir/train_local.scp $tmpdir/cv_local.scp $num_sequence $frame_num_limit $tmpdir $tmpdir || exit 1;
  feats_tr="ark,s,cs:copy-feats scp:$tmpdir/feats_tr.JOB.scp ark:- |"
  feats_cv="ark,s,cs:copy-feats scp:$tmpdir/feats_cv.JOB.scp ark:- |"

  trap "echo \"Removing features tmpdir $tmpdir @ $(hostname)\"; ls -l $tmpdir; rm -r $tmpdir" EXIT

elif $copy_feats; then
  # Save the features to a local dir on the GPU machine. On Linux, this usually points to /tmp
  tmpdir=$(mktemp -dp "$feats_tmpdir");
      
  copy-feats "$feats_tr" ark,scp:$tmpdir/train.ark,$tmpdir/train_local.scp || exit 1;
  copy-feats "$feats_cv" ark,scp:$tmpdir/cv.ark,$tmpdir/cv_local.scp || exit 1;

  utils/prep_scps.sh --nj $nj --cmd "run.pl" ${seed:+ --seed=$seed} \
    $tmpdir/train_local.scp $tmpdir/cv_local.scp $num_sequence $frame_num_limit $tmpdir $tmpdir || exit 1;
  feats_tr="ark,s,cs:copy-feats scp:$tmpdir/feats_tr.JOB.scp ark:- |"
  feats_cv="ark,s,cs:copy-feats scp:$tmpdir/feats_cv.JOB.scp ark:- |"
  
  trap "echo \"Removing features tmpdir $tmpdir @ $(hostname)\"; ls $tmpdir; rm -r $tmpdir" EXIT
else
  # we hope you have the features set up correctly

  feats_tr="ark,s,cs:copy-feats scp:$feats_tmpdir/feats_tr.JOB.scp ark:- |"
  feats_cv="ark,s,cs:copy-feats scp:$feats_tmpdir/feats_cv.JOB.scp ark:- |"
fi

if $add_deltas; then
  feats_tr="$feats_tr add-deltas ark:- ark:- |"
  feats_cv="$feats_cv add-deltas ark:- ark:- |"
fi
## End of feature setup

# Initialize model parameters
if [ ! -f $dir/nnet/nnet.iter0 ]; then
  echo "Initializing model as $dir/nnet/nnet.iter0"
  net-initialize --binary=true $dir/nnet.proto $dir/nnet/nnet.iter0 >& $dir/log/initialize_model.log || exit 1;
fi

T=`mktemp -d` 
cp $dir/nnet/nnet.iter$[start_epoch_num-1] $T || exit 1;

cur_time=`date | awk '{print $6 "-" $2 "-" $3 " " $4}'`
echo "TRAINING STARTS [$cur_time]"
echo "[NOTE] TOKEN_ACCURACY refers to token accuracy, i.e., (1.0 - token_error_rate)."
for iter in $(seq $start_epoch_num $max_iters); do
    cvacc_prev=$cvacc
    echo -n "EPOCH $iter RUNNING ... "

    # train
    for JOB in `seq 1 $nj`; do
      F=`echo $feats_tr|awk -v j=$JOB '{sub("JOB", j); print $0}'`
      $train_tool --report-step=$report_step --num-sequence=$num_sequence --frame-limit=$frame_num_limit \
	    --learn-rate=$learn_rate --momentum=$momentum --num-jobs=$nj --job-id=$JOB --verbose=$verbose \
            ${utts_per_avg:+ --utts-per-avg=$utts_per_avg} \
            "$F" "$labels_tr" $T/nnet.iter$[iter-1] $T/nnet.iter${iter} >& $dir/log/tr.iter$iter.$JOB.log &
      sleep 30
    done
    cp $T/nnet.iter$[iter-1] $dir/nnet
    wait
    tracc=$(cat $dir/log/tr.iter${iter}.1.log | grep "TOTAL TOKEN_ACCURACY" | tail -n 1 | awk '{ acc=$(NF-1); gsub("%","",acc); print acc; }')
    echo -n "lrate $(printf "%.6g" $learn_rate), TRAIN ACCURACY $(printf "%.4f" $tracc)%, "

    end_time=`date | awk '{print $6 "-" $2 "-" $3 " " $4}'`
    echo -n "ENDS [$end_time]: "

    # validation
    for JOB in `seq 1 $nj`; do
	F=`echo $feats_cv|awk -v j=$JOB '{sub("JOB", j); print $0}'`
	$train_tool --report-step=$report_step --num-sequence=$valid_num_sequence --frame-limit=$frame_num_limit \
        --cross-validate=true --num-jobs=$nj --job-id=$JOB --learn-rate=$learn_rate --verbose=$verbose \
        "$F" "$labels_cv" $T/nnet.iter${iter} >& $dir/log/cv.iter$iter.$JOB.log || exit 1 &
	sleep 30
    done
    wait
    cvacc=$(cat $dir/log/cv.iter${iter}.1.log | grep "TOTAL TOKEN_ACCURACY" | tail -n 1 | awk '{ acc=$(NF-1); gsub("%","",acc); print acc; }')
    echo "VALID ACCURACY $(printf "%.4f" $cvacc)%"

    # stopping criterion
    intre='^[0-9]+$'
    rel_impr=$(bc <<< "($cvacc-$cvacc_prev)") || rel_impr=$start_halving_inc
    if [ 1 == $halving -a 1 == $(bc <<< "$rel_impr < $end_halving_inc") ]; then
      if [[ ( "$min_iters" =~ $intre ) && ( $min_iters -gt $iter ) ]]; then
        echo we were supposed to finish, but we continue as min_iters : $min_iters
      else
        echo finished, too small rel. improvement $rel_impr
        break
      fi
    fi

    # start annealing when improvement is low
    if [ 1 == $(bc <<< "$rel_impr < $start_halving_inc") -a $iter -ge $halving_after_epoch ]; then
      halving=1
    fi
    if [[ ( "$force_halving_epoch" =~ $intre ) && ( $iter -ge $force_halving_epoch ) ]]; then
      halving=1
    fi
    
    # do annealing
    if [ 1 == $halving ]; then
      learn_rate=$(awk "BEGIN{print($learn_rate*$halving_factor)}")
      learn_rate=$(awk "BEGIN{if ($learn_rate<$final_learn_rate) {print $final_learn_rate} else {print $learn_rate}}")
    fi

    # save the status 
    echo $[$iter+1] > $dir/.epoch    # +1 because we save the epoch to start from
    echo $cvacc > $dir/.cvacc
    echo $halving > $dir/.halving
    echo $learn_rate > $dir/.lrate
done

# Convert the model marker from "<BiLstmParallel>" to "<BiLstm>"
format-to-nonparallel $dir/nnet/nnet.iter${iter} $dir/final.nnet >& $dir/log/model_to_nonparal.log || exit 1;

echo "Training succeeded. The final model $dir/final.nnet"
