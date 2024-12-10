#!/bin/bash

#SBATCH -N 1
#SBATCH -c 8
#SBATCH -t 03:00:00
#SBATCH -p conroy,itc_cluster,shared
#SBATCH --constraint="intel"
#SBATCH --mem=8G
#SBATCH --export=ALL
#SBATCH -J test-build
#SBATCH --no-requeue


# set SLURM options (used for all sbatch calls)
export CLEANUP_OPTIONS="--partition=conroy,shared,itc_cluster --constraint=intel --mem=4G --ntasks-per-node=1"
export MY_SLURM_OPTIONS="--partition=conroy,shared,itc_cluster --constraint=intel --mem=15G"
export STAR_OPTIONS="--partition=conroy,shared,itc_cluster --constraint=intel --mem=15G --time=6:00:00"

# set other relevant MESA options
#export MESA_RUN_OPTIONAL=t
#export MESA_FPE_CHECKS_ON=1

# make sure this is on by default for when we update to using this instead of MESA_RUN_OPTIONAL
export MESA_SKIP_OPTIONAL=t

# set paths for OP opacities
#export MESA_OP_MONO_DATA_PATH=${DATA_DIR}/OP4STARS_1.3/mono
#export MESA_OP_MONO_DATA_CACHE_FILENAME=${DATA_DIR}/OP4STARS_1.3/mono/op_mono_cache.bin
#rm -f ${MESA_OP_MONO_DATA_CACHE_FILENAME}

# set non-default cache directory (will be cleaned up on each run)
#export MESA_CACHES_DIR=/tmp/mesa-cache


echo $HOME
cd ~/mesa-helios-test
pwd

echo $OUT_FOLD
echo "-----"

source ~/.bashrc

# Dont let this file get confused with mesa_test.sh
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
	echo "script ${BASH_SOURCE[0]} is being sourced ..."
	exit 1
fi

echo $DATACENTER
echo $SLURM_JOB_NODELIST
echo $SLURM_LOCALID
echo $SLURM_NODE_ALIASES
echo $SLURM_NODEID
echo $SLURM_JOB_ID
echo $SLURMD_NODENAME
echo $OUT_FOLD
echo $HOME
echo "**********"

source mesa_test.sh

# set email address for SLURM and for cleanup output
export MY_EMAIL_ADDRESS=evan.bauer.astro@gmail.com

# set how many threads; this will also be sent to SLURM as --ntasks-per-node
export OMP_NUM_THREADS=8

echo $MESASDK_ROOT
echo $VERSION


# Limit number of mesa's being tested at once
while [[ $(ls -d "${MESA_TMP}"/tmp.* | wc -l) -gt 20 ]];
do
	echo "Too many tests in progress sleeping"
	date
	sleep 10m
done

# Make a temporay folder to build mesa in
export MESA_DIR=$(mktemp -d -p "$MESA_TMP")
echo $MESA_DIR
echo $HOME

#module load git
spack load git-lfs # also loads a newer git

echo "MESA_GIT_LFS_SLEEP:"
echo $MESA_GIT_LFS_SLEEP

which git
which git-lfs

# Checkout and install to new folder
mesa_test install -c --mesadir=$MESA_DIR $VERSION
mesa_test submit -e --mesadir=$MESA_DIR


if ! grep -q "MESA installation was successful" "$MESA_DIR/build.log" ; then
	echo "Checkout failed"
	rm -r $MESA_DIR
	exit 1
fi

cd "${MESA_DIR}" || exit

# Look for tests to be skipped
export skip_tests=0
if [[ $(git log -1) == *'[ci skip]'* ]];then
    export skip_tests=1
fi

export split_tests=0
if [[ $(git log -1) == *'[ci split]'* ]];then
    export split_tests=1
fi

if [[ $(git log -1) == *'[ci optional'* ]];then
    export MESA_RUN_OPTIONAL=t
    unset MESA_SKIP_OPTIONAL
    export STAR_OPTIONS="--partition=conroy,shared,itc_cluster --constraint=intel --mem=15G --time=12:00:00"
fi

if [[ $(git log -1) == *'[ci converge]'* ]];then
    export MESA_TEST_SUITE_RESOLUTION_FACTOR=0.8
    export STAR_OPTIONS="--partition=conroy,shared,itc_cluster --constraint=intel --mem=15G --time=12:00:00"
fi

if [[ $(git log -1) == *'[ci fpe]'* ]];then
    export MESA_FPE_CHECKS_ON=1
fi

# if ci skip, then exit and don't submit any further tests
if [[ $skip_tests -eq 1 ]];then
    rm -rf $MESA_DIR
    exit 0
fi

# if USE_MESA_TEST is set, use mesa_test gem; pick its options via MESA_TEST_OPTIONS
# otherwise, use built-in each_test_run script
export USE_MESA_TEST=t
export MESA_TEST_OPTIONS="--force --mesadir=${MESA_DIR}" # --no-submit"

# function to clean caches; executed at start of each job
clean_caches(){
    # clean up cache dir if needed
    if [ -n "${MESA_CACHES_DIR}" ]; then
        rm -rf ${MESA_CACHES_DIR}
        mkdir -p ${MESA_CACHES_DIR}
    fi
}

export -f clean_caches


# Need to be in mesa-helios-test to submit the jobs
cd $MESA_SCRIPTS

# run the star test suite
# this is part is parallelized, so get the number of tests
cd ${MESA_DIR}/star/test_suite
export NTESTS=$(./count_tests)
cd -

if [[ $NTESTS -gt 0 ]]; then
    if [[ $split_tests -eq 1 ]];then
	half=$((NTESTS/2))
	export STAR_JOBID=$(sbatch --parsable \
                               --ntasks-per-node=${OMP_NUM_THREADS} \
                               --array=1-${half} \
                               --output="${OUT_FOLD}/star.log-%a" \
                               --mail-user=${MY_EMAIL_ADDRESS} \
                               ${STAR_OPTIONS} \
                               star.sh)
	depend=afterany:$STAR_JOBID
    else
	if [[ $NTESTS -gt 10 ]]; then
	    # submit the first 10 tests with 16 cores
	    export OMP_NUM_THREADS=16
	    export STAR_JOBID1=$(sbatch --parsable \
                               --ntasks-per-node=${OMP_NUM_THREADS} \
                               --array=1-10 \
                               --output="${OUT_FOLD}/star.log-%a" \
                               --mail-user=${MY_EMAIL_ADDRESS} \
                               ${STAR_OPTIONS} \
                               star.sh)
	    export OMP_NUM_THREADS=8
	    export STAR_JOBID2=$(sbatch --parsable \
                               --ntasks-per-node=${OMP_NUM_THREADS} \
                               --array=11-${NTESTS} \
                               --output="${OUT_FOLD}/star.log-%a" \
                               --mail-user=${MY_EMAIL_ADDRESS} \
                               ${STAR_OPTIONS} \
                               star.sh)
	    depend=afterany:$STAR_JOBID1,afterany:$STAR_JOBID2
	else
	    # just submit all the tests for 16 cores
	    export OMP_NUM_THREADS=16
	    export STAR_JOBID=$(sbatch --parsable \
                               --ntasks-per-node=${OMP_NUM_THREADS} \
                               --array=1-${NTESTS} \
                               --output="${OUT_FOLD}/star.log-%a" \
                               --mail-user=${MY_EMAIL_ADDRESS} \
                               ${STAR_OPTIONS} \
                               star.sh)
	    export OMP_NUM_THREADS=8
	    depend=afterany:$STAR_JOBID
	fi
    fi
fi

# run the binary test suite
# this is part is parallelized, so get the number of tests
cd ${MESA_DIR}/binary/test_suite
export NTESTS=$(./count_tests)
cd -

if [[ $NTESTS -gt 0 ]]; then
    export BINARY_JOBID=$(sbatch --parsable \
                                 --ntasks-per-node=${OMP_NUM_THREADS} \
                                 --array=1-${NTESTS} \
                                 --output="${OUT_FOLD}/binary.log-%a" \
                                 --mail-user=${MY_EMAIL_ADDRESS} \
                                 ${MY_SLURM_OPTIONS} \
                                 binary.sh)
    depend=${depend},afterany:$BINARY_JOBID
fi


# run the astero test suite
# this is part is parallelized, so get the number of tests
cd ${MESA_DIR}/astero/test_suite
export NTESTS=$(./count_tests)
cd -

if [[ $NTESTS -gt 0 ]]; then
    export ASTERO_JOBID=$(sbatch --parsable \
                                 --ntasks-per-node=${OMP_NUM_THREADS} \
                                 --array=1-${NTESTS} \
                                 --output="${OUT_FOLD}/astero.log-%a" \
                                 --mail-user=${MY_EMAIL_ADDRESS} \
                                 ${MY_SLURM_OPTIONS} \
                                 astero.sh)
    depend=${depend},afterany:$ASTERO_JOBID
fi

echo "Dependencies for cleanup:"
echo $depend

sbatch --output="${OUT_FOLD}/cleanup.log" \
       --dependency=${depend} \
       ${CLEANUP_OPTIONS} \
       cleanup.sh

