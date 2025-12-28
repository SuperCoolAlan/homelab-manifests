# Authentik PostgreSQL Migration to TrueNAS

## Background
Currently running CNPG (CloudNative PostgreSQL) on NFS storage, which is not recommended for PostgreSQL due to file locking and fsync issues. Need to migrate to TrueNAS-hosted PostgreSQL.

## Current State
- CNPG cluster with 2 replicas (`authentik-postgres-1`, `authentik-postgres-2`)
- Storage: NFS at `/mnt/Test Stripe/authentik-cnpg` and `authentik-cnpg2`
- Running for 5+ days without issues, but risk of corruption exists

## Migration Steps

### 1. Set up PostgreSQL on TrueNAS
- [ ] Deploy PostgreSQL app on TrueNAS Scale
- [ ] Configure with appropriate resources
- [ ] Note the connection details (host, port, credentials)
- [ ] Ensure it's accessible from cluster at `truenas.asandov.local:5432`

### 2. Backup Current Authentik Database
```bash
# Get current primary pod
kubectl --kubeconfig ~/.kube/clusters/kubeconfig-talos-dell.yaml get pods -n authentik -l cnpg.io/cluster=authentik-postgres

# Exec into primary and dump
kubectl --kubeconfig ~/.kube/clusters/kubeconfig-talos-dell.yaml exec -n authentik authentik-postgres-1 -- pg_dump -U authentik authentik > authentik-backup.sql
```

### 3. Create Database on TrueNAS
```sql
CREATE USER authentik WITH PASSWORD 'your-password';
CREATE DATABASE authentik OWNER authentik;
```

### 4. Restore to TrueNAS PostgreSQL
```bash
# Copy backup to TrueNAS and restore
psql -h truenas.asandov.local -U authentik -d authentik < authentik-backup.sql
```

### 5. Update Authentik Configuration
Edit `talos/authentik/values.yaml` to use external postgres:
```yaml
postgresql:
  enabled: false

authentik:
  postgresql:
    host: truenas.asandov.local
    port: 5432
    name: authentik
    user: authentik
    password: # from secret
```

### 6. Remove CNPG Resources
- [ ] Delete CNPG cluster from `talos/authentik/resources/cnpg-cluster.yaml`
- [ ] Delete storage from `talos/authentik/resources/cnpg-storage.yaml`
- [ ] Clean up NFS directories on TrueNAS

## Rollback Plan
Keep NFS backups for 7 days after migration. If issues arise, can restore CNPG cluster and point Authentik back.

## Estimated Downtime
~5-10 minutes during cutover
