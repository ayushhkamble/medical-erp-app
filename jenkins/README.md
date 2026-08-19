# CI/CD Deployment Guide — medical-erp-app

Two Jenkins pipelines for this repo:

| Pipeline | File | Deploys |
|---|---|---|
| Backend | `jenkins/Jenkinsfile.backend` | `user-service`, `product-service`, `order-service` → AWS ECR → AWS EKS |
| Frontend | `jenkins/Jenkinsfile.frontend` | React/Vite SPA → AWS S3 (+ optional CloudFront) |

**Read "Architecture note" and "Known issues" below before your first run.** Both sections describe real discrepancies found in this repo as it stands today — not hypotheticals.

---

## Architecture note — why the frontend pipeline does NOT deploy to Kubernetes

This repo actually contains two different frontend hosting paths, and they conflict:

1. **`terraform/modules/s3-cloudfront/`** provisions an S3 bucket + CloudFront distribution for the built static site. This is the path the frontend pipeline below uses.
2. **`frontend/Dockerfile` + `frontend/nginx.conf`** build an nginx container that reverse-proxies `/api/user`, `/api/product`, `/api/order` to in-cluster Kubernetes Service names (`user-service:8081`, etc.). This is designed to run **as a pod inside EKS**, not on S3.

Nothing in `k8s/deployments/` or `k8s/services/` references the frontend image — there is no frontend Deployment/Service manifest in this repo. The Docker/nginx path exists but is currently unused by any pipeline or manifest.

Since you described the frontend as "hosted on S3 bucket," `Jenkinsfile.frontend` builds it as **static files synced to S3**, matching Terraform's own `s3-cloudfront` module. It has no Docker/ECR/kubectl stage.

**If you actually want the frontend running as a pod in EKS instead**, that's a different, larger change: you'd need to add a Deployment + Service (+ Ingress path) for it under `k8s/`, rewrite `Jenkinsfile.frontend` to match the backend's shape (checkout → install → docker build/tag → push ECR → kubectl deploy), and change the build-time `VITE_*_URL` values to relative `/api/...` paths that resolve through the in-pod nginx proxy instead of the public ALB host. **Don't run both** — S3 and an in-cluster pod would serve two independently-updated copies of the frontend behind two different addresses, and users could land on either one depending on which URL they use.

---

## Known issues found while reading this repo

These aren't pipeline bugs — they're pre-existing inconsistencies in the repo itself. Fix (or consciously accept) them before your first production run.

### 1. Terraform and the live cluster disagree on ECR repo names and region
- `terraform/modules/ecr/main.tf` provisions repos named **`medical-erp/user-service`, `medical-erp/product-service`, `medical-erp/order-service`** in **`us-east-1`** (per `terraform/env/prod/variables.tf` default).
- The **already-deployed** `k8s/deployments/*.yaml` manifests reference **`medical-erp/user`, `medical-erp/products`, `medical-erp/order`** (shortened, inconsistent suffix) in **`eu-north-1`**, account `716616997130`.
- Git history on `k8s/deployments/` shows six separate manual image-tag/URI edits after the initial commit, while `terraform/modules/ecr/` was never touched again — so the manifests drifted away from what Terraform actually creates.
- **The Jenkinsfiles in this PR match the live manifests** (`eu-north-1`, short names), since that's what your cluster runs today. If you run `terraform apply` fresh, it will create *differently-named repos in a different region* that nothing points to. Either update `terraform/modules/ecr/main.tf` to match the live naming/region, or update the K8s manifests + Jenkinsfiles to match Terraform — pick one direction and make both sides agree.

### 2. `k8s/secrets/app-secrets.yaml` contains live-looking credentials, committed to a public repo
The `data:` values in that file are base64 — **encoding, not encryption**. Anyone with read access to the repo (or its git history, even after the file is later changed) can decode them in one command. What's checked in looks like a real MongoDB Atlas connection string (with embedded username/password) and a JWT signing secret, not placeholders.
- **Rotate the MongoDB Atlas password and the JWT secret now**, independent of anything else in this guide.
- Regenerate `app-secrets.yaml` from a local `.env` (see Step 6 below) and **do not commit the regenerated file**. Add `k8s/secrets/app-secrets.yaml` to `.gitignore` and keep only a `.example` version with placeholder values in the repo.
- If this repo is public, treat the current MongoDB/JWT values as fully compromised — rotating them is not optional cleanup.

### 3. Region mismatch inside the existing `Jenkinsfile.backend`/`.frontend` (superseded by this PR)
The versions of these files already in the repo hardcode `us-east-1`, but the live cluster and images are in `eu-north-1`. The versions in this PR use `eu-north-1` to match the live manifests — just flagging the change so it isn't a silent surprise in the diff.

### 4. `k8s/ingress/ingress.yaml`'s ACM certificate is in a third region
The `certificate-arn` annotation points at a cert in **`ap-southeast-2`**, while the cluster/ECR images are in `eu-north-1`. The manifest's own inline comment warns about exactly this: ACM certs used by an ALB must be in the *same region as the ALB*, or you get `ValidationError: Certificate ARN '...' is not valid`. Issue a new ACM cert in `eu-north-1` for your domain and swap the `certificate-arn` value before applying this Ingress — the current value will not work against a `eu-north-1` cluster. The `security-groups` value (`sg-0d08c1fb86b325ca3`) is also almost certainly specific to whichever AWS account/VPC these manifests were last applied against — verify it exists in your account before applying, or drop the annotation and let the controller manage its own security group.

---

## Prerequisites

### Accounts & access
- AWS account with an existing (or about-to-be-created) EKS cluster in **`eu-north-1`**, ECR access, an S3 bucket for the frontend, and (optionally) CloudFront + an ACM cert for HTTPS.
- IAM user/role for Jenkins with: `ecr:GetAuthorizationToken`, `ecr:BatchCheckLayerAvailability`, `ecr:PutImage`, `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload` on the `medical-erp/*` repos; `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket` on the frontend bucket; `cloudfront:CreateInvalidation` if using CloudFront; EKS cluster access (`eks:DescribeCluster` + an entry in the cluster's `aws-auth`/access entries mapping this IAM identity to a Kubernetes RBAC role — see Step 5).
- A MongoDB Atlas cluster (or self-hosted MongoDB) reachable from EKS, with three databases: `user_db`, `products_db`, `order_db` (per the existing — compromised — secret; use your own after rotating).

### Jenkins server / agents
- Jenkins 2.x LTS.
- Agent(s) with: **JDK 17**, **Maven 3.8+**, **Docker** (daemon reachable from the agent), **AWS CLI v2**, **kubectl** (matching your EKS cluster's Kubernetes minor version), **Node.js 20.x + npm**.
- Jenkins plugins: **Pipeline**, **Git**, **AWS Credentials**, **JUnit**.
- Confirm the agent's `/bin/sh` — the pipelines' `sh` blocks are written to run correctly under either `dash` or `bash`, but if you hand-edit them later and add bash-only syntax (arrays, `[[ ]]`, `declare`), make sure the target agent's default shell actually supports it. Alpine-based Jenkins agent images default `/bin/sh` to `dash`, which does not.

### Local machine (one-time setup steps below)
- AWS CLI v2, configured with credentials that can create ECR repos / describe the EKS cluster.
- `kubectl`, `helm` (for the AWS Load Balancer Controller, if not already installed on the cluster).
- `terraform` ≥ 1.5, if provisioning infra from scratch.

---

## Deploying from scratch

### Step 1 — Provision AWS infrastructure
If the EKS cluster, ECR repos, VPC, and S3/CloudFront don't exist yet, use the Terraform in this repo:

```bash
cd terraform/env/prod
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set your domain_name and acm_certificate_arn
terraform init
terraform plan
terraform apply
```

**Before running this**, resolve Known Issue #1 above — either edit `terraform/modules/ecr/main.tf` so `for_each` produces `user`, `products`, `order` (not `user-service`, `product-service`, `order-service`) and set `aws_region` to `eu-north-1` in `terraform/env/prod/variables.tf`, **or** decide you're moving the whole stack to `us-east-1` with full-length repo names and update `k8s/deployments/*.yaml` + both Jenkinsfiles' `AWS_REGION`/repo-name logic to match instead. Don't apply Terraform as-is against an account that already has the `eu-north-1` resources — you'll end up with two disconnected sets of infra.

### Step 2 — Install the AWS Load Balancer Controller on EKS
Required for `k8s/ingress/ingress.yaml` (ALB Ingress) to work:

```bash
aws eks update-kubeconfig --region eu-north-1 --name <your-cluster-name>
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=<your-cluster-name> \
  --set serviceAccount.create=true
```
Full detail already in `docs/KUBERNETES_DEPLOYMENT.md` — follow that for the IAM policy/IRSA setup this chart needs.

### Step 3 — Create the namespace
```bash
kubectl apply -f k8s/namespace/
```

### Step 4 — Rotate and create real secrets (do this before Step 5)
```bash
# Generate a new JWT secret
NEW_JWT_SECRET=$(openssl rand -base64 48)

# In MongoDB Atlas: rotate the ayushkamble820_db_user password, then build new URIs
kubectl create secret generic app-secrets \
  --namespace med-erp \
  --from-literal=MONGODB_URI_USER="mongodb+srv://<new-user>:<new-pass>@<cluster>/user_db?retryWrites=true&w=majority" \
  --from-literal=MONGODB_URI_PRODUCT="mongodb+srv://<new-user>:<new-pass>@<cluster>/products_db?retryWrites=true&w=majority" \
  --from-literal=MONGODB_URI_ORDER="mongodb+srv://<new-user>:<new-pass>@<cluster>/order_db?retryWrites=true&w=majority" \
  --from-literal=JWT_SECRET="$NEW_JWT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -
```
Do **not** commit the output of this command. Delete or gitignore the checked-in `k8s/secrets/app-secrets.yaml` (see Known Issue #2).

### Step 5 — Apply ConfigMaps, Services, Deployments, HPA, Ingress
```bash
kubectl apply -f k8s/configmaps/
kubectl apply -f k8s/services/
kubectl apply -f k8s/deployments/
kubectl apply -f k8s/hpa/
kubectl apply -f k8s/ingress/ingressclass.yaml
kubectl apply -f k8s/ingress/ingress.yaml
```
`k8s/ingress/ingress.yaml` hardcodes an ACM cert ARN and a security group ID — replace both with your own before applying, or the Ingress will fail to provision an ALB.

Verify:
```bash
kubectl get pods -n med-erp
kubectl get ingress -n med-erp
```

### Step 6 — Set up Jenkins credentials
**Manage Jenkins → Credentials → System → Global credentials → Add Credentials.** Exact IDs (both pipelines depend on these):

| ID | Kind | Contents |
|---|---|---|
| `aws-credentials` | AWS Credentials | Access key + secret for the IAM identity described in Prerequisites |
| `kubeconfig` | Secret file | Your cluster's kubeconfig (`aws eks update-kubeconfig` output), used by the backend pipeline only |

### Step 7 — Set Jenkins environment variables
**Manage Jenkins → System → Global properties → Environment variables** (or per-job):

| Name | Example | Used by |
|---|---|---|
| `S3_BUCKET_NAME` | `medical-erp-frontend-prod` | Frontend |
| `AWS_REGION` | `eu-north-1` | Both (frontend reads it directly; backend hardcodes it — keep them in sync if you change region) |
| `API_BASE_URL` | `https://api.edublitzb2berp.online/api/v1` | Frontend build (must match the `host:` in `k8s/ingress/ingress.yaml`) |
| `CLOUDFRONT_DISTRIBUTION_ID` | `E123ABC...` | Frontend — optional, skips invalidation if unset |

### Step 8 — Create the two Jenkins jobs
**New Item → Pipeline** (or Multibranch Pipeline), pointing each at this repo, with:

| Job | Script Path |
|---|---|
| Backend | `jenkins/Jenkinsfile.backend` |
| Frontend | `jenkins/Jenkinsfile.frontend` |

### Step 9 — First run
Trigger each job manually on `main`. Watch:
- Backend: `Install dependencies & build` (Maven, all 3 services) → `Docker build, tag & push to ECR` → `Deploy to EKS` (rolling update + `kubectl rollout status` wait).
- Frontend: `Install dependencies` → `Build` (Vite, with `VITE_*_URL` pointed at `API_BASE_URL`) → `Deploy to S3` (synced with long cache on hashed assets, no-cache on `index.html`, optional CloudFront invalidation).

Confirm:
```bash
kubectl get pods -n med-erp -w
curl -I https://<your-s3-or-cloudfront-domain>/
curl https://api.edublitzb2berp.online/api/v1/actuator/health
```

---

## Pipeline stage reference

**Backend (`Jenkinsfile.backend`)**
1. **Checkout** — `checkout scm`
2. **Install dependencies & build** — `mvn clean package` per service (`user-service`, `product-service`, `order-service`), JUnit results collected
3. **Docker build, tag & push to ECR** *(main branch only)* — per service: `docker build` tagged with both the short git commit SHA and `latest`, pushed to `<account>.dkr.ecr.eu-north-1.amazonaws.com/medical-erp/<repo>`
4. **Deploy to EKS** *(main branch only)* — `kubectl set image` + `kubectl rollout status` per service, using the pushed commit-SHA tag (not `latest`, so rollbacks via `kubectl rollout undo` are meaningful)

**Frontend (`Jenkinsfile.frontend`)**
1. **Checkout**
2. **Install dependencies** — `npm ci`
3. **Build** — `npm run lint` then `npm run build` (Vite), with `VITE_*_SERVICE_URL` env vars set from `API_BASE_URL`
4. **Deploy to S3** *(main branch only)* — `aws s3 sync` with immutable long-cache on hashed assets, no-cache on `index.html`, optional CloudFront invalidation

Neither pipeline auto-rolls-back on failure. A failed `Deploy to EKS` stage leaves the previous rollout's pods running until `kubectl rollout status` times out; check `kubectl rollout undo deployment/<svc> -n med-erp` if a bad image made it through.
