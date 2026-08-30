# Deploying a Containerized Application to AWS EKS with Terraform, Jenkins, and Argo CD

<h2>Description</h2>

This project deploys a Node.js web application to a production-style Amazon EKS cluster, with the entire infrastructure defined in Terraform and the delivery automated two different ways. The application is containerized with Docker, stored in Amazon ECR, packaged as a Helm chart, and exposed to the internet through an Application Load Balancer provisioned by the AWS Load Balancer Controller.

Two independent CI/CD pipelines deliver the same application from the same Helm chart. The `main` branch uses a push-based Jenkins pipeline that builds, pushes, and deploys. The `gitops` branch uses a pull-based model where GitHub Actions only writes to Git and Argo CD, running inside the cluster, reconciles the cluster toward what Git says. Both pipelines are functional and can be compared directly.

Autoscaling is implemented at two layers and verified under load: a HorizontalPodAutoscaler scaling pods 1 to 3 on CPU or memory utilization, and the Cluster Autoscaler scaling worker nodes 1 to 4 when pods can no longer be scheduled.

<br />

<h2>Live Application</h2>

<ul>
  <li><b>URL:</b> http://k8s-default-hellowor-1800b9d2ea-1139299927.us-east-1.elb.amazonaws.com</li>
  <li><b>Health check:</b> http://k8s-default-hellowor-1800b9d2ea-1139299927.us-east-1.elb.amazonaws.com/health</li>
  <li><b>Region:</b> us-east-1</li>
  <li><b>Cluster:</b> devops-ch2-cluster</li>
</ul>

<br />

<h2>Architecture</h2>

<b>Request path, end to end</b>

```
Internet
  → Application Load Balancer  (public subnets, 2 AZs)
    → Target Group             (target-type: ip)
      → Pod IP                 (worker node, private subnet)
        → Express process      (port 3000)
```

<b>Infrastructure</b>

```
VPC 10.0.0.0/16 (us-east-1)
├── Public subnets    10.0.3.0/24, 10.0.4.0/24   → ALB, NAT Gateway
├── Private subnets   10.0.1.0/24, 10.0.2.0/24   → EKS worker nodes
├── Internet Gateway
└── NAT Gateway (single, shared)                 → outbound only for private subnets

EKS cluster: devops-ch2-cluster (Kubernetes 1.34)
├── Managed control plane
├── Managed node group
│     ├── Instance type: t3.small
│     ├── Min / Desired / Max: 1 / 2 / 4
│     └── Add-ons: coredns, kube-proxy, vpc-cni
├── AWS Load Balancer Controller  (IRSA)  → creates and manages the ALB
├── Cluster Autoscaler            (IRSA)  → scales the node group
└── metrics-server                        → serves the Metrics API to the HPA

ECR repository: devops-challenge-2-app
├── Image scanning on push
└── Lifecycle policy: keep the last 5 tagged images

IAM roles
├── devops-challenge-2-aws-load-balancer-controller   (IRSA)
├── devops-challenge-2-cluster-autoscaler             (IRSA)
└── devops-challenge-2-github-actions                 (GitHub OIDC, gitops branch only)
```

<b>Repository layout</b>

```
.
├── index.js                     Express application
├── package.json
├── Dockerfile                   Application image (node:16)
├── Jenkinsfile                  Four-stage pipeline
├── jenkins/
│     └── Dockerfile             Jenkins image + Docker CLI, AWS CLI v2, kubectl, Helm
├── terraform/
│     ├── provider.tf
│     ├── variables.tf
│     ├── vpc.tf
│     ├── eks.tf
│     ├── ecr.tf
│     ├── iam.tf
│     ├── iam-gitops.tf          gitops branch only
│     └── outputs.tf
├── helm/hello-world/
│     ├── Chart.yaml
│     ├── values.yaml
│     └── templates/
│           ├── deployment.yaml
│           ├── service.yaml
│           ├── ingress.yaml
│           └── hpa.yaml
├── argocd/application.yaml      gitops branch only
└── .github/workflows/ci.yml     gitops branch only
```

<br />

<h2>Prerequisites</h2>

<ol>
  <li>AWS CLI v2, configured with credentials that can create VPC, EKS, IAM, and ECR resources</li>
  <li>Terraform 1.5 or later</li>
  <li>kubectl 1.28 or later</li>
  <li>Helm 3</li>
  <li>Docker Desktop or Docker Engine, running before any build</li>
  <li>Node.js 16
    <ul>
      <li>Run <code>nvm use 16</code> before any npm command.</li>
      <li>Both <code>Dockerfile</code> and <code>jenkins/Dockerfile</code> pin <code>node:16</code>. Running <code>npm ci</code> under a different major version produces a lockfile that will not install cleanly inside the image.</li>
    </ul>
  </li>
  <li>hey, optional, for the load test: <code>brew install hey</code></li>
</ol>

<br />

<h2>Step 1: Run the Application Locally</h2>

<ol>
  <li>Clone the repository and install dependencies under Node 16.</li>
</ol>

```bash
git clone https://github.com/SomoneL/devops-tech-challenge-2.git
cd devops-tech-challenge-2
nvm use 16
npm ci
node index.js
```

<ol start="2">
  <li>In a second terminal, confirm both routes respond.</li>
</ol>

```bash
curl http://localhost:3000          # → Hello, World!
curl http://localhost:3000/health   # → OK
```

<ul>
  <li><code>/</code> returns the Hello World response the challenge requires.</li>
  <li><code>/health</code> is a dedicated endpoint for the ALB health check and the Kubernetes liveness and readiness probes. Keeping it separate means a passing probe indicates the process is genuinely healthy, rather than a catch-all route matching every path.</li>
  <li>The port is read from <code>process.env.PORT</code> with a fallback to 3000, so the same image runs locally and in any container environment that sets the variable differently.</li>
</ul>

<br />

<h2>Step 2: Provision the Infrastructure with Terraform</h2>

<ol>
  <li>Initialize, review the plan, and apply.</li>
</ol>

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

<ol start="2">
  <li>Expect 15 to 20 minutes. The control plane comes up first; the managed node group takes another 5 to 10 minutes after that. Do not interrupt it.</li>
  <li>Configure kubectl and verify the cluster.</li>
</ol>

```bash
aws eks --region us-east-1 update-kubeconfig --name devops-ch2-cluster
kubectl get nodes
kubectl get pods -A
```

<ul>
  <li>Nodes should report <code>Ready</code>.</li>
  <li>The <code>kube-system</code> pods (coredns, kube-proxy, aws-node) should be <code>Running</code>.</li>
</ul>

<br />

<h2>Step 3: Install the AWS Load Balancer Controller</h2>

<ol>
  <li>Create and annotate the ServiceAccount <b>before</b> installing the chart. A pod's AWS identity is injected by a mutating webhook at creation time, so pods created before the annotation exists start with no credentials and crash-loop.</li>
</ol>

```bash
kubectl create serviceaccount aws-load-balancer-controller -n kube-system

kubectl annotate serviceaccount aws-load-balancer-controller -n kube-system \
  eks.amazonaws.com/role-arn=$(cd terraform && terraform output -raw load_balancer_controller_role_arn)
```

<ol start="2">
  <li>Add the chart repository and install the controller.</li>
</ol>

```bash
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

<ol start="3">
  <li>Confirm two controller pods are running. Two replicas run for high availability, with a leader election between them.</li>
</ol>

```bash
kubectl get pods -n kube-system | grep aws-load-balancer-controller
```

<ul>
  <li><code>serviceAccount.create=false</code> matters. Miss it and Helm creates a second, unannotated ServiceAccount, the pods get no IAM role, and the controller logs fill with AccessDenied.</li>
  <li>Passing <code>vpcId</code> explicitly is optional but removes a failure mode. The controller can auto-discover it, but not always cleanly.</li>
</ul>

<br />

<h2>Step 4: Install the Cluster Autoscaler and metrics-server</h2>

<ol>
  <li>Same annotate-before-install ordering as the previous step.</li>
</ol>

```bash
kubectl create serviceaccount cluster-autoscaler -n kube-system

kubectl annotate serviceaccount cluster-autoscaler -n kube-system \
  eks.amazonaws.com/role-arn=$(cd terraform && terraform output -raw cluster_autoscaler_role_arn)
```

<ol start="2">
  <li>Install both charts.</li>
</ol>

```bash
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

<ol start="3">
  <li>Verify. Give metrics-server a minute after install; the first <code>kubectl top</code> often returns nothing until it has completed a scrape cycle.</li>
</ol>

```bash
kubectl logs -n kube-system deploy/cluster-autoscaler | grep -i "node group"
kubectl top nodes
kubectl top pods
```

<ul>
  <li>metrics-server scrapes CPU and memory from each node's kubelet and serves them through the Kubernetes Metrics API. The HPA reads that API, not Prometheus and not CloudWatch. Without it the HPA has no data source and its TARGETS column reads <code>&lt;unknown&gt;</code> permanently.</li>
  <li>The Cluster Autoscaler discovers Auto Scaling Groups by tag. The node group carries <code>k8s.io/cluster-autoscaler/enabled</code> and <code>k8s.io/cluster-autoscaler/devops-ch2-cluster = owned</code>. Without those tags it runs happily and manages nothing, with no error.</li>
</ul>

<br />

<h2>Step 5: Deploy the Application</h2>

<ol>
  <li>The Jenkins pipeline does this automatically on every commit. To deploy manually:</li>
</ol>

```bash
ECR_REPO=$(cd terraform && terraform output -raw ecr_repository_url)

helm upgrade --install hello-world ./helm/hello-world \
  --set image.repository=$ECR_REPO \
  --set image.tag=<tag> \
  --wait --timeout 3m
```

<ol start="2">
  <li>Watch the Ingress until an address appears. The controller needs two to three minutes to create the ALB, target group, and listener, and for AWS to bring it to active.</li>
</ol>

```bash
kubectl get pods
kubectl get hpa
kubectl get ingress hello-world -w
```

<ol start="3">
  <li>Hit the load balancer.</li>
</ol>

```bash
ALB_URL=$(kubectl get ingress hello-world -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://$ALB_URL/
curl http://$ALB_URL/health
```

<br />

<h2>Explanation of the Terraform Code</h2>

<ul>
  <li><code>provider.tf</code> — AWS provider pinned to <code>~&gt; 5.0</code> and Kubernetes provider to <code>~&gt; 2.0</code>. The pessimistic constraint allows patch and minor updates within 5.x but never 6.0, so a build that worked last month does not break today.</li>
  <li><code>variables.tf</code> — region, project name, VPC CIDR, cluster name and version, node instance type and sizing, and application port. Every value used more than once lives here.</li>
  <li><code>vpc.tf</code> — the <code>terraform-aws-modules/vpc/aws</code> module builds two availability zones with public and private subnets, an Internet Gateway, and a single shared NAT Gateway.</li>
  <li><code>eks.tf</code> — the <code>terraform-aws-modules/eks/aws</code> module builds the control plane, the managed node group, and the three core add-ons. <code>cluster_endpoint_public_access</code> is enabled so kubectl works from a workstation without a VPN.</li>
  <li><code>ecr.tf</code> — the image repository, with scanning on push and a lifecycle policy that expires all but the last five tagged images.</li>
  <li><code>iam.tf</code> — IRSA roles for the AWS Load Balancer Controller and the Cluster Autoscaler, using the <code>iam-role-for-service-accounts-eks</code> module.</li>
  <li><code>iam-gitops.tf</code> — the GitHub OIDC trust relationship and the role GitHub Actions assumes. Present only on the gitops branch.</li>
  <li><code>outputs.tf</code> — cluster name and endpoint, ECR repository URL, region, VPC ID, and the IRSA role ARNs. Outputs are the supported way to get a value out of state; no ARN is ever copied by hand from the console.</li>
</ul>

<b>Why community modules rather than hand-written resources</b>

EKS has networking requirements that are easy to get silently wrong. The most important is subnet tagging: <code>public_subnet_tags</code> sets <code>kubernetes.io/role/elb = 1</code> and <code>private_subnet_tags</code> sets <code>kubernetes.io/role/internal-elb = 1</code>. The AWS Load Balancer Controller uses those tags to find somewhere to place an internet-facing ALB. Without them the Ingress simply never receives an address, and nothing errors.

<b>Why IRSA rather than node-role permissions</b>

Attaching the load balancer policy to the node group's IAM role would give every pod on every node permission to create load balancers. IRSA scopes the permission to a single ServiceAccount instead. The cluster's OIDC provider issues the pod a signed JWT, STS exchanges that token for temporary credentials for the named role, and the trust policy pins it to one namespace and service account. The credentials are short-lived, rotated automatically, and no access key exists anywhere in the system.

<br />

<h2>Explanation of the Helm Chart</h2>

`helm/hello-world` is the single source of truth for the workload and is used unchanged by both delivery pipelines.

<ul>
  <li><code>deployment.yaml</code> — pod spec, liveness and readiness probes against <code>/health</code>, and resource requests (100m CPU, 128Mi) and limits (250m CPU, 256Mi).</li>
  <li><code>service.yaml</code> — ClusterIP service, port 80 forwarding to targetPort 3000.</li>
  <li><code>ingress.yaml</code> — ALB Ingress: internet-facing scheme, <code>target-type: ip</code>, health check path <code>/health</code>.</li>
  <li><code>hpa.yaml</code> — HorizontalPodAutoscaler, 1 to 3 replicas, triggering at 50% CPU or 50% memory utilization.</li>
</ul>

Two details worth calling out:

<ol>
  <li><b>replicas is omitted from the Deployment when autoscaling is enabled.</b> If the template always set it, every <code>helm upgrade</code> the pipeline runs would reset the replica count to 1 and fight the HPA.</li>
  <li><b>Resource requests are required for the HPA to function.</b> Utilization is a percentage of the request, so with no request there is no denominator and the HPA reports <code>&lt;unknown&gt;</code> indefinitely.</li>
</ol>

Only two values are overridden per deploy: <code>image.repository</code> and <code>image.tag</code>.

<br />

<h2>Explanation of the Jenkins Pipeline</h2>

Jenkins runs in a container built from `jenkins/Dockerfile`, which adds the four tools the base image lacks: the Docker CLI (builds run against the host daemon through the mounted socket), AWS CLI v2, kubectl, and Helm.

<ol>
  <li>Build and run the Jenkins image.</li>
</ol>

```bash
docker build -t jenkins-devops -f jenkins/Dockerfile jenkins/

docker run -d --name jenkins \
  -p 8080:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  jenkins-devops
```

<ol start="2">
  <li>Retrieve the initial admin password, open <code>localhost:8080</code>, install the suggested plugins, then add <b>Docker Pipeline</b> and <b>AWS Credentials</b>.</li>
</ol>

```bash
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

<ol start="3">
  <li>Add two credentials under Manage Jenkins → Credentials.
    <ul>
      <li><code>aws-creds</code> — AWS Credentials type, using an access key scoped to ECR push/pull and <code>eks:DescribeCluster</code>. Not a root or admin key.</li>
      <li><code>github-creds</code> — Username with password, using a Personal Access Token, since the repository is private.</li>
    </ul>
  </li>
  <li>Create a Pipeline job with Definition set to <b>Pipeline script from SCM</b>, SCM set to Git, branch specifier <code>*/main</code>, and script path <code>Jenkinsfile</code>.</li>
</ol>

<b>What each stage produces</b>

<ol>
  <li><b>Checkout</b> — pulls the commit under build via <code>checkout scm</code>.</li>
  <li><b>Build Docker Image</b> — builds <code>$ECR_REPO:$BUILD_NUMBER</code> against the mounted Docker daemon.</li>
  <li><b>Push to ECR</b> — authenticates with <code>aws ecr get-login-password</code> and pushes the tagged image.</li>
  <li><b>Deploy to EKS</b> — refreshes the kubeconfig, then runs <code>helm upgrade --install</code> with the new image tag and <code>--wait --timeout 3m</code> so the stage fails if the rollout does not become healthy.</li>
</ol>

Images are tagged with the build number rather than <code>latest</code>. A mutable <code>latest</code> tag makes rollbacks guesswork and makes it impossible to tell from the cluster which build is actually running.

<br />

<h2>Explanation of the GitOps Pipeline</h2>

The `gitops` branch delivers the same application with an inverted trust model.

The Jenkins pipeline is <b>push-based</b>: Jenkins holds cluster credentials and reaches into the API server from outside. The GitOps pipeline is <b>pull-based</b>: GitHub Actions only builds the image and writes the new tag into Git, and Argo CD, running inside the cluster, is the only component with deploy permissions. The CI system holds no cluster credentials at all.

<b>GitHub Actions — <code>.github/workflows/ci.yml</code></b>

<ol>
  <li>Authenticates to AWS with OIDC rather than a stored access key. The IAM trust policy pins the <code>sub</code> claim to this repository <i>and</i> the gitops branch, so a fork or a pull request cannot mint credentials.</li>
  <li>Builds the image and pushes it to ECR, tagged with the commit SHA so the running image traces directly back to a commit.</li>
  <li>Rewrites <code>image.tag</code> in <code>helm/hello-world/values.yaml</code> and commits it back to the branch. That commit is the workflow's final act; it never calls kubectl or helm.</li>
</ol>

The workflow's IAM role carries <code>AmazonEC2ContainerRegistryPowerUser</code> and nothing else, deliberately no EKS permissions. The <code>paths:</code> filter on the trigger is load-bearing: without it, the workflow's own values commit re-triggers the workflow and produces an infinite build loop.

<b>Argo CD — <code>argocd/application.yaml</code></b>

<ol>
  <li>Install Argo CD and apply the Application manifest.</li>
</ol>

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server
kubectl apply -f argocd/application.yaml
```

<ol start="2">
  <li>Access the UI over a port-forward. No ingress and no public exposure; the tunnel dies when you stop it.</li>
</ol>

```bash
kubectl port-forward svc/argocd-server -n argocd 8081:443
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

The Application watches <code>targetRevision: gitops</code> at path <code>helm/hello-world</code>, with <code>selfHeal: true</code> and <code>prune: true</code>. Self-healing was verified directly: running <code>kubectl scale deploy hello-world --replicas=5</code> is reverted by Argo CD on the next reconciliation, because Git rather than the cluster is the source of truth.

<br />

<h2>Autoscaling and Load Test Results</h2>

Two systems, chained rather than alternative:

<ul>
  <li><b>Pods</b> — the HorizontalPodAutoscaler watches per-pod CPU and memory as a percentage of requests, scaling 1 to 3.</li>
  <li><b>Nodes</b> — the Cluster Autoscaler watches for pods stuck in <code>Pending</code> with nowhere to schedule, scaling 1 to 4.</li>
</ul>

The HPA raises the replica count. Those pods schedule until no node has allocatable CPU left, at which point they sit <code>Pending</code>. Pending is the handoff signal, not an error, and the Cluster Autoscaler responds by calling <code>SetDesiredCapacity</code> on the Auto Scaling Group.

<b>Test</b>

```bash
ALB_URL=$(kubectl get ingress hello-world -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
hey -z 8m -c 100 http://$ALB_URL/
```

Eight minutes at 100 concurrent connections. Duration matters: the HPA evaluates every 15 seconds and the Cluster Autoscaler needs minutes to bring up a node, so a short burst proves nothing.

<b>Results</b>

<ul>
  <li><b>Requests served:</b> 824,096 responded HTTP 200, 1 responded HTTP 502</li>
  <li><b>Throughput:</b> approximately 1,716 requests per second</li>
  <li><b>Latency:</b> 58 ms average, 93 ms at p95, 162 ms at p99</li>
  <li><b>HPA at peak:</b> CPU at 213% against the 50% target</li>
  <li><b>Pods:</b> scaled 1 to 3</li>
  <li><b>Nodes:</b> scaled 1 to 2, with the new node reaching <code>Ready</code> in roughly three minutes</li>
</ul>

Scale-down is deliberately slower than scale-up. The HPA waits out a five-minute stabilization window, and the Cluster Autoscaler wants roughly ten minutes of low utilization before it drains a node. The asymmetry is intentional: being under-provisioned drops traffic, while scaling down too eagerly causes thrashing, where capacity is removed and immediately needed again.

<br />

<h2>Design Decisions</h2>

<ol>
  <li><b>Managed node groups rather than self-managed.</b> AWS handles AMI updates, draining, and replacing unhealthy instances. Self-managed nodes are only worth the operational cost when you need control the managed group does not expose.</li>
  <li><b>IRSA rather than node-role IAM policies.</b> Scopes permissions to a single workload instead of every pod on the node, with short-lived, automatically rotated credentials and no stored keys.</li>
  <li><b>ALB Ingress rather than a LoadBalancer Service.</b> A LoadBalancer Service creates one network load balancer per service with no path routing, host rules, or shared listeners. The ALB Ingress gives layer 7 routing and a single load balancer across many services.</li>
  <li><b>Image tagged with the build number or commit SHA, never latest.</b> Every running pod traces back to a specific build. A mutable tag makes rollback guesswork and breaks image pull caching semantics.</li>
  <li><b>Terraform community modules rather than hand-written resources.</b> The EKS and VPC modules encode subnet tagging and IAM wiring that is easy to get silently wrong from scratch.</li>
  <li><b>Two pipelines on two branches.</b> Lets the push-based and pull-based delivery models be compared directly against the same application and the same Helm chart.</li>
  <li><b>A dedicated /health route.</b> Keeps the health check independent of application routing, so a passing probe means the process is genuinely healthy rather than a catch-all matching every path.</li>
</ol>

<br />

<h2>Teardown</h2>

Order matters here.

<ol>
  <li>Remove anything that created AWS resources outside Terraform's state.</li>
</ol>

```bash
helm uninstall hello-world
helm uninstall aws-load-balancer-controller -n kube-system
helm uninstall cluster-autoscaler -n kube-system
helm uninstall metrics-server -n kube-system
```

<ol start="2">
  <li>Then destroy the infrastructure.</li>
</ol>

```bash
cd terraform
terraform destroy
```

The ALB was created by the Load Balancer Controller, not by Terraform, so it does not exist in Terraform state and <code>terraform destroy</code> does not know it is there. Its network interfaces are attached to the VPC subnets, and AWS will not delete a subnet with a live ENI in it. Run destroy first and it gets partway through the VPC and hangs. Uninstalling the Helm releases deletes the Ingress, which makes the controller tear down the ALB it owns, which frees the ENIs.

The general rule: anything a Kubernetes controller provisions in AWS lives outside your infrastructure-as-code state and has to be removed before the IaC teardown.

<br />

<h2>Troubleshooting Notes</h2>

Issues encountered while building this, and what they actually were:

<ol>
  <li><b><code>no match for platform in manifest</code> leading to ImagePullBackOff.</b> Images were built on an arm64 Mac against amd64 EKS nodes. Fixed by building with <code>--platform linux/amd64</code> and making the Jenkins image's kubectl and AWS CLI downloads architecture-aware.</li>
  <li><b>Permission denied on <code>/var/run/docker.sock</code> during a build.</b> The jenkins user cannot read the mounted socket. Resolved with <code>docker exec -u root jenkins chmod 666 /var/run/docker.sock</code>.</li>
  <li><b>Jenkins checkout found no branch.</b> The Git SCM branch specifier defaults to <code>*/master</code>; this repository uses <code>main</code>.</li>
  <li><b>Pipeline failed on credential lookup.</b> The <code>aws-creds</code> credential ID referenced in the Jenkinsfile must match the ID configured in Jenkins exactly.</li>
  <li><b>kubectl from Jenkins returned an authorization error.</b> IAM authenticates, Kubernetes RBAC authorizes. The <code>jenkins-ci</code> IAM user needed an EKS access entry in addition to its IAM policy.</li>
  <li><b>Ingress ADDRESS never populated.</b> Subnet tagging. The controller logs state the problem in plain English; look for "unable to discover subnets".</li>
  <li><b>ALB returned 503.</b> The load balancer is up but has no healthy targets. <code>kubectl get endpoints hello-world</code> returning empty means the readiness probe is failing.</li>
  <li><b>HPA TARGETS showed <code>&lt;unknown&gt;</code>.</b> Either metrics-server was not ready yet, or the Deployment was missing <code>resources.requests</code>.</li>
  <li><b>Cluster Autoscaler ran but never scaled.</b> Missing Auto Scaling Group discovery tags on the node group.</li>
  <li><b><code>helm repo add</code> failed on a restricted network.</b> <code>aws.github.io</code> is blocked on some corporate wifi. Fetching chart repositories over a phone hotspot resolved it.</li>
</ol>

<br />

<h2>Submission</h2>

<ul>
  <li>Private GitHub repository, shared with the mentor as a collaborator</li>
  <li>Live application URL listed at the top of this document</li>
  <li>Both branches functional and independent: <code>main</code> deploys through Jenkins, <code>gitops</code> deploys through GitHub Actions and Argo CD</li>
</ul>
