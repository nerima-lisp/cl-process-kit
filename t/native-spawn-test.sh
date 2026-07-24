#!/bin/sh
set -eu

trampoline=${1:?native spawn trampoline path is required}
temporary=${TMPDIR:-/tmp}/cl-process-kit-native-spawn-$$
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
mkdir -p "$temporary"

"$trampoline" --error-fd 2 --map 1:2 -- /bin/echo mapped >&2 2>"$temporary/mapped"
test "$(cat "$temporary/mapped")" = mapped

exec 8>"$temporary/passed"
"$trampoline" --error-fd 2 --pass 8 -- /bin/sh -c 'printf inherited >&8'
exec 8>&-
test "$(cat "$temporary/passed")" = inherited

exec 3>"$temporary/three"
exec 4>"$temporary/four"
"$trampoline" --error-fd 2 --map 3:4 --map 4:3 -- \
  /bin/sh -c 'printf to-four >&3; printf to-three >&4'
exec 3>&-
exec 4>&-
test "$(cat "$temporary/three")" = to-three
test "$(cat "$temporary/four")" = to-four

"$trampoline" --error-fd 2 --map 0:-2 --map 9:-1 -- \
  /bin/sh -c 'test ! -t 0; ! (: >&9) 2>/dev/null'

"$trampoline" --error-fd 2 --chdir "$temporary" -- \
  /bin/sh -c 'pwd' >"$temporary/directory"
test "$(cat "$temporary/directory")" = "$(cd "$temporary" && pwd -P)"

"$trampoline" --error-fd 2 --session 1 -- \
  /bin/sh -c 'test "$(ps -o pid= -p $$ | perl -pe "s/ //g")" = "$(ps -o pgid= -p $$ | perl -pe "s/ //g")"' &
session_child=$!
wait "$session_child"

"$trampoline" --error-fd 2 --rlimit nofile:32:32 -- \
  /bin/sh -c 'test "$(ulimit -n)" = 32'

"$trampoline" --error-fd 2 --umask 077 -- /usr/bin/touch "$temporary/masked"
case $(uname -s) in
  Darwin) mode=$(/usr/bin/stat -f %Lp "$temporary/masked") ;;
  *) mode=$(stat -c %a "$temporary/masked") ;;
esac
test "$mode" = 600

set +e
"$trampoline" --error-fd 2 -- /definitely/missing 2>"$temporary/error"
status=$?
set -e
test "$status" = 127
test "$(wc -c <"$temporary/error" | perl -pe 's/ //g')" = 8
test "$(perl -e 'read STDIN, $x, 8; print unpack("L", $x)' <"$temporary/error")" = 8
