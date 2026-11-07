#!/bin/bash
# Fork experiment, run as root beside the suite: for each nr-softmodem the
# suite attaches strace to (sig_term_handled), check 6.5 s later whether it
# still lives; if so, dump its threads, then save the killed container's log.
export KUBECONFIG=${KUBECONFIG:-/home/runner/.kube/config}
declare -A seen
podof() { # host pid -> namespace/pod from its cgroup's pod uid
  local u; u=$(grep -o 'pod[0-9a-f_-]\{36\}' /proc/$1/cgroup | head -1 | sed 's/^pod//; s/_/-/g')
  kubectl get pods -A -o jsonpath="{range .items[?(@.metadata.uid=='$u')]}{.metadata.namespace}/{.metadata.name}{end}" 2>/dev/null
}
check() { # pid tracer pod
  local p=$1 tp=$2 pod=$3 t tid
  sleep 6.5
  if [ ! -d /proc/$p ]; then echo "=== $(date +%T) $pod nr-softmodem $p gone within 6.5 s of strace (tracer $tp)"; return; fi
  echo "=== $(date +%T) $pod nr-softmodem $p STILL ALIVE 6.5 s after strace attached (tracer $tp)"
  grep -E 'State|SigPnd|ShdPnd|SigBlk|SigCgt' /proc/$p/status
  for t in /proc/$p/task/*; do
    tid=${t##*/}
    echo "$tid $(cat $t/comm) state=$(awk '{print $3}' $t/stat) wchan=$(cat $t/wchan) syscall=$(cut -d' ' -f1 $t/syscall) $(chrt -p $tid 2>/dev/null | sed -n 's/.*policy: /policy=/p;s/.*priority: /prio=/p' | tr '\n' ' ') pnd=$(awk '/^SigPnd/{print $2}' $t/status)"
    echo "    kstack: $(awk '{print $2}' $t/stack 2>/dev/null | head -6 | tr '\n' ' ')"
  done
  while [ -d /proc/$p ]; do sleep 0.2; done
  echo "--- $(date +%T) $pod: killed; its container's log (previous), last 60 lines"
  sleep 3
  kubectl -n ${pod%%/*} logs ${pod#*/} --previous --tail=60 2>&1 | cut -c1-220
}
end=$((SECONDS+4000))
while [ $SECONDS -lt $end ]; do
  for p in $(pgrep -x nr-softmodem); do
    [ -n "${seen[$p]:-}" ] && continue
    tp=$(awk '/^TracerPid/{print $2}' /proc/$p/status 2>/dev/null)
    [ -n "$tp" ] && [ "$tp" != 0 ] || continue
    seen[$p]=1; pod=$(podof $p)
    echo "=== $(date +%T) $pod nr-softmodem $p traced by $tp ($(tr '\0' ' ' < /proc/$tp/cmdline 2>/dev/null | cut -c1-80))"
    check $p $tp "$pod" &
  done
  sleep 0.3
done
