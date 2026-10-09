# shellcheck shell=bash
# The M2 tool-calling suite: 20 DevOps/SRE tasks that cannot be done without
# tools. Every case runs in a fresh copy of the same small "server snapshot"
# (eval_fixture), as the agent's current directory.
#
# Per case ID:
#   eval_prompt ID   the prompt sent to zot
#   eval_kind ID     the tool the task mainly needs (for the report)
#   check_ID         run in the workspace after the agent finished, with the
#                    agent's final reply in $ANSWER. Exit 0 = task done.
#                    Prints the reason on failure.
#   solve_ID         reference solution (tests only): makes check_ID pass and
#                    prints the reference answer.
#
# Checks look only at the outcome (files on disk, facts in the reply), never
# at how the agent got there. Answers are matched case-insensitively.
# jq is needed by check_json_fix (dev tool).

# Bump when a prompt, the fixture or a check changes: results of different
# suite versions are not comparable. runs.tsv records it.
# shellcheck disable=SC2034 # read by run-eval.sh
EVAL_SUITE=2

# shellcheck disable=SC2034 # read by run-eval.sh and the tests
EVAL_CASES="write_motd nginx_port k8s_replicas list_units count_500 oom_victim
fstab_var sshd_root chmod_deploy systemd_unit ss_listener disk_full cron_add
dockerfile_base json_fix k8s_env hosts_entry most_errors restore_backup tar_etc"

eval_kind() {
  case $1 in
    (write_motd | systemd_unit) echo write ;;
    (nginx_port | oom_victim | fstab_var | ss_listener | disk_full) echo read ;;
    (k8s_replicas | sshd_root | cron_add | dockerfile_base | json_fix | k8s_env | hosts_entry) echo edit ;;
    (list_units) echo glob ;;
    (count_500 | chmod_deploy | restore_backup | tar_etc) echo bash ;;
    (most_errors) echo multi ;;
    (*) return 1 ;;
  esac
}

# Every workspace path is written ./relative. Suite 1 wrote etc/hosts and the
# like, and models "corrected" that to the host's /etc/hosts: a test of
# path guessing, not of tool calling.
eval_prompt() {
  case $1 in
    (write_motd) echo "Create a file named motd.txt in the current directory containing exactly this line: Maintenance window: Sunday 02:00 UTC" ;;
    (nginx_port) echo "Which port does the server block in ./etc/nginx/sites-enabled/app.conf listen on?" ;;
    (k8s_replicas) echo "Scale the deployment in ./k8s/deployment.yaml to 3 replicas by editing the file." ;;
    (list_units) echo "Which systemd service units are defined under ./etc/systemd/system? List the .service file names." ;;
    (count_500) echo "How many requests in ./logs/access.log returned HTTP status 500? Answer with the number." ;;
    (oom_victim) echo "According to ./logs/kern.log, which process did the OOM killer kill? Give the process name and its PID." ;;
    (fstab_var) echo "In ./etc/fstab, which filesystem type is used for the /var mount?" ;;
    (sshd_root) echo "Harden ./etc/ssh/sshd_config: disable root login over SSH. Change only that setting." ;;
    (chmod_deploy) echo "Make the script ./deploy.sh executable." ;;
    (systemd_unit) echo "Write a systemd service unit file named backup.service in the current directory. It should run /usr/local/bin/backup.sh as the user backup, with Type=oneshot." ;;
    (ss_listener) echo "./diag/ss-tlnp.txt holds the output of ss -tlnp from a server. Which process is listening on port 5432?" ;;
    (disk_full) echo "./diag/df-h.txt holds df -h output from a server. Which mount point is almost full?" ;;
    (cron_add) echo "Add an entry to ./etc/crontab that runs /usr/local/bin/backup.sh as root every day at 03:30. Keep the existing entries." ;;
    (dockerfile_base) echo "Update the base image in ./Dockerfile from ubuntu:20.04 to ubuntu:24.04." ;;
    (json_fix) echo "./config/app.json fails to parse. Fix the JSON syntax error without changing any values." ;;
    (k8s_env) echo "Add an environment variable LOG_LEVEL with the value debug to the container in ./k8s/deployment.yaml." ;;
    (hosts_entry) echo "Add an entry to ./etc/hosts that maps db.internal to 10.0.0.5." ;;
    (most_errors) echo "Find which file in ./logs/ named app-*.log has the most lines containing ERROR, and write just that file name into ./answer.txt." ;;
    (restore_backup) echo "./etc/nginx/nginx.conf was corrupted. Restore it from the backup ./etc/nginx/nginx.conf.bak." ;;
    (tar_etc) echo "Create a gzip-compressed tar archive of the ./etc directory at ./backups/etc.tar.gz." ;;
    (*) return 1 ;;
  esac
}

# --- fixture ----------------------------------------------------------------

# eval_fixture - create the server snapshot in the current directory.
eval_fixture() {
  mkdir -p etc/nginx/sites-enabled etc/ssh etc/systemd/system logs k8s diag config || return 1

  cat >etc/hosts <<'EOF'
127.0.0.1   localhost
127.0.1.1   web-01
::1         localhost ip6-localhost ip6-loopback
10.0.0.4    cache.internal
EOF

  cat >etc/fstab <<'EOF'
# /etc/fstab: static file system information.
# <file system>                            <mount point>  <type>  <options>          <dump> <pass>
UUID=3f1c2a4e-7d1b-4c55-9e0a-2b8f61d4c901  /              ext4    defaults,noatime   0      1
UUID=9A2B-41C7                             /boot/efi      vfat    umask=0077         0      2
UUID=77d0e5b2-0c3f-4a8e-b1d9-5e6f7a8b9c0d  /var           xfs     defaults,nodev     0      2
UUID=1c3e5a7b-9d2f-4e6a-8b0c-1d2e3f4a5b6c  /home          ext4    defaults           0      2
/swapfile                                  none           swap    sw                 0      0
EOF

  cat >etc/crontab <<'EOF'
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# m h dom mon dow user  command
17 *    * * *   root    cd / && run-parts --report /etc/cron.hourly
25 6    * * *   root    test -x /usr/sbin/anacron || ( cd / && run-parts --report /etc/cron.daily )
EOF

  cat >etc/ssh/sshd_config <<'EOF'
# This is the sshd server system-wide configuration file.
Include /etc/ssh/sshd_config.d/*.conf

Port 22
#AddressFamily any
#ListenAddress 0.0.0.0

#LoginGraceTime 2m
PermitRootLogin yes
#StrictModes yes
#MaxAuthTries 6

PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

  cat >etc/nginx/sites-enabled/app.conf <<'EOF'
server {
    listen 8443 ssl;
    server_name billing.example.internal;

    ssl_certificate     /etc/ssl/billing.crt;
    ssl_certificate_key /etc/ssl/billing.key;

    location / {
        proxy_pass http://127.0.0.1:8081;
        proxy_set_header Host $host;
    }
}
EOF

  cat >etc/nginx/nginx.conf.bak <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;

events {
    worker_connections 768;
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
    gzip on;
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
  # The corrupted copy: truncated mid-block, with a run of NUL-like garbage.
  printf 'user www-data;\nworker_processes auto;\npid /run/nginx.pid;\n\nevents {\n    worker_conn@@@@@@@@@@@@@@@@\n' >etc/nginx/nginx.conf

  local u
  for u in api worker metrics-exporter; do
    cat >"etc/systemd/system/$u.service" <<EOF
[Unit]
Description=$u
After=network-online.target

[Service]
ExecStart=/opt/$u/bin/$u
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  done
  printf '[Unit]\nDescription=old worker (disabled)\n' >etc/systemd/system/old-worker.service.bak
  printf '[Unit]\nDescription=cleanup\n\n[Timer]\nOnCalendar=daily\n\n[Install]\nWantedBy=timers.target\n' >etc/systemd/system/cleanup.timer
  printf '[Unit]\nDescription=api socket\n\n[Socket]\nListenStream=8080\n\n[Install]\nWantedBy=sockets.target\n' >etc/systemd/system/api.socket

  # 60 access-log lines; exactly 7 have status 500. No other field contains "500".
  local i status path size
  : >logs/access.log
  i=1
  while [ $i -le 60 ]; do
    case $i in
      (4 | 13 | 22 | 29 | 41 | 47 | 58) status=500 ;;
      (9 | 35) status=502 ;;
      (17 | 52) status=404 ;;
      (26) status=503 ;;
      (*) status=200 ;;
    esac
    case $((i % 4)) in (0) path=/api/orders ;; (1) path=/api/invoices ;; (2) path=/healthz ;; (*) path=/api/customers ;; esac
    size=$((i * 37 + 113))
    printf '10.0.%d.%d - - [06/Oct/2026:10:%02d:%02d +0000] "GET %s HTTP/1.1" %d %d "-" "curl/8.5.0"\n' \
      $((i % 3)) $((10 + i)) $((i / 2)) $(((i * 7) % 60)) "$path" "$status" "$size" >>logs/access.log
    i=$((i + 1))
  done

  cat >logs/kern.log <<'EOF'
Oct  6 03:12:01 web-01 kernel: [812345.100201] e1000e 0000:00:1f.6 eno1: NIC Link is Up 1000 Mbps Full Duplex
Oct  6 03:12:41 web-01 kernel: [812385.552910] postgres invoked oom-killer: gfp_mask=0x140cca(GFP_HIGHUSER_MOVABLE|__GFP_COMP), order=0, oom_score_adj=0
Oct  6 03:12:41 web-01 kernel: [812385.552931] CPU: 2 PID: 1104 Comm: postgres Not tainted 6.8.0-45-generic #45-Ubuntu
Oct  6 03:12:41 web-01 kernel: [812385.553402] Mem-Info:
Oct  6 03:12:41 web-01 kernel: [812385.553410] active_anon:1532101 inactive_anon:240112 isolated_anon:0
Oct  6 03:12:41 web-01 kernel: [812385.554777] oom-kill:constraint=CONSTRAINT_NONE,nodemask=(null),cpuset=/,mems_allowed=0,global_oom,task_memcg=/system.slice/billing.service,task=java,pid=4242,uid=1001
Oct  6 03:12:41 web-01 kernel: [812385.554801] Out of memory: Killed process 4242 (java) total-vm:8123456kB, anon-rss:6234567kB, file-rss:0kB, shmem-rss:0kB, UID:1001 pgtables:13000kB oom_score_adj:0
Oct  6 03:12:42 web-01 kernel: [812386.101112] oom_reaper: reaped process 4242 (java), now anon-rss:0kB, file-rss:0kB, shmem-rss:0kB
Oct  6 03:15:09 web-01 kernel: [812533.000017] audit: type=1400 audit(1791249309.123:88): apparmor="STATUS" operation="profile_replace" name="nginx"
EOF

  # ERROR lines per file: api 3, billing 11, auth 5, web 0.
  local f n k
  for f in api:3 billing:11 auth:5 web:0; do
    n=${f#*:} f=logs/app-${f%%:*}.log
    : >"$f"
    k=1
    while [ $k -le 20 ]; do
      printf '2026-10-06T03:%02d:00Z INFO request served path=/x latency_ms=%d\n' "$k" $((k * 3)) >>"$f"
      if [ $k -le "$n" ]; then printf '2026-10-06T03:%02d:30Z ERROR upstream timeout after 30s\n' "$k" >>"$f"; fi
      if [ $k -le 2 ]; then printf '2026-10-06T03:%02d:40Z WARN slow query\n' "$k" >>"$f"; fi
      k=$((k + 1))
    done
  done

  cat >k8s/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: billing-api
  labels:
    app: billing-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: billing-api
  template:
    metadata:
      labels:
        app: billing-api
    spec:
      containers:
        - name: billing-api
          image: registry.internal/billing-api:1.8.2
          ports:
            - containerPort: 8081
          env:
            - name: PORT
              value: "8081"
EOF

  cat >diag/ss-tlnp.txt <<'EOF'
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
LISTEN 0      4096   127.0.0.53%lo:53         0.0.0.0:*     users:(("systemd-resolve",pid=612,fd=14))
LISTEN 0      128          0.0.0.0:22         0.0.0.0:*     users:(("sshd",pid=1021,fd=3))
LISTEN 0      511          0.0.0.0:443        0.0.0.0:*     users:(("nginx",pid=1290,fd=7),("nginx",pid=1288,fd=7))
LISTEN 0      128        127.0.0.1:5432       0.0.0.0:*     users:(("pgbouncer",pid=1187,fd=9))
LISTEN 0      244        127.0.0.1:5433       0.0.0.0:*     users:(("postgres",pid=1104,fd=6))
LISTEN 0      4096       127.0.0.1:6379       0.0.0.0:*     users:(("redis-server",pid=998,fd=6))
LISTEN 0      4096               *:9100             *:*     users:(("node_exporter",pid=877,fd=3))
EOF

  cat >diag/df-h.txt <<'EOF'
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p2  100G   41G   54G  44% /
tmpfs           7.8G     0  7.8G   0% /dev/shm
/dev/nvme0n1p1  511M  6.1M  505M   2% /boot/efi
/dev/nvme1n1p1  500G  485G   15G  97% /var/lib/docker
/dev/nvme0n1p3  200G  120G   80G  60% /home
EOF

  cat >config/app.json <<'EOF'
{
  "name": "billing-api",
  "port": 8081,
  "db": {
    "host": "db.internal",
    "pool": 10,
  },
  "features": ["audit", "metrics"]
}
EOF

  cat >Dockerfile <<'EOF'
FROM ubuntu:20.04
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*
COPY app /opt/app
CMD ["/opt/app/run"]
EOF

  cat >deploy.sh <<'EOF'
#!/usr/bin/env bash
# Roll out the current release.
set -eu
echo "deploying $(cat VERSION 2>/dev/null || echo dev)"
EOF
  chmod 644 deploy.sh
}

# --- check helpers ----------------------------------------------------------

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# answer_has WORD... - every WORD occurs in $ANSWER (case-insensitive).
answer_has() {
  local a w
  a=$(lower "${ANSWER:-}")
  for w in "$@"; do
    case $a in
      (*"$(lower "$w")"*) ;;
      (*) echo "reply does not mention '$w'"; return 1 ;;
    esac
  done
}

# answer_has_number N - $ANSWER contains N as a whole number.
answer_has_number() {
  local re="(^|[^0-9])$1([^0-9]|$)"
  [[ ${ANSWER:-} =~ $re ]] || { echo "reply does not contain the number $1"; return 1; }
}

# has_line FILE REGEX - some line of FILE matches the extended REGEX.
has_line() {
  [ -f "$1" ] || { echo "$1 is missing"; return 1; }
  grep -Eq -- "$2" "$1" || { echo "$1 has no line matching /$2/"; return 1; }
}

# lacks_line FILE REGEX
lacks_line() {
  ! grep -Eq -- "$2" "$1" 2>/dev/null || { echo "$1 still has a line matching /$2/"; return 1; }
}

# keeps_line FILE LINE - FILE still contains LINE exactly.
keeps_line() {
  grep -Fxq -- "$2" "$1" 2>/dev/null || { echo "$1 lost the line: $2"; return 1; }
}

# --- checks and reference solutions -----------------------------------------

check_write_motd() {
  [ -f motd.txt ] || { echo "motd.txt was not created"; return 1; }
  local c
  c=$(cat motd.txt)
  c=${c%"${c##*[![:space:]]}"}
  [ "$c" = "Maintenance window: Sunday 02:00 UTC" ] || { echo "motd.txt holds: $c"; return 1; }
}
solve_write_motd() { echo "Maintenance window: Sunday 02:00 UTC" >motd.txt; echo "Created motd.txt."; }

check_nginx_port() { answer_has_number 8443; }
solve_nginx_port() { echo "It listens on port 8443 (ssl)."; }

check_k8s_replicas() {
  has_line k8s/deployment.yaml '^  replicas: 3[[:space:]]*$' &&
    lacks_line k8s/deployment.yaml 'replicas: 1' &&
    keeps_line k8s/deployment.yaml '          image: registry.internal/billing-api:1.8.2' &&
    keeps_line k8s/deployment.yaml '              value: "8081"'
}
solve_k8s_replicas() {
  local t
  t=$(cat k8s/deployment.yaml)
  printf '%s\n' "${t/replicas: 1/replicas: 3}" >k8s/deployment.yaml
  echo "Set replicas to 3."
}

check_list_units() { answer_has api.service worker.service metrics-exporter.service; }
solve_list_units() { echo "api.service, worker.service, metrics-exporter.service"; }

check_count_500() { answer_has_number 7; }
solve_count_500() { echo "7 requests returned 500."; }

check_oom_victim() { answer_has java && answer_has_number 4242; }
solve_oom_victim() { echo "The OOM killer killed java (PID 4242)."; }

check_fstab_var() { answer_has xfs; }
solve_fstab_var() { echo "/var is xfs."; }

check_sshd_root() {
  has_line etc/ssh/sshd_config '^[[:space:]]*PermitRootLogin[[:space:]]+no[[:space:]]*$' &&
    lacks_line etc/ssh/sshd_config '^[[:space:]]*PermitRootLogin[[:space:]]+yes' &&
    keeps_line etc/ssh/sshd_config 'PasswordAuthentication no' &&
    keeps_line etc/ssh/sshd_config 'PubkeyAuthentication yes' &&
    keeps_line etc/ssh/sshd_config 'Port 22'
}
solve_sshd_root() {
  local t
  t=$(cat etc/ssh/sshd_config)
  printf '%s\n' "${t/PermitRootLogin yes/PermitRootLogin no}" >etc/ssh/sshd_config
  echo "Set PermitRootLogin no."
}

check_chmod_deploy() {
  [ -x deploy.sh ] || { echo "deploy.sh is not executable"; return 1; }
  keeps_line deploy.sh '#!/usr/bin/env bash' && keeps_line deploy.sh 'set -eu'
}
solve_chmod_deploy() { chmod +x deploy.sh; echo "Done."; }

check_systemd_unit() {
  local f=backup.service
  has_line $f '^[[:space:]]*\[Service\][[:space:]]*$' &&
    has_line $f '^[[:space:]]*ExecStart[[:space:]]*=[[:space:]]*/usr/local/bin/backup\.sh' &&
    has_line $f '^[[:space:]]*User[[:space:]]*=[[:space:]]*backup[[:space:]]*$' &&
    has_line $f '^[[:space:]]*Type[[:space:]]*=[[:space:]]*oneshot[[:space:]]*$'
}
solve_systemd_unit() {
  printf '[Unit]\nDescription=Backup\n\n[Service]\nType=oneshot\nUser=backup\nExecStart=/usr/local/bin/backup.sh\n' >backup.service
  echo "Wrote backup.service."
}

check_ss_listener() { answer_has pgbouncer; }
solve_ss_listener() { echo "pgbouncer (pid 1187) listens on 127.0.0.1:5432."; }

check_disk_full() { answer_has /var/lib/docker; }
solve_disk_full() { echo "/var/lib/docker is at 97%."; }

check_cron_add() {
  has_line etc/crontab '^30[[:space:]]+0?3[[:space:]]+\*[[:space:]]+\*[[:space:]]+\*[[:space:]]+root[[:space:]]+/usr/local/bin/backup\.sh' &&
    keeps_line etc/crontab '17 *    * * *   root    cd / && run-parts --report /etc/cron.hourly' &&
    keeps_line etc/crontab '25 6    * * *   root    test -x /usr/sbin/anacron || ( cd / && run-parts --report /etc/cron.daily )'
}
solve_cron_add() { printf '30 3    * * *   root    /usr/local/bin/backup.sh\n' >>etc/crontab; echo "Added."; }

check_dockerfile_base() {
  has_line Dockerfile '^FROM[[:space:]]+ubuntu:24\.04[[:space:]]*$' &&
    lacks_line Dockerfile '20\.04' &&
    keeps_line Dockerfile 'COPY app /opt/app' &&
    keeps_line Dockerfile 'CMD ["/opt/app/run"]' &&
    keeps_line Dockerfile 'RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*'
}
solve_dockerfile_base() {
  local t
  t=$(cat Dockerfile)
  printf '%s\n' "${t/ubuntu:20.04/ubuntu:24.04}" >Dockerfile
  echo "Updated."
}

check_json_fix() {
  local got want='{"name":"billing-api","port":8081,"db":{"host":"db.internal","pool":10},"features":["audit","metrics"]}'
  got=$(jq -c . config/app.json 2>&1) || { echo "config/app.json still does not parse: $got"; return 1; }
  [ "$got" = "$want" ] || { echo "values changed: $got"; return 1; }
}
solve_json_fix() {
  local t
  t=$(cat config/app.json)
  printf '%s\n' "${t/\"pool\": 10,/\"pool\": 10}" >config/app.json
  echo "Removed the trailing comma."
}

check_k8s_env() {
  local f=k8s/deployment.yaml a b
  has_line $f '^[[:space:]]*- name:[[:space:]]*"?LOG_LEVEL"?[[:space:]]*$' &&
    has_line $f '^[[:space:]]*value:[[:space:]]*"?debug"?[[:space:]]*$' &&
    keeps_line $f '            - name: PORT' &&
    keeps_line $f '  replicas: 1' || return 1
  # The new entry must sit in the same list as PORT (same indentation).
  a=$(grep -E -- '- name:[[:space:]]*"?LOG_LEVEL' $f | head -n 1)
  b='            - name: PORT'
  [ "${a%%-*}" = "${b%%-*}" ] || { echo "LOG_LEVEL is not in the container's env list: [$a]"; return 1; }
}
solve_k8s_env() {
  printf '            - name: LOG_LEVEL\n              value: debug\n' >>k8s/deployment.yaml
  echo "Added LOG_LEVEL=debug."
}

check_hosts_entry() {
  has_line etc/hosts '^10\.0\.0\.5[[:space:]]+([^#]*[[:space:]])?db\.internal([[:space:]]|$)' &&
    keeps_line etc/hosts '127.0.0.1   localhost' &&
    keeps_line etc/hosts '10.0.0.4    cache.internal'
}
solve_hosts_entry() { printf '10.0.0.5    db.internal\n' >>etc/hosts; echo "Added."; }

check_most_errors() {
  [ -f answer.txt ] || { echo "answer.txt was not created"; return 1; }
  local c
  c=$(cat answer.txt)
  case $c in
    (*app-billing.log*) ;;
    (*) echo "answer.txt holds: $c"; return 1 ;;
  esac
  case $c in
    (*app-api.log* | *app-auth.log* | *app-web.log*) echo "answer.txt names more than one file: $c"; return 1 ;;
  esac
}
solve_most_errors() { echo app-billing.log >answer.txt; echo "app-billing.log (11 ERROR lines)."; }

check_restore_backup() {
  [ -f etc/nginx/nginx.conf.bak ] || { echo "the backup is gone"; return 1; }
  cmp -s etc/nginx/nginx.conf etc/nginx/nginx.conf.bak || { echo "nginx.conf differs from the backup"; return 1; }
}
solve_restore_backup() { cp etc/nginx/nginx.conf.bak etc/nginx/nginx.conf; echo "Restored."; }

# The etc tree with or without its etc/ prefix: `tar -czf … etc` and
# `tar -czf … -C etc .` are both an archive of the directory.
check_tar_etc() {
  local list f
  [ -f backups/etc.tar.gz ] || { echo "backups/etc.tar.gz was not created"; return 1; }
  list=$(tar -tzf backups/etc.tar.gz 2>&1) || { echo "not a gzip tar archive: $list"; return 1; }
  for f in hosts ssh/sshd_config; do
    printf '%s\n' "$list" | grep -Eqx "(\./)?(etc/)?$f" ||
      { echo "archive does not contain etc/$f"; return 1; }
  done
}
solve_tar_etc() { mkdir -p backups && tar -czf backups/etc.tar.gz etc; echo "Created."; }
