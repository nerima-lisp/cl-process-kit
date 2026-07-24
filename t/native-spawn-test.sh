#!/bin/sh
set -eu

trampoline=${1:?native spawn trampoline path is required}
temporary=${TMPDIR:-/tmp}/cl-process-kit-native-spawn-$$
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
mkdir -p "$temporary"

# The trampoline execs its target by the exact path given -- it does not
# search $PATH -- so every subprocess below must be resolved to a real path
# first. A pure Nix sandbox build has no FHS /bin or /usr/bin, only whatever
# nativeBuildInputs put on $PATH, so hardcoding e.g. /bin/echo would fail
# there even though it works on a normal host.
sh_bin=$(command -v sh)
touch_bin=$(command -v touch)
# `command -v echo` can return the bare name "echo" when it resolves to a
# shell builtin rather than a file, which the trampoline (no $PATH search)
# cannot exec; unlike sh/touch, echo is commonly a builtin. Scan $PATH by
# hand for a real echo file instead of trusting command -v echo. touch and
# echo are also not reliably in the same directory (e.g. macOS ships
# /bin/echo but /usr/bin/touch), so this can't be derived from touch_bin.
echo_bin=
save_ifs=$IFS
IFS=:
for directory in $PATH; do
  if [ -x "$directory/echo" ]; then
    echo_bin="$directory/echo"
    break
  fi
done
IFS=$save_ifs
: "${echo_bin:?no echo executable found on PATH}"

"$trampoline" --error-fd 2 --map 1:2 -- "$echo_bin" mapped >&2 2>"$temporary/mapped"
test "$(cat "$temporary/mapped")" = mapped

exec 8>"$temporary/passed"
"$trampoline" --error-fd 2 --pass 8 -- "$sh_bin" -c 'printf inherited >&8'
exec 8>&-
test "$(cat "$temporary/passed")" = inherited

exec 3>"$temporary/three"
exec 4>"$temporary/four"
"$trampoline" --error-fd 2 --map 3:4 --map 4:3 -- \
  "$sh_bin" -c 'printf to-four >&3; printf to-three >&4'
exec 3>&-
exec 4>&-
test "$(cat "$temporary/three")" = to-three
test "$(cat "$temporary/four")" = to-four

"$trampoline" --error-fd 2 --map 0:-2 --map 9:-1 -- \
  "$sh_bin" -c 'test ! -t 0; ! (: >&9) 2>/dev/null'

"$trampoline" --error-fd 2 --chdir "$temporary" -- \
  "$sh_bin" -c 'pwd' >"$temporary/directory"
test "$(cat "$temporary/directory")" = "$(cd "$temporary" && pwd -P)"

"$trampoline" --error-fd 2 --session 1 -- \
  "$sh_bin" -c 'test "$(ps -o pid= -p $$ | perl -pe "s/ //g")" = "$(ps -o pgid= -p $$ | perl -pe "s/ //g")"' &
session_child=$!
wait "$session_child"

"$trampoline" --error-fd 2 --rlimit nofile:32:32 -- \
  "$sh_bin" -c 'test "$(ulimit -n)" = 32'

"$trampoline" --error-fd 2 --umask 077 -- "$touch_bin" "$temporary/masked"
case $(uname -s) in
  Darwin) mode=$(stat -f %Lp "$temporary/masked") ;;
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
