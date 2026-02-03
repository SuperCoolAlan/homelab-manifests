# Security Scanning Implementation Plan

## Overview
Add security scanning tools to the homelab Kubernetes cluster using the existing Kustomize + Helm pattern.

## Tools to Deploy

### 1. Trivy Operator (Priority: High)
- **Purpose**: In-cluster vulnerability scanning for images, configs, secrets, RBAC
- **Helm repo**: `https://aquasecurity.github.io/helm-charts/`
- **Chart**: `trivy-operator`
- **Namespace**: `trivy-system`

### 2. Falco (Priority: Medium)
- **Purpose**: Runtime threat detection (shell in container, unexpected network, etc.)
- **Helm repo**: `https://falcosecurity.github.io/charts`
- **Chart**: `falco`
- **Namespace**: `falco`

## Directory Structure
```
talos/security/
├── PLAN.md
├── trivy-operator/
│   ├── kustomization.yaml
│   └── values.yaml
└── falco/
    ├── kustomization.yaml
    └── values.yaml
```

## Implementation Steps

### Step 1: Trivy Operator Setup
Create `talos/security/trivy-operator/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

helmCharts:
  - name: trivy-operator
    repo: https://aquasecurity.github.io/helm-charts/
    version: 0.31.0
    releaseName: trivy-operator
    namespace: trivy-system
    valuesFile: values.yaml
    includeCRDs: true
```

Create `talos/security/trivy-operator/values.yaml` with overrides:
- Enable ServiceMonitor for Prometheus integration
- Set scan schedule/concurrency appropriate for homelab
- Configure resource limits (lightweight for single worker node)
- Node affinity for ramhaus

### Step 2: Falco Setup
Create `talos/security/falco/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

helmCharts:
  - name: falco
    repo: https://falcosecurity.github.io/charts
    version: 8.0.0
    releaseName: falco
    namespace: falco
    valuesFile: values.yaml
    includeCRDs: true
```

Create `talos/security/falco/values.yaml` with overrides:
- Use modern eBPF driver (not kernel module) for Talos compatibility
- Enable ServiceMonitor for Prometheus
- Configure alerting (optional: Slack/webhook integration)
- Resource limits appropriate for homelab

### Step 3: ArgoCD Applications
Create ArgoCD Application manifests or add to existing app-of-apps pattern.

### Step 4: Test Deployment
```bash
# Test trivy-operator build
kustomize build --enable-helm talos/security/trivy-operator

# Test falco build
kustomize build --enable-helm talos/security/falco

# Apply via ArgoCD or kubectl
```

## Values to Configure

### Trivy Operator Key Values
```yaml
trivy:
  ignoreUnfixed: true  # ignore vulns with no fix yet

operator:
  scanJobsConcurrentLimit: 2  # limit for single-node cluster

serviceMonitor:
  enabled: true

nodeSelector: {}  # or pin to ramhaus if needed

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    memory: 512Mi
```

### Falco Key Values
```yaml
driver:
  kind: modern_ebpf  # required for Talos (no kernel headers)

falco:
  grpc:
    enabled: true
  grpc_output:
    enabled: true

falcosidekick:
  enabled: false  # enable later if want Slack/webhook alerts

serviceMonitor:
  enabled: true

resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    memory: 512Mi
```

## Notes
- Trivy Operator creates CRDs: VulnerabilityReport, ConfigAuditReport, etc.
- Scan results viewable via `kubectl get vulnerabilityreports -A`
- Falco logs security events, viewable via `kubectl logs -n falco`
- Both integrate with Prometheus/Grafana for dashboards

## Current Status
- [x] Branch created: `feature/security-scanning`
- [x] Directory structure created
- [x] Trivy Operator kustomization.yaml
- [x] Trivy Operator values.yaml
- [x] Falco kustomization.yaml
- [x] Falco values.yaml
- [x] ArgoCD ApplicationSet updated (talos/security/*)
- [ ] Test and deploy
