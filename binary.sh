#!/bin/bash

#SBATCH --job-name=binary
#SBATCH --nodes=1
#SBATCH --export=ALL
#SBATCH --time=4:00:00
#SBATCH --mail-type=FAIL
#SBATCH --requeue

clean_caches

if [ -n "${USE_MESA_TEST}" ]; then
    mesa_test test ${SLURM_ARRAY_TASK_ID} --module=binary ${MESA_TEST_OPTIONS}
else
    cd ${MESA_DIR}/binary/test_suite
    ./each_test_run ${SLURM_ARRAY_TASK_ID}
fi
