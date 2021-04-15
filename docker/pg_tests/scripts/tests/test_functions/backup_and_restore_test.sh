#!/bin/sh
set -e

pgstart() {
  pg_ctl start
  i=0
  while /bin/true; do
      sleep 0.1
      pg_isready && break
      i=$(expr $i + 1)
      [ "$i" -ge 10 ] && break
  done
}

gendata() {
  echo "create tablespace tbs location '$PGTBS';"
  echo 'create table t1 (id int, txt varchar) tablespace tbs;'
  echo 'INSERT INTO T1 Values'
  i=0
  while /bin/true; do
    NEW_UUID=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 32 | head -n 1)
    echo -n "(${i}, '${NEW_UUID}')"
    i=$(expr $i + 1)
    [ "$i" -ge 100 ] && break
    echo ","
  done
  echo ";"
}

recovery_conf() {
  echo "recovery_target_action=promote"
  echo "restore_command='$PWD/wal-g wal-fetch %f %p'"
}

backup_and_restore_test() {
  TMP_CONFIG=$1
  TMPDIR=${TMPDIR:-$(mktemp -d)}
  echo "All data can be found in $TMPDIR"
  PGTBS="$(dirname "${PGDATA}")/tbs"
  export PGTBS
  mkdir "${PGTBS}"

  echo Initializing source
  initdb
  PGVERSION=$(cat "${PGDATA}/PG_VERSION")
  echo "local replication postgres trust" >> "$PGDATA/pg_hba.conf"
  echo "archive_command = '$PWD/wal-g --config=${TMP_CONFIG} wal-push %p'
  archive_mode = on
  logging_collector=on
  wal_level=replica
  max_wal_senders=5" >> "$PGDATA/postgresql.conf"

  echo Starting source
  pgstart

  echo Loading random data to source
  gendata | psql | sed 's/^/  /'

  echo "Dumping source"
  pg_dump > "${TMPDIR}/srcdump.sql"

  echo Backup source
  wal-g --config=${TMP_CONFIG} backup-push

  echo transporting last wal files
  if awk 'BEGIN {exit !('"$PGVERSION"' >= 10)}'; then
    echo 'select pg_switch_wal();' | psql
  else
    echo 'select pg_switch_xlog();' | psql
  fi

  echo Stopping source
  pg_ctl stop
  rm -rf "${PGTBS}"/*
  rm -rf "${PGDATA}"

  echo Restore destination
  BACKUP=$(./wal-g --config=${TMP_CONFIG} backup-list | sed -n '2{s/ .*//;p}')
  wal-g --config=${TMP_CONFIG} backup-fetch "$PGDATA" "$BACKUP"
  chmod 0700 "$PGDATA"
  if awk 'BEGIN {exit !('"$PGVERSION"' >= 12)}'; then
    touch "$PGDATA/recovery.signal"
    recovery_conf >> "$PGDATA/postgresql.conf"
  else
    recovery_conf > "$PGDATA/recovery.conf"
  fi

  echo Starting destination
  pgstart

  echo "Dumping destination"
  pg_dump > "${TMPDIR}/dstdump.sql"

  echo Stopping destination
  pg_ctl stop

  echo Comparing source and destination
  if diff "${TMPDIR}"/*dump.sql; then
    echo OK
  else
    echo Ouch
    return 1
  fi
}

PGBIN=$(ls -d /usr/lib/postgresql/*/bin | xargs -n 1)
export PATH=$PGBIN:$PATH
