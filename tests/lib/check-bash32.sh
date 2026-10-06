#!/usr/bin/env bash
# Flag bash-4+ constructs in scripts that must run on bash 3.2 (PRD: Shell
# compatibility). A cheap static net; the real proof is running the tests in
# the bash:3.2 container (`make test-bash32`). Comment lines are ignored.
# Usage: tests/lib/check-bash32.sh FILE...
set -u

# pattern<TAB>explanation (extended regex, matched per line)
rules='\bmapfile\b|readarray\b	mapfile/readarray (bash 4)
\b(declare|local|typeset)[[:space:]]+-[a-zA-Z]*[An]	associative arrays / namerefs (bash 4.0/4.3)
\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,,?|\^\^?)[^}]*\}	case-modifying expansion ${v,,} ${v^^} (bash 4)
\$\{[A-Za-z_][A-Za-z0-9_]*@[QEPAaUuLK]\}	${v@Q}-style transformations (bash 4.4)
\[\[[[:space:]]+-v[[:space:]]	[[ -v name ]] (bash 4.2)
\|&	|& pipe (bash 4)
&>>	&>> redirection (bash 4)
;;&|;&[[:space:]]*$	case fall-through ;;& / ;& (bash 4)
\bcoproc\b	coproc (bash 4)
\bwait[[:space:]]+-n\b	wait -n (bash 4.3)
EPOCHSECONDS|EPOCHREALTIME|BASHPID	bash 4/5-only variables
printf[[:space:]]+(-v[[:space:]]+[A-Za-z_]+[[:space:]]+)?.%\([^)]*\)T	printf %(fmt)T (bash 4.2)
\$\{[A-Za-z_][A-Za-z0-9_]*\[-[0-9]+\]\}	negative array index (bash 4.3)
\{[0-9a-z]+\.\.[0-9a-z]+\.\.[0-9]+\}	brace expansion with step (bash 4)
shopt[[:space:]]+-s[[:space:]]+(globstar|lastpipe|autocd|direxpand|checkjobs)	bash-4-only shopt
\bread[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*i	read -i (bash 4)
\bdeclare[[:space:]]+-[a-zA-Z]*g	declare -g (bash 4.2)'

status=0
for f in "$@"; do
  while IFS='	' read -r re why; do
    hits=$(grep -nE "$re" "$f" | grep -vE '^[0-9]+:[[:space:]]*#')
    if [ -n "$hits" ]; then
      printf '%s: %s\n' "$f" "$why"
      printf '%s\n' "$hits" | sed 's/^/    line /'
      status=1
    fi
  done <<EOF
$rules
EOF
done
exit $status
