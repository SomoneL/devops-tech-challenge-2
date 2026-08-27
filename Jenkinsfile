pipeline {
  agent any
  environment {
    AWS_REGION   = 'us-east-1'
    ECR_REPO     = '318630425437.dkr.ecr.us-east-1.amazonaws.com/devops-challenge-2-app'
    CLUSTER_NAME = 'devops-ch2-cluster'
    IMAGE_TAG    = "${env.BUILD_NUMBER}"
  }
  stages {
    stage('Checkout') {
      steps { checkout scm }
    }
    stage('Build Docker Image') {
      steps {
        sh 'docker build -t $ECR_REPO:$IMAGE_TAG .'
      }
    }
    stage('Push to ECR') {
      steps {
        withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-creds']]) {
          sh '''
            aws ecr get-login-password --region $AWS_REGION | \
              docker login --username AWS --password-stdin $ECR_REPO
            docker push $ECR_REPO:$IMAGE_TAG
          '''
        }
      }
    }
    stage('Deploy to EKS') {
      steps {
        withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-creds']]) {
          sh '''
            aws eks --region $AWS_REGION update-kubeconfig --name $CLUSTER_NAME
            helm upgrade --install hello-world ./helm/hello-world \
              --set image.repository=$ECR_REPO \
              --set image.tag=$IMAGE_TAG \
              --wait --timeout 3m
          '''
        }
      }
    }
  }
}
