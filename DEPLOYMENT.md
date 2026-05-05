# Dracolich AKS + ArgoCD + Helm Deployment Guide

End-to-end documentation for deploying the dracolich MTG stack to Azure Kubernetes Service, managed declaratively via Helm + ArgoCD with GitOps.

## Architecture Overview

```
┌───────────────────────────────────────────────────────────────┐
│                  laaasilva (developer)                         │
│  ─────────────                                                 │
│   git push (fix:/feature:/update: prefix)                      │
└────────┬──────────────────────────────────────────────────────┘
         │
         ▼
┌───────────────────────────────────────────────────────────────┐
│   GitHub                                                       │
│  ─────────────                                                 │
│   Per-app repo (e.g. dracolich-mtg-library-api)                │
│   ├─ pr.yml         → mvn test on every PR                     │
│   └─ dev.yml        → on push to dev:                          │
│                       1. semver bump (tag)                     │
│                       2. mvn package + maven-deploy            │
│                       3. docker build + push to Docker Hub     │
│                       4. helm-bump (cross-repo) → dracolich-helm│
│                                                                │
│   dracolich-helm (single ops repo)                             │
│   ├─ lib/                  ← shared Helm library chart         │
│   ├─ services/<svc>/       ← consumer charts                   │
│   ├─ infrastructure/       ← raw manifests (MongoDB)           │
│   └─ argocd/               ← AppProject + ApplicationSet       │
└────────┬──────────────────────────────────────────────────────┘
         │ (ArgoCD watches main branch)
         ▼
┌───────────────────────────────────────────────────────────────┐
│   Azure AKS (westus2, free tier control plane)                 │
│  ─────────────                                                 │
│   ┌─────────────┐  ┌────────────────────────────────────────┐ │
│   │  argocd ns  │  │       dracolich-dev ns                 │ │
│   │  • argocd   │  │  ┌────────────┐  ┌──────────────────┐  │ │
│   │             │  │  │ mongodb    │  │ services         │  │ │
│   │             │  │  │ (mongo:7   │◄─┤ • mtg-library    │  │ │
│   │             │  │  │  + 10Gi    │  │ • user           │  │ │
│   │             │  │  │  PVC)      │  │ • ai             │  │ │
│   │             │  │  └────────────┘  │ • deck-builder   │  │ │
│   │             │  │                  └────────┬─────────┘  │ │
│   │             │  │  ┌─────────────────────┐  │            │ │
│   │             │  │  │ NGINX Ingress       │◄─┘            │ │
│   │             │  │  │ + cert-manager TLS  │               │ │
│   │             │  │  └──────────┬──────────┘               │ │
│   └─────────────┘  └─────────────┼──────────────────────────┘ │
└────────────────────────────────┬─┼────────────────────────────┘
                                 │ │ (Azure Standard LB)
                                 ▼ ▼
                       https://dev.dracolich.app
                       (Cloudflare DNS → AKS LB IP)
```

**Key principles**

- App repos contain only application code; never Helm or k8s manifests
- All deployment config (charts, values, ArgoCD apps) lives in **one repo**: `dracolich-helm`
- All secrets are created out-of-band via `kubectl create secret`, never committed to git
- Single Docker Hub repository (`laaasilva/dracolich`) with service-prefixed tags

---

## Repository Layout — `dracolich-helm`

```
dracolich-helm/
├── lib/                              ← Helm library chart (named templates)
│   ├── Chart.yaml                    type: library
│   └── templates/
│       ├── _helpers.tpl              fullname, labels, selector helpers
│       ├── _deployment.tpl           Deployment template
│       ├── _service.tpl              ClusterIP Service
│       └── _ingress.tpl              Ingress (optional via values)
│
├── services/                         ← One subdir per app
│   ├── mtg-library-api/
│   │   ├── Chart.yaml                depends on file://../../lib
│   │   ├── values.yaml               base defaults
│   │   ├── values-dev.yaml           dev environment overrides
│   │   └── templates/
│   │       └── all.yaml              just `{{ include }}` calls
│   ├── user-api/
│   ├── ai-api/
│   └── deck-builder-api/
│
├── infrastructure/                   ← Raw manifests for stateful infra
│   └── mongodb.yaml                  MongoDB Deployment + PVC + Service
│
└── argocd/                           ← ArgoCD declarative config
    ├── project.yaml                  AppProject `dracolich`
    └── applicationset.yaml           ApplicationSet — spawns 1 Application per service
```

---

## Prerequisites

### Local tooling

```bash
brew install azure-cli kubernetes-cli helm
brew install kubectx mongosh    # optional but recommended
```

### Accounts & credentials

| Resource | Setup |
|---|---|
| Azure subscription | Free Trial or Pay-As-You-Go on personal Microsoft account |
| Cloudflare DNS | Domain registered + DNS managed there |
| GitHub Personal Access Token (PAT) | Fine-grained, scoped to `dracolich-helm` repo, **Contents: write** |
| Docker Hub account | For pulling published images (no push needed locally) |
| Anthropic API key | For ai-api |

### Environment variables (set per terminal session)

```bash
export RG=dracolich-dev
export LOCATION=westus2
export AKS_NAME=dracolich-dev-aks
export NS=dracolich-dev
```

### Per-app-repo GitHub Secrets

| Secret | Value |
|---|---|
| `DOCKERHUB_USERNAME` | `laaasilva` |
| `DOCKERHUB_TOKEN` | Docker Hub access token (R/W) |
| `DRACOLICH_HELM_PAT` | The fine-grained PAT scoped to dracolich-helm repo |

---

## Stage 1 — Azure Provisioning

### One-time subscription setup

```bash
# Register required resource providers (only needed on a fresh subscription)
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.Compute
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.Storage

# Wait until "Registered"
az provider show --namespace Microsoft.ContainerService --query registrationState -o tsv
```

### Resource group + AKS cluster

```bash
az group create --name $RG --location $LOCATION

az aks create \
  --resource-group $RG \
  --name $AKS_NAME \
  --tier free \
  --node-count 1 \
  --node-vm-size Standard_B2s_v2 \
  --generate-ssh-keys \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --network-plugin azure

az aks get-credentials --resource-group $RG --name $AKS_NAME
kubectl get nodes    # expect 1 Ready node
```

> **Note**: Trial subscriptions don't allow original `Standard_B2s` (v1) in many regions. Use `Standard_B2s_v2` (the v2 successor — same shape, ~$30/mo) in `westus2`.

---

## Stage 2 — Cluster Bootstrap

Install the four cluster-wide controllers via Helm.

```bash
# 1. NGINX Ingress (provisions Azure Standard LB with public IP)
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.externalTrafficPolicy=Local

# Capture the LB's external IP for DNS
kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# 2. cert-manager (auto-issues Let's Encrypt TLS certs)
helm upgrade --install cert-manager cert-manager \
  --repo https://charts.jetstack.io \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true

# 3. ArgoCD
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm \
  --namespace argocd --create-namespace
```

### DNS — Cloudflare

| Type | Name | Value | Proxy |
|---|---|---|---|
| A | `dev` | `<LB-IP from above>` | DNS only (gray cloud — keep off until Cloudflare Access is set up) |

Verify: `dig dev.dracolich.app +short`

### ClusterIssuer + namespace

```bash
kubectl create namespace dracolich-dev

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: <your-email>
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
EOF
```

---

## Stage 3 — MongoDB (in-cluster)

The Bitnami MongoDB chart broke for public consumption in 2025. Use a raw manifest instead.

```bash
# 1. Generate root password and store as a Secret
PASS="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"
echo "Save this: $PASS"

kubectl create secret generic mongodb-credentials \
  --namespace=dracolich-dev \
  --from-literal=MONGO_INITDB_ROOT_USERNAME=root \
  --from-literal=MONGO_INITDB_ROOT_PASSWORD="$PASS"

# 2. Apply MongoDB manifest (committed at dracolich-helm/infrastructure/mongodb.yaml)
kubectl apply -f infrastructure/mongodb.yaml
```

The manifest provisions:

- A `Deployment` with `mongo:7`, `replicas: 1`, `strategy: Recreate`
- A 10 Gi `PersistentVolumeClaim` (Azure managed disk)
- A `ClusterIP` `Service` listening on 27017
- Auth env vars from the `mongodb-credentials` Secret

Connection URI: `mongodb://root:<password>@mongodb.dracolich-dev.svc.cluster.local:27017/?authSource=admin`

---

## Stage 4 — ArgoCD Wiring

### One-time ArgoCD configuration

```bash
# Apply the ArgoCD AppProject + ApplicationSet
kubectl apply -f argocd/project.yaml
kubectl apply -f argocd/applicationset.yaml
```

The ApplicationSet generates one Application per service listed in its `generators.list.elements`. Adding a new service = adding one line.

### Access ArgoCD UI

```bash
# Initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d ; echo

# Port-forward
kubectl port-forward -n argocd svc/argocd-server 8080:443
```

Visit `https://localhost:8080`, log in as `admin`. Change the password via the UI, then delete the bootstrap secret:

```bash
kubectl -n argocd delete secret argocd-initial-admin-secret
```

To expose it publicly later: same pattern as service Ingresses, with Cloudflare Access in front.

---

## Stage 5 — Per-Service Deployment

For each service (mtg-library-api, user-api, ai-api, deck-builder-api):

### 1. Create the K8s Secret with required env vars

```bash
URI='mongodb://root:<password>@mongodb.dracolich-dev.svc.cluster.local:27017/?authSource=admin'

# Example: mtg-library-api
kubectl create secret generic mtg-library-secrets \
  --namespace=dracolich-dev \
  --from-literal=MONGODB_URI="$URI" \
  --from-literal=MONGODB_DATABASE=mtg-library \
  --from-literal=CORS_ALLOWED_ORIGINS=https://dev.dracolich.app
```

### 2. (For services with JWT keys) Mount PEM files as volumes

```bash
# user-api JWT private + public keys
kubectl create secret generic user-api-jwt-keys \
  --namespace=dracolich-dev \
  --from-file=ec-private.pem=/path/to/ec-private.pem \
  --from-file=ec-public.pem=/path/to/ec-public.pem

# deck-builder-api JWT public key
kubectl create secret generic deck-builder-api-jwt-keys \
  --namespace=dracolich-dev \
  --from-file=ec-public.pem=/path/to/ec-public.pem
```

### 3. Helm values structure (per service)

`dracolich-helm/services/<svc>/values.yaml`:

```yaml
replicaCount: 1
image:
  repository: laaasilva/dracolich
  tag: <service>-latest
  pullPolicy: IfNotPresent
service:
  appPort: 8080
  managementPort: 7980
probes:
  livenessPath: /actuator/health/liveness
  readinessPath: /actuator/health/readiness
resources:
  requests: { cpu: 100m, memory: 384Mi }
  limits:   { cpu: 500m, memory: 768Mi }
env:
  SPRING_PROFILES_ACTIVE: dev
envFrom:
  - secretRef:
      name: <svc>-secrets
ingress:
  enabled: false  # base default; values-dev.yaml flips to true
```

`dracolich-helm/services/<svc>/values-dev.yaml`:

```yaml
image:
  tag: <service>-latest
ingress:
  enabled: true
  className: nginx
  host: dev.dracolich.app
  path: /dracolich/<service-base-path>
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  tls:
    - hosts: [dev.dracolich.app]
      secretName: dev-dracolich-app-tls
```

### 4. ArgoCD picks it up automatically

After commit + push to `dracolich-helm`, the ApplicationSet sees the change within ~3 min (or force a Sync via UI).

---

## CI/CD Flow

```
┌──────────────────────────────────────────────────────────────┐
│ Developer commits to fix/feature/update PR                    │
│   ↓                                                            │
│ pr.yml runs (mvn test) — must pass before merge                │
│   ↓                                                            │
│ Squash-merge to dev branch                                     │
│   ↓                                                            │
│ dev.yml fires:                                                 │
│   1. semver bump (based on commit prefix)                      │
│      - feature: → major bump                                   │
│      - update:  → minor bump                                   │
│      - fix:     → patch bump                                   │
│   2. mvn package + deploy to GitHub Packages                   │
│   3. docker build + push to laaasilva/dracolich:<svc>-X.Y.Z    │
│   4. helm-bump:                                                │
│      - clones dracolich-helm via DRACOLICH_HELM_PAT            │
│      - yq edits services/<svc>/values-dev.yaml image.tag       │
│      - commits + pushes back to main                           │
│   ↓                                                            │
│ ArgoCD reconciles dracolich-helm/main                          │
│   ↓                                                            │
│ Rolling deploy → new pod online in ~2 min                      │
└──────────────────────────────────────────────────────────────┘
```

### Branch protection ruleset (per app repo, applied to dev + main)

- Require pull request before merging (Required approvals: 0 for solo dev)
- Require linear history
- Allowed merge methods: **squash only**
- Require status checks: PR Validation / `test`
- Block force pushes
- Restrict deletions
- Bypass list: empty
- Required signatures: **off** (CI commits aren't GPG-signed)

### Commit prefix convention

| Prefix | Bumps | Use for |
|---|---|---|
| `feature:` | major | New features, breaking changes |
| `update:` | minor | Non-breaking enhancements |
| `fix:` | patch | Bug fixes |
| (other) | nothing | No release happens; CI runs but skips publish |

---

## Operational Runbook

### Stop / start the cluster (save money overnight)

```bash
# Stop (~3-5 min). While stopped: ~$5/mo (LB IP + PVC).
az aks stop --resource-group $RG --name $AKS_NAME

# Start (~5-7 min before pods are responsive)
az aks start --resource-group $RG --name $AKS_NAME
```

State preserved through stop: PVC data, Secrets, ArgoCD state, LB IP, TLS cert.

### Force ArgoCD sync

```bash
# Single app
kubectl -n argocd patch app <app-name> --type merge -p '{"operation":{"sync":{}}}'

# All apps
for app in mtg-library-api user-api ai-api deck-builder-api; do
  kubectl -n argocd patch app $app --type merge -p '{"operation":{"sync":{}}}'
done
```

### Restart a pod (after secret update, etc.)

```bash
kubectl rollout restart deployment/<svc-name> -n dracolich-dev
```

### Update a Secret idempotently

```bash
kubectl create secret generic <name> \
  --namespace=dracolich-dev \
  --from-literal=KEY=value \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deployment/<svc> -n dracolich-dev
```

### Get the MongoDB password back

```bash
kubectl get secret mongodb-credentials -n dracolich-dev \
  -o jsonpath='{.data.MONGO_INITDB_ROOT_PASSWORD}' | base64 -d ; echo
```

### Port-forward to MongoDB

```bash
kubectl port-forward -n dracolich-dev svc/mongodb 27017:27017
# Connect: mongodb://root:<password>@localhost:27017/?authSource=admin
```

### Tail service logs

```bash
kubectl logs -n dracolich-dev -l app.kubernetes.io/name=<svc> -f --tail=100
```

### Verify cluster + service health

```bash
kubectl get pods -n dracolich-dev
kubectl get applications -n argocd
kubectl get certificate -n dracolich-dev
```

---

## Troubleshooting

### Already-faced issues

#### 1. `BadRequest: VM size of Standard_B2s is not allowed in your subscription`

**Cause**: Trial subscriptions restrict old VM SKU families.

**Fix**: Use `Standard_B2s_v2` in `westus2`. Other regions (Brazil South, East US) don't allow B-series at all on trial subs.

#### 2. `MissingSubscriptionRegistration: subscription is not registered to use namespace 'Microsoft.ContainerService'`

**Cause**: Fresh Azure subscription needs resource providers explicitly registered.

**Fix**: `az provider register --namespace Microsoft.ContainerService` (also Compute, Network, Storage).

#### 3. AKS `Pending` pods, `Too many pods` event

**Cause**: Azure CNI default pod limit is 30/node. With ArgoCD + ingress + cert-manager + 4 service pods + retry replicas, easy to hit.

**Fix**: Scale node pool to 2 nodes:

```bash
az aks nodepool scale --resource-group $RG --cluster-name $AKS_NAME --name nodepool1 --node-count 2
```

#### 4. Bitnami chart `Error: invalid_reference: invalid tag`

**Cause**: Bitnami changed image distribution in 2025; default image refs no longer resolve cleanly.

**Fix**: Skip the chart for stateful infra. Write raw manifests (`infrastructure/mongodb.yaml` pattern) — ~50 lines, zero chart-drift risk.

#### 5. Spring app fails to start: `Could not resolve placeholder 'X'`

**Cause**: An env var referenced in `application.yml` has no default and isn't set in the pod env. CI doesn't include `application-dev.yml` (gitignored), so any `${ENV:default}` patterns are now mandatory.

**Fix**: Add an empty default to every env-fed property in `application.yml`:

```yaml
cors.allowed-origins: ${CORS_ALLOWED_ORIGINS:}
```

#### 6. Spring app connects to `localhost:27017` instead of MongoDB

**Cause**: Spring Boot 4 + Spring Data MongoDB 5 expects `spring.mongodb.*` (NOT `spring.data.mongodb.*`). The latter is silently ignored, autoconfig falls back to localhost.

**Fix**:

```yaml
spring:
  mongodb:        # NOT spring.data.mongodb
    uri: ${MONGODB_URI}
    database: ${MONGODB_DATABASE}
```

#### 7. Env var set in pod but Spring property unresolved

**Cause**: Spring relaxed binding rules — env var name must match property name with `.` and `-` replaced by `_`, uppercase. `JWT_PRIVATE_KEY_PATH` does NOT map to `dracolich.jwt.private-key`. The right env var is `DRACOLICH_JWT_PRIVATE_KEY`.

**Fix**: Either rename the env var to follow Spring's mapping, or in `application.yml` reference the env var explicitly: `${MY_RAW_VAR:default}`.

#### 8. Pod `CreateContainerConfigError`, "secret not found"

**Cause**: Secret was created in the wrong namespace (usually `default` because `$NS` wasn't exported in the shell).

**Fix**:

```bash
kubectl get secrets --all-namespaces | grep <secret-name>
# Recreate with explicit --namespace=dracolich-dev
```

#### 9. `mtg-library-api` OOMKilled during Scryfall sync

**Cause**: 768Mi memory limit too low — the seeder buffers the ~400 MB Scryfall bulk file in memory.

**Fix**: Bump to 1.5 GB and cap JVM heap percentage:

```yaml
resources:
  limits:
    memory: 1536Mi
env:
  JAVA_TOOL_OPTIONS: "-XX:MaxRAMPercentage=70"
```

#### 10. Atlas M0 silently rejects writes after ~3,800 cards

**Cause**: 512 MB cap. The Scryfall bulk fits in ~500 MB → just doesn't fit.

**Fix**: Either upgrade to Atlas M2 ($9/mo, 2 GB), or self-host MongoDB in-cluster (10 Gi PVC for ~$1/mo, what we picked).

#### 11. Routes 404 with weird message: `card: id not found: search`

**Cause**: Spring controller has `GET /{id}` and `GET /search` on the same path; `{id}` matches first.

**Fix**: Add a regex constraint to the path variable:

```java
@GetMapping("/{id:[0-9a-f-]{36}}")
```

#### 12. Jackson 3 can't deserialize `dm.dracolich.forge.error.ApiError`

**Cause**: ApiError had no no-arg constructor; its `error` field was an `ErrorCode` interface (Jackson can't construct interfaces without help).

**Fix**: Add `@NoArgsConstructor` and change `error` to `String`. Constructors that take `ErrorCode` extract the code string.

#### 13. cert-manager can't issue cert: `dial tcp: lookup dev.dracolich.cc on 10.0.0.10:53: no such host`

**Cause**: Ingress still has the old hostname (e.g. domain change wasn't synced by ArgoCD).

**Fix**:

```bash
git push                                    # ensure local commit is pushed
kubectl -n argocd patch app <svc> --type merge -p '{"operation":{"sync":{"prune":true}}}'
kubectl delete certificate <old-name> -n dracolich-dev
kubectl delete order -n dracolich-dev --all
kubectl delete challenge -n dracolich-dev --all
```

#### 14. Browser: `ERR_CERT_AUTHORITY_INVALID`, no override option (.app domain)

**Cause**: `.app` is HSTS-preloaded — browsers refuse any non-LE-issued cert. Usually means LE hasn't issued yet (challenge in progress or failing).

**Fix**: Wait for `kubectl get certificate -n dracolich-dev` to show `READY=True`. If solver pod stuck Pending, free up node capacity (`kubectl delete app` for non-critical Apps, or scale node pool).

#### 15. GH Actions: `Invalid format 'fix: trigger pipeline'` on multi-line commit message

**Cause**: GitHub tightened `$GITHUB_OUTPUT` validation. Multi-line `git log -1 --pretty=%B` (full body) now breaks.

**Fix**: Use `--pretty=%s` (subject only) instead.

#### 16. Bash `--namespace=$NS` resolves to empty when `$NS` not exported

**Cause**: Variable not set in current shell.

**Fix**: Always `export NS=dracolich-dev` at the top of the session, or hardcode `--namespace=dracolich-dev`.

### Issues you might hit

#### A. Atlas M0 "good for prod" assumption

**Symptom**: 512 MB fills up quickly (Scryfall bulk, growing user data).

**Fix**: Upgrade to M2 ($9/mo, 2 GB) early. Or self-host (we picked this).

#### B. Self-signed CA cert intercept (corporate proxies)

**Symptom**: `helm install` fails with TLS verification errors when on corporate Wi-Fi.

**Fix**: `export NODE_EXTRA_CA_CERTS=/path/to/ca-bundle.crt` for kubectl/helm CLI tools, or work from non-corporate network.

#### C. Cloudflare proxy on (orange cloud) breaks Let's Encrypt HTTP-01 challenge

**Symptom**: Cert never issues; challenge solver returns 404 from edge.

**Fix**: Set Cloudflare DNS to "DNS only" (gray cloud) at least until cert is issued. Once you set up Cloudflare Access, you can flip back to proxied.

#### D. ArgoCD shows "OutOfSync" forever after manual `kubectl edit`

**Symptom**: ArgoCD detects drift and reverts your manual change repeatedly.

**Fix**: Either commit the change to dracolich-helm, or use `argocd app diff` then `kubectl apply` from a manifest that ArgoCD ignores.

#### E. PVC not deletable when Pod gone

**Symptom**: `kubectl delete pvc` hangs.

**Fix**: PVC has a finalizer holding it. `kubectl patch pvc <name> -p '{"metadata":{"finalizers":null}}'`.

#### F. Kubelet OOMKilling pods even though memory limit looks generous

**Symptom**: Pod restarts with no obvious memory leak.

**Fix**: JVM heap defaults can over-allocate beyond container limits without `-XX:MaxRAMPercentage`. Cap at 70-75% of container limit.

#### G. `kubectl logs` returns nothing after pod restart

**Symptom**: Just-restarted pod has empty logs.

**Fix**: Logs are per-container instance. Use `--previous` flag for the previous container's logs:

```bash
kubectl logs -n dracolich-dev <pod> --previous
```

#### H. ArgoCD's auto-sync doesn't trigger on values-dev.yaml change

**Symptom**: Pushed to dracolich-helm but ArgoCD didn't sync within minutes.

**Fix**: Default polling interval is 3 minutes. Force manual sync, or check if the Application has `syncPolicy.automated.selfHeal: true`. Webhook from GitHub → ArgoCD reduces lag to seconds, but adds setup.

#### I. CertManager rate-limited by Let's Encrypt

**Symptom**: Cert stuck issuing for hours; logs mention "rate limited."

**Fix**: LE has 5 failed validations / hour / domain. Don't spam Sync attempts. Wait the cooldown out, OR use the LE staging issuer for testing:

```yaml
acme.server: https://acme-staging-v02.api.letsencrypt.org/directory
```

(certs from staging are NOT trusted by browsers, but useful to validate config without hitting prod limits.)

#### J. ArgoCD "App of Apps" pattern question — when to use ApplicationSet vs Applications

**ApplicationSet**: when services share a common Helm pattern (your case, 4 Spring services).

**Application**: when each app is unique (custom project, custom values).

For now, ApplicationSet is right. Adding the UI later might warrant a separate Application since it's structurally different (static frontend vs Spring API).

---

## Costs

| Component | Monthly cost (running) | Monthly cost (stopped) |
|---|---|---|
| AKS control plane (Free tier) | $0 | $0 |
| 1× B2s_v2 node | ~$30 | $0 |
| 2× B2s_v2 nodes (recommended for headroom) | ~$60 | $0 |
| Azure Standard LB | ~$20 | ~$20 |
| LB Public IP | ~$3-4 | ~$3-4 |
| MongoDB PVC (10 GB Azure managed disk) | ~$1.50 | ~$1.50 |
| Cloudflare DNS | $0 | $0 |
| Domain (`dracolich.app`) | ~$1/mo annualized | ~$1/mo annualized |
| **Total** | **~$55-90/mo** | **~$5-7/mo** |

Stop the cluster nightly (`az aks stop`) to save ~$50/mo when not actively iterating.

---

## Useful Aliases

```bash
# Add to your ~/.zshrc or similar
alias kctx='kubectl config get-contexts'
alias kuse='kubectl config use-context'
alias kpods='kubectl get pods -n dracolich-dev'
alias klogs='kubectl logs -n dracolich-dev'
alias ksecret='kubectl get secrets -n dracolich-dev'
alias ksync='function _ksync() { kubectl -n argocd patch app $1 --type merge -p "{\"operation\":{\"sync\":{}}}"; }; _ksync'
```

---

## Future Hardening (Deferred)

These are intentionally not done in dev. Address before public/prod launch.

- **Cloudflare Access** in front of `dev.dracolich.app` and `argocd.dracolich.app`
- **External Secrets Operator + Azure Key Vault** to replace out-of-band `kubectl create secret`
- **NetworkPolicy** to restrict ai-api ingress to deck-builder-api only
- **Multi-replica services** with `PodDisruptionBudget` for zero-downtime deploys
- **HPA** (HorizontalPodAutoscaler) for traffic-driven scaling
- **MongoDB backups** — Azure Disk snapshots on a cron, or move to Atlas M2+ for auto-backups
- **MongoDB replica set** if you need HA
- **Prometheus + Grafana** for metrics, **Loki** for log aggregation
- **Rate limiting** at NGINX or app layer
- **`application-prod.yml`** profiles per service
- **Production cluster** — separate AKS, separate Atlas/MongoDB, separate Cloudflare zone (`dracolich.app` → prod, `dev.dracolich.app` → dev)
