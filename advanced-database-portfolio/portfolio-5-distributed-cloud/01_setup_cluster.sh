#!/usr/bin/env bash
# =====================================================================
# MIT 8103 - Portfolio 5 : build a 5-node PostgreSQL 16 lab on one host
#
#   node            port  role
#   primary         5432  read/write primary (the voltgrid DB from Portfolios 1-4) + shard coordinator (postgres_fdw)
#   replica1        5433  streaming-replication hot standby (used for sync commit and failover tests)
#   replica_delayed 5436  streaming standby that APPLIES WAL 30 s LATE (recovery_min_apply_delay) -
#                         a safety net against human error, not against hardware failure
#   shard_a         5434  meter readings with hash(meter_no) % 2 = 0
#   shard_b         5435  meter readings with hash(meter_no) % 2 = 1
#
# Each node is a separate postgres server process with its own data directory, WAL and port -
# the same as separate VMs, minus network latency.     Run as root:  bash 01_setup_cluster.sh
# =====================================================================
set -euo pipefail
PGBIN=/usr/lib/postgresql/16/bin
BASE=/home/claude/pg
as_pg() { su postgres -c "$*"; }

echo "== primary: replication settings, restart"
as_pg "$PGBIN/pg_ctl -D $BASE/primary -o \"-p 5432 -c wal_level=replica -c max_replication_slots=10 -c max_wal_senders=10 \
  -c wal_keep_size=256MB -c hot_standby=on -c max_prepared_transactions=20 -c listen_addresses=localhost\" -l $BASE/primary.log -w restart"
for SLOT in replica1_slot replica_delayed_slot; do
  psql -h localhost -p 5432 -U postgres -qc "SELECT pg_drop_replication_slot('$SLOT')" 2>/dev/null || true
  psql -h localhost -p 5432 -U postgres -qAtc "SELECT 'slot ' || slot_name FROM pg_create_physical_replication_slot('$SLOT')"
done

make_standby() {   # name port slot extra-config
  local NAME=$1 PORT=$2 SLOT=$3 EXTRA=$4
  echo "== $NAME: pg_basebackup -R from primary (port $PORT)"
  as_pg "$PGBIN/pg_ctl -D $BASE/$NAME -m fast stop" 2>/dev/null || true
  rm -rf $BASE/$NAME
  as_pg "$PGBIN/pg_basebackup -h localhost -p 5432 -U postgres -D $BASE/$NAME -X stream -S $SLOT -R --checkpoint=fast"
  echo "cluster_name = '$NAME'" >> $BASE/$NAME/postgresql.auto.conf
  echo "max_prepared_transactions = 20   # must be >= primary's value on a standby" >> $BASE/$NAME/postgresql.auto.conf
  [ -n "$EXTRA" ] && echo "$EXTRA" >> $BASE/$NAME/postgresql.auto.conf
  sed -i "s/primary_conninfo = '/primary_conninfo = 'application_name=$NAME /" $BASE/$NAME/postgresql.auto.conf
  as_pg "$PGBIN/pg_ctl -D $BASE/$NAME -o '-p $PORT' -l $BASE/$NAME.log -w start"
}
make_standby replica1        5433 replica1_slot        ""
make_standby replica_delayed 5436 replica_delayed_slot "recovery_min_apply_delay = '30s'"

for SHARD in shard_a:5434 shard_b:5435; do
  NAME=${SHARD%%:*}; PORT=${SHARD##*:}
  echo "== $NAME on port $PORT"
  for OLD in shard_south shard_north $NAME; do as_pg "$PGBIN/pg_ctl -D $BASE/$OLD -m fast stop" 2>/dev/null || true; done
  rm -rf $BASE/$NAME
  as_pg "$PGBIN/initdb -D $BASE/$NAME -A trust -U postgres" > /dev/null
  as_pg "$PGBIN/pg_ctl -D $BASE/$NAME -o '-p $PORT -c listen_addresses=localhost' -l $BASE/$NAME.log -w start"
  psql -h localhost -p $PORT -U postgres -qc "CREATE DATABASE voltgrid_shard"
done

echo "== cluster status"
for P in 5432 5433 5436 5434 5435; do
  printf "port %s : " $P
  psql -h localhost -p $P -U postgres -Atc "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby (read-only)' ELSE 'primary (read/write)' END
    || ', apply delay ' || current_setting('recovery_min_apply_delay') || ', ' || current_setting('data_directory')"
done
