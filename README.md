# Final task

## Installation

### Nginx ingress
Install Nginx ingress helm chart
```
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install nginx-ingress bitnami/nginx-ingress-controller
```

### Nextcloud

Create secrets with MySQL and Nextcloud admin credentials
```
kubectl create secret generic nextcloud-mysql --from-literal=username=nextcloud --from-literal=password=nextcloud
kubectl create secret generic nextcloud-admin --from-literal=username=admin --from-literal=password=admin123
```

Build docker image
```
export GCP_PROJECT=<your-gcp-project>
gcloud auth configure-docker
docker build -t gcr.io/${GCP_PROJECT}/nextcloud:21.0.1-apache nextcloud-docker/
docker push gcr.io/${GCP_PROJECT}/nextcloud:21.0.1-apache
```

Copy values.example.yaml to values.yaml and update it with proper values
```
cp values.example.yaml values.yaml
nano values.yaml
```

Install Nextcloud helm chart
```
helm repo add nextcloud https://nextcloud.github.io/helm/
helm install nextcloud nextcloud/nextcloud -f values.yaml
```
