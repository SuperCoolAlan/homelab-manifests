# Twingate Connector Helm Chart

[Twingate](https://www.twingate.com/) is remote access for the modern world.

## Introduction

This chart bootstraps a [Twingate Connector](https://hub.docker.com/r/twingate/connector) deployment on a [Kubernetes](http://kubernetes.io) cluster using the [Helm](https://helm.sh) package manager.

## Prerequisites

- Kubernetes 1.12+
- Helm 2.0+

## Installing the Chart

To install the chart with the release name `my-release`:

```shell
$ helm repo add twingate https://twingate.github.io/helm-charts
$ helm upgrade --install my-release twingate/connector -n [namespace] \
    --set connector.network=[network] \
    --set connector.accessToken=[accessToken] \
    --set connector.refreshToken=[refreshToken]
```

These commands deploy Twingate on the Kubernetes cluster in the default configuration. The [Parameters](#parameters) section lists the parameters that can be configured during installation.

> **Tip**: List all releases using `helm ls -n [namespace]`

### Using an Existing Secret for Access/Refresh Tokens

Rather than passing in `connector.accessToken` and `connector.refreshToken`, you may provide the name of an existing secret that contains those values via `connector.existingSecret`.

Example secret:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-secret
type: Opaque
data:
  TWINGATE_ACCESS_TOKEN: "your access token base64 encoded"
  TWINGATE_REFRESH_TOKEN: "your refresh token base64 encoded"
```

## Uninstalling the Chart

To uninstall/delete the `my-release` deployment:

```shell
$ helm del my-release -n [namespace]
```

The command removes all the Kubernetes components associated with the chart and deletes the release.

## Parameters

The following table lists the configurable parameters of the Twingate chart and their default values.

| Parameter                               | Description                                                                                                                 | Default                                                 |
|-----------------------------------------|-----------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------|
| `connector.network`                     | The Twingate network name, eg. acme (required)                                                                              |                                                         |
| `connector.url`                         | The Twingate service domain                                                                                                 | `twingate.com`                                          |
| `connector.accessToken`                 | Access Token (required unless `connector.existingSecret` is specified)                                                      |                                                         |
| `connector.refreshToken`                | Refresh Token (required unless `connector.existingSecret` is specified)                                                     |                                                         |
| `connector.existingSecret`              | The name of an existing secret to use for the access and refresh tokens                                                     |                                                         |
| `connector.logLevel`                    | Log Level - supported : [error, warning, info, debug]                                                                       | `error`                                                 |
| `connector.logAnalytics`                | Real-time connection logs (see https://www.twingate.com/docs/connector-real-time-logs) - supported : [v1, v2]               |                                                         |
| `connector.dnsServer`                   | Custom DNS server                                                                                                           |                                                         |
| `image.repository`                      | Twingate image name                                                                                                         | `twingate/connector`                                    |
| `image.tag`                             | Twingate image tag                                                                                                          | `latest`                                                |
| `image.pullPolicy`                      | Twingate image pull policy                                                                                                  | `Always`                                                |
| `image.imagePullSecrets`                | Specify docker-registry secret names as an array                                                                            | `[]` (does not add image pull secrets to deployed pods) |
| `nameOverride`                          | String to partially override twingate.fullname template                                                                     | `nil`                                                   |
| `fullnameOverride`                      | String to fully override twingate.fullname template                                                                         | `nil`                                                   |
| `icmpSupport.enabled`                   | Enable the ICMP securityContext. See more in values file                                                                    | `false`                                                 |
| `affinity`                              | Map of node/pod affinities                                                                                                  | `{}` (The value is evaluated as a template)             |
| `priorityClassName`                     | String to added priorityClass for pod assignment                                                                            | `nil`                                                   |
| `nodeSelector`                          | node labels for pod assignment                                                                                              | `{}` (The value is evaluated as a template)             |
| `tolerations`                           | Tolerations for pod assignment                                                                                              | `[]` (The value is evaluated as a template)             |
| `topologySpreadConstraints`             | Topology spread constraints for pod assignment                                                                              | `[]` (The value is evaluated as a template)             |
| `resources`                             | Resource requests and limits                                                                                                | `{}` (The value is evaluated as a template)             |
| `additionalLabels`                      | Additional labels for the deployment                                                                                        | `{}` (The value is evaluated as a template)             |
| `podAnnotations`                        | Map of annotations to add to pods                                                                                           | `{}`                                                    |
| `podDnsPolicy`                          | Optional pod [DNS policy](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/#pods-dns-policy)         |                                                         |
| `podDnsConfig`                          | Optional pod [DNS configurations](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/#pods-dns-config) |                                                         |
| `env`                                   | Additional environment variables for the deployment                                                                         | `{}` (The value is evaluated as a template)             |
| `hostNetwork`                           | Enable/Disable host network for the pod                                                                                     | `false` (Disabled by default)                           |
| `securityContext`                       | Security context for the Connector container                                                                                | {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}, "readOnlyRootFilesystem": true, "runAsNonRoot": true, "runAsUser": 65532, "seccompProfile": {"type": "RuntimeDefault"}} |
| `podSecurityContext`                    | Security context for the Connector pod                                                                                      | `{}` (Disabled by default)                           |
| `readinessProbe`                        | Pod's readiness probe                                                                                                       | default healthcheck - `connectorctl health`             |
| `livenessProbe`                         | Pod's liveness probe                                                                                                        | default healthcheck - `connectorctl health`             |
