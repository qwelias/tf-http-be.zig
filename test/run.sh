#!/usr/bin/env bash
set -o errexit
set -o errtrace
set -o pipefail
set -o nounset
shopt -s globstar
shopt -s nullglob
# set -o xtrace

BASEDIR=$(dirname $0)

tf_destroy() {
    name=$1
    (
        cd "${name}"
        echo test: DESTROY "${name}"
        terraform apply -auto-approve -destroy > /dev/null
    )
}

tf_apply() {
    name=$1
    (
        cd "${name}"
        test -d .terraform || {
            echo test: INIT "${name}"
            terraform init > /dev/null
        }
        echo test: PLAN "${name}"
        plan_lines=$(terraform plan | wc -l)
        echo test: PLAN_LINES "${name}" "${plan_lines}"
        test 70 -gt "${plan_lines}"
        echo test: APPLY "${name}"
        terraform apply -auto-approve > /dev/null
    )
}

test_name() {
    name=$1
    mkdir "${name}"
    sed "s/NAME/${name}/" main.tf > ${name}/main.tf
    for i in $(seq 10); do
        for j in $( seq $(( (i-1)*50+1 )) $(( i*50 )) ); do
            sed "s/OUTPUT/${name}_${j}/" stuff.tf >> "${name}/main.tf"
        done
        tf_apply "${name}"
    done
    tf_destroy "${name}"
}

echo test: Start
./zig-out/bin/tf-http-be &
PID=$!
sleep 1

START_MEM=$(pmap $PID | grep total | awk '{print $2}')
trap 'pkill tf-http-be' ERR
(
    cd "${BASEDIR}"
    rm -rf */
    for i in $(seq 32); do
        test_name "name_${i}" &
    done

    while
        test 0 -lt $(jobs | grep test_name | wc -l)
    do
        jobs
        wait
    done
    rm -rf */
)
END_MEM=$(pmap $PID | grep total | awk '{print $2}')
echo test: MEM CHANGE $START_MEM '->' $END_MEM
echo test: Done, killing server
pkill tf-http-be || true
