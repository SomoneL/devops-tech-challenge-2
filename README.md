# **Tech Challenge 2**

DevOps Tech Challenge — Node.js application deployment with Docker, Terraform, AWS EKS, Jenkins, and Argo CD

<h2>Overview</h2>

A Node.js "Hello, World!" application deployed to an Amazon EKS cluster provisioned entirely with Terraform. The application is containerized with Docker, stored in Amazon ECR, packaged as a Helm chart, and exposed through an Application Load Balancer.

Two independent CI/CD pipelines deliver the same chart. The `main` branch uses a push-based Jenkins pipeline. The `gitops` branch uses GitHub Actions for CI and Argo CD for pull-based CD.

<b>Live application:</b> http://k8s-default-hellowor-1800b9d2ea-1139299927.us-east-1.elb.amazonaws.com

Hello World served through the ALB<img width="676" height="122" alt="01-app-in-browser" src="https://github.com/user-attachments/assets/8703d945-fa89-4174-b2bc-40c4499d4f29" />


<br />

<h2>Requirements Met</h2>

<ul>
  <li><b>EKS cluster</b> provisioned with Terraform, with auto-scaling and an ALB</li>
  <li><b>4 nodes maximum</b>, 1 node minimum, 2 desired</li>
  <li><b>Instance type:</b> t3.small</li>
  <li><b>HPA</b> scaling to a maximum of 3 pods, triggering at 50% CPU or 50% memory utilization</li>
  <li><b>Jenkins pipeline</b> building the image, pushing to ECR, and deploying with kubectl and Helm</li>
  <li><b>GitOps branch</b> with GitHub Actions and Argo CD bootstrapped to the Helm chart</li>
</ul>

<br />

<h2>Architecture</h2>

```
Internet
  → Application Load Balancer   (public subnets, 2 AZs)
    → Target Group              (target-type: ip)
      → Pod IP                  (worker node, private subnet)
        → Express process       (port 3000)
```

<ul>
  <li><b>VPC</b> 10.0.0.0/16 — public subnets 10.0.3.0/24 and 10.0.4.0/24, private subnets 10.0.1.0/24 and 10.0.2.0/24, one shared NAT Gateway</li>
  <li><b>EKS cluster</b> devops-ch2-cluster, Kubernetes 1.34, managed node group on t3.small, add-ons coredns / kube-proxy / vpc-cni</li>
  <li><b>ECR repository</b> devops-challenge-2-app, scan on push, keep the last 5 tagged images</li>
  <li><b>In-cluster controllers</b> — AWS Load Balancer Controller, Cluster Autoscaler, metrics-server</li>
  <li><b>IAM</b> — IRSA roles for the load balancer controller and the autoscaler; a GitHub OIDC role for Actions on the gitops branch</li>
</ul>

<br />

<h2>Repository Layout</h2>

```
index.js                        Express application
Dockerfile                      Application image (node:16)
Jenkinsfile                     Four-stage pipeline
jenkins/Dockerfile              Jenkins image + Docker CLI, AWS CLI v2, kubectl, Helm
terraform/                      provider, variables, vpc, eks, ecr, iam, outputs
helm/hello-world/               Chart, values, and templates for Deployment / Service / Ingress / HPA
argocd/application.yaml         gitops branch only
.github/workflows/ci.yml        gitops branch only
```

<br />

<h2>Setting Up Your Environment</h2>

<ul>
  <li><b>AWS CLI v2</b> — configured with credentials that can create VPC, EKS, IAM, and ECR resources</li>
  <li><b>Terraform</b> — 1.5 or later</li>
  <li><b>kubectl</b> — 1.28 or later</li>
  <li><b>Helm</b> — version 3</li>
  <li><b>Docker</b> — Docker Desktop, running before any build</li>
  <li><b>Node.js 16</b> — run <code>nvm use 16</code> before any npm command. Both Dockerfiles pin <code>node:16</code>.</li>
  <li><b>hey</b> — optional, load testing only: <code>brew install hey</code></li>
</ul>

<br />

<h2>Running the Project Locally</h2>

```bash
git clone https://github.com/SomoneL/devops-tech-challenge-2.git
cd devops-tech-challenge-2
nvm use 16
npm ci
node index.js
```

In a second terminal:

```bash
curl http://localhost:3000          # → Hello, World!
curl http://localhost:3000/health   # → OK
```

<img width="1912" height="172" alt="02-local-curl" src="https://github.com/user-attachments/assets/22eabd57-d4f6-4e61-a329-1d57ba246b35" />


<br />

<h2>Deploying the Infrastructure</h2>

<h3>Step 1: Provision with Terraform</h3>

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

Expect 15 to 20 minutes. The node group takes 5 to 10 minutes after the control plane is up.

<img width="2048" height="364" alt="03-terraform-apply" src="https://github.com/user-attachments/assets/b2b8086c-26cf-4f93-94dc-5f286925c77f" />


<h3>Step 2: Configure kubectl</h3>

```bash
aws eks --region us-east-1 update-kubeconfig --name devops-ch2-cluster
kubectl get nodes
kubectl get pods -A
```

<img width="1112" height="365" alt="04-get-nodes" src="https://github.com/user-attachments/assets/20d3fc58-f709-4f85-83c9-7176da66cebd" />



<h3>Step 3: Install the AWS Load Balancer Controller</h3>

Create and annotate the ServiceAccount **before** the Helm install. IRSA credentials are injected at pod creation, so pods created before the annotation exists will crash-loop.

```bash
kubectl create serviceaccount aws-load-balancer-controller -n kube-system

kubectl annotate serviceaccount aws-load-balancer-controller -n kube-system \
  eks.amazonaws.com/role-arn=$(cd terraform && terraform output -raw load_balancer_controller_role_arn)

helm repo add eks https://aws.github.io/eks-charts
helm repo update

VPC_ID=$(cd terraform && terraform output -raw vpc_id)

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=devops-ch2-cluster \
  --set region=us-east-1 \
  --set vpcId=$VPC_ID \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```

<h3>Step 4: Install the Cluster Autoscaler and metrics-server</h3>

```bash
kubectl create serviceaccount cluster-autoscaler -n kube-system

kubectl annotate serviceaccount cluster-autoscaler -n kube-system \
  eks.amazonaws.com/role-arn=$(cd terraform && terraform output -raw cluster_autoscaler_role_arn)

helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update

helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system \
  --set autoDiscovery.clusterName=devops-ch2-cluster \
  --set awsRegion=us-east-1 \
  --set rbac.serviceAccount.create=false \
  --set rbac.serviceAccount.name=cluster-autoscaler

helm install metrics-server metrics-server/metrics-server -n kube-system
```

<h3>Step 5: Deploy and verify</h3>

The Jenkins pipeline deploys automatically. To deploy by hand:

```bash
ECR_REPO=$(cd terraform && terraform output -raw ecr_repository_url)

helm upgrade --install hello-world ./helm/hello-world \
  --set image.repository=$ECR_REPO \
  --set image.tag=<tag> \
  --wait --timeout 3m

kubectl get ingress hello-world -w
```

The ALB address appears after two to three minutes.

<img width="1820" height="88" alt="05-ingress-address" src="https://github.com/user-attachments/assets/36dc3104-fa86-43c5-8577-445ad74367af" />


<br />

<h2>Explanation of the Terraform Code</h2>

<ul>
  <li><code>provider.tf</code> — AWS provider pinned to <code>~&gt; 5.0</code>, Kubernetes provider to <code>~&gt; 2.0</code></li>
  <li><code>variables.tf</code> — region, project name, VPC CIDR, cluster name and version, node sizing, application port</li>
  <li><code>vpc.tf</code> — <code>terraform-aws-modules/vpc/aws</code>, two AZs, public and private subnets, IGW, single NAT Gateway</li>
  <li><code>eks.tf</code> — <code>terraform-aws-modules/eks/aws</code>, control plane, managed node group, core add-ons</li>
  <li><code>ecr.tf</code> — image repository with scan-on-push and a keep-last-5 lifecycle policy</li>
  <li><code>iam.tf</code> — IRSA roles for the load balancer controller and the Cluster Autoscaler</li>
  <li><code>iam-gitops.tf</code> — GitHub OIDC provider trust and the Actions role (gitops branch only)</li>
  <li><code>outputs.tf</code> — cluster name and endpoint, ECR URL, region, VPC ID, IRSA role ARNs</li>
</ul>

Three decisions worth noting:

<ol>
  <li><b>Community modules over hand-written resources.</b> The VPC module applies the subnet tags (<code>kubernetes.io/role/elb</code>) the load balancer controller needs for discovery. Without them the Ingress never receives an address, and nothing errors.</li>
  <li><b>IRSA over node-role IAM policies.</b> Attaching the policy to the node role would give every pod on the node the same permissions. IRSA scopes them to one ServiceAccount with short-lived, auto-rotated credentials.</li>
  <li><b>ASG discovery tags on the node group.</b> The Cluster Autoscaler finds Auto Scaling Groups by tag. Without <code>k8s.io/cluster-autoscaler/enabled</code>, it runs and scales nothing.</li>
</ol>

<br />

<h2>Explanation of the Helm Chart</h2>

`helm/hello-world` is the single source of truth for the workload, used unchanged by both pipelines.

<ul>
  <li><code>deployment.yaml</code> — pod spec, probes on <code>/health</code>, requests 100m CPU / 128Mi, limits 250m CPU / 256Mi</li>
  <li><code>service.yaml</code> — ClusterIP, port 80 to targetPort 3000</li>
  <li><code>ingress.yaml</code> — ALB Ingress, internet-facing, <code>target-type: ip</code>, health check on <code>/health</code></li>
  <li><code>hpa.yaml</code> — 1 to 3 replicas at 50% CPU or 50% memory</li>
</ul>

<code>replicas</code> is omitted from the Deployment when autoscaling is enabled, so a <code>helm upgrade</code> does not reset the count to 1 and fight the HPA. Resource requests are mandatory: utilization is a percentage of the request, and without one the HPA reports <code>&lt;unknown&gt;</code>.

Only <code>image.repository</code> and <code>image.tag</code> are overridden per deploy.

<br />

<h2>Explanation of the Jenkins Pipeline</h2>

Jenkins runs in a container built from `jenkins/Dockerfile`, which adds the four tools the base image lacks: Docker CLI, AWS CLI v2, kubectl, and Helm.

```bash
docker build -t jenkins-devops -f jenkins/Dockerfile jenkins/

docker run -d --name jenkins \
  -p 8080:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  jenkins-devops
```

<b>Credentials</b>

<ul>
  <li><code>aws-creds</code> — AWS Credentials type, access key scoped to ECR push/pull and <code>eks:DescribeCluster</code></li>
  <li><code>github-creds</code> — username and Personal Access Token, required because the repository is private</li>
</ul>

<b>Job configuration:</b> Pipeline, Definition set to Pipeline script from SCM, branch specifier <code>*/main</code>, script path <code>Jenkinsfile</code>.

<b>Stages</b>

<ol>
  <li><b>Checkout</b> — pulls the commit under build</li>
  <li><b>Build Docker Image</b> — builds <code>$ECR_REPO:$BUILD_NUMBER</code> against the mounted Docker daemon</li>
  <li><b>Push to ECR</b> — authenticates with <code>aws ecr get-login-password</code> and pushes the tagged image</li>
  <li><b>Deploy to EKS</b> — refreshes the kubeconfig, then <code>helm upgrade --install</code> with <code>--wait --timeout 3m</code> so the stage fails if the rollout is unhealthy</li>
</ol>

Images are tagged with the build number rather than <code>latest</code>, so every running pod traces back to a specific build.

<img width="1018" height="626" alt="06-jenkins-build" src="https://github.com/user-attachments/assets/2a8c6d33-9349-4269-b641-d1ad49b67b96" />

<img width="1270" height="144" alt="07-pod-image" src="https://github.com/user-attachments/assets/0e83156e-0c68-4679-b801-59f56669bd68" />


<br />

<h2>GitOps Branch: GitHub Actions and Argo CD</h2>

Same application, inverted trust model. Jenkins is push-based and holds cluster credentials. The GitOps pipeline is pull-based: Actions only writes to Git, and Argo CD inside the cluster is the only component with deploy permissions.

<b>GitHub Actions</b> — `.github/workflows/ci.yml`

<ol>
  <li>Authenticates to AWS with OIDC, no stored keys. The trust policy pins the <code>sub</code> claim to this repository and the gitops branch.</li>
  <li>Builds and pushes the image tagged with the commit SHA.</li>
  <li>Rewrites <code>image.tag</code> in <code>values.yaml</code> and commits it back. It never calls kubectl or helm.</li>
</ol>

The role carries <code>AmazonEC2ContainerRegistryPowerUser</code> and no EKS permissions. The <code>paths:</code> filter on the trigger prevents the workflow's own commit from re-triggering it in an infinite loop.

<b>Argo CD</b> — `argocd/application.yaml`

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server
kubectl apply -f argocd/application.yaml

kubectl port-forward svc/argocd-server -n argocd 8081:443
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

The Application watches `targetRevision: gitops` at path `helm/hello-world` with `selfHeal: true` and `prune: true`. Verified by running `kubectl scale deploy hello-world --replicas=5` and watching Argo CD revert it.

<img width="750" height="790" alt="Screenshot 2026-08-30 at 6 48 52 PM" src="https://github.com/user-attachments/assets/a1814750-8396-434a-a49d-6565a5eda213" />


<br />

<h2>Load Testing and Scaling Results</h2>

Two systems, chained rather than alternative. The HPA raises the replica count; those pods schedule until no node has allocatable CPU left and sit `Pending`. The Cluster Autoscaler watches for that condition and adds a node.

```bash
ALB_URL=$(kubectl get ingress hello-world -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
hey -z 8m -c 100 http://$ALB_URL/
```

<b>Results</b>

<ul>
  <li><b>Requests:</b> 824,096 HTTP 200, 1 HTTP 502</li>
  <li><b>Throughput:</b> ~1,716 requests per second</li>
  <li><b>Latency:</b> 58 ms average, 93 ms p95, 162 ms p99</li>
  <li><b>HPA at peak:</b> CPU 213% against the 50% target</li>
  <li><b>Pods:</b> 1 → 3</li>
  <li><b>Nodes:</b> 1 → 2, new node Ready in roughly 3 minutes</li>
</ul>

<img width="2048" height="355" alt="08-load-peak" src="https://github.com/user-attachments/assets/09a0577e-a213-441b-88a8-3438d584a118" />


<img width="2048" height="620" alt="10-scale-down" src="https://github.com/user-attachments/assets/3d38a314-b407-4617-aa33-72f200c785bb" />


Scale-down is slower by design: the HPA waits out a five-minute stabilization window and the Cluster Autoscaler wants roughly ten minutes of low utilization. Under-provisioning drops traffic; scaling down too eagerly causes thrashing.

<br />

<h2>Teardown</h2>

Order matters. The ALB was created by a controller, not by Terraform, so it is not in Terraform state. Its ENIs are attached to the subnets and AWS will not delete a subnet with a live ENI, so `terraform destroy` hangs partway through the VPC.

```bash
helm uninstall hello-world
helm uninstall aws-load-balancer-controller -n kube-system
helm uninstall cluster-autoscaler -n kube-system
helm uninstall metrics-server -n kube-system

cd terraform
terraform destroy
```

<br />

<h2>Troubleshooting Notes</h2>

<ul>
  <li><b>ImagePullBackOff, <code>no match for platform in manifest</code></b> — arm64 Mac building for amd64 nodes. Build with <code>--platform linux/amd64</code> and make the Jenkins image's tool downloads architecture-aware.</li>
  <li><b>Permission denied on <code>/var/run/docker.sock</code></b> — <code>docker exec -u root jenkins chmod 666 /var/run/docker.sock</code></li>
  <li><b>Jenkins checkout finds no branch</b> — the branch specifier defaults to <code>*/master</code>; this repo uses <code>main</code>.</li>
  <li><b>kubectl from Jenkins is unauthorized</b> — IAM authenticates, RBAC authorizes. The <code>jenkins-ci</code> user needs an EKS access entry.</li>
  <li><b>Ingress ADDRESS never fills in</b> — subnet tagging. Check the controller logs for "unable to discover subnets".</li>
  <li><b>ALB returns 503</b> — no healthy targets. If <code>kubectl get endpoints hello-world</code> is empty, the readiness probe is failing.</li>
  <li><b>HPA shows <code>&lt;unknown&gt;</code></b> — metrics-server not ready, or the Deployment is missing <code>resources.requests</code>.</li>
  <li><b>Cluster Autoscaler never scales</b> — missing ASG discovery tags on the node group.</li>
  <li><b><code>helm repo add</code> fails</b> — <code>aws.github.io</code> is blocked on some networks; use a phone hotspot.</li>
</ul>

<br />
