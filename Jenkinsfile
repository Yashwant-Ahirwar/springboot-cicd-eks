pipeline {
  agent any

  environment {
    // --- App / Image ---
    APP_NAME      = 'springboot-cicd-eks'
    APP_VERSION   = '0.0.1'
    REGISTRY      = 'docker.io/youruser'   // for AWS: <aws_account>.dkr.ecr.<region>.amazonaws.com/<repo>
    IMAGE         = "${REGISTRY}/${APP_NAME}:${APP_VERSION}"

    // --- Kubernetes / AWS ---
    K8S_NAMESPACE = 'team-app'
    AWS_REGION    = 'ap-south-1'
    CLUSTER_NAME  = 'YOUR_EKS_CLUSTER_NAME'
  }

  options { timestamps() }

  tools {
    maven 'Maven_3.9.8'
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Maven Build & Test') {
      steps {
        sh "mvn -B -DskipTests=false clean verify"
      }
      post {
        always {
          junit 'target/surefire-reports/*.xml'
        }
      }
    }

    stage('Package JAR') {
      steps {
        sh "mvn -B -DskipTests package"
      }
      post {
        success {
          archiveArtifacts artifacts: 'target/*.jar', fingerprint: true
        }
      }
    }

    stage('Docker Build') {
      steps {
        sh "docker build -t ${IMAGE} ."
      }
    }

    stage('Docker Push (Docker Hub)') {
      when { expression { env.REGISTRY.contains('docker.io') } }
      steps {
        withCredentials([usernamePassword(credentialsId: 'dockerhub-creds',
                                          usernameVariable: 'DOCKER_USER',
                                          passwordVariable: 'DOCKER_PASS')]) {
          sh """
            echo \$DOCKER_PASS | docker login -u \$DOCKER_USER --password-stdin
            docker push ${IMAGE}
          """
        }
      }
    }

    stage('Docker Push (ECR)') {
      when { expression { env.REGISTRY.contains('amazonaws.com') } }
      steps {
        sh """
          aws ecr get-login-password --region ${AWS_REGION} \
            | docker login --username AWS --password-stdin ${REGISTRY}
          docker push ${IMAGE}
        """
      }
    }

    stage('Deploy to Kubernetes') {
      steps {
        script {
          if (env.REGISTRY.contains('docker.io')) {
            // --- Local cluster (kind/minikube) ---
            sh """
              echo ">>> Deploying to local cluster with deployment-local.yaml"
              kubectl apply -f k8s/deployment-local.yaml
              if [ -f k8s/service-local.yaml ]; then kubectl apply -f k8s/service-local.yaml; fi
              if [ -f k8s/ingress.yaml ]; then kubectl apply -f k8s/ingress.yaml; fi
            """
          } else if (env.REGISTRY.contains('amazonaws.com')) {
            // --- AWS EKS ---
            sh """
              echo ">>> Configuring kubectl for EKS..."
              aws eks update-kubeconfig --region ${AWS_REGION} --name ${CLUSTER_NAME}

              echo ">>> Ensuring namespace exists..."
              kubectl create namespace ${K8S_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

              echo ">>> Applying configs..."
              kubectl apply -f k8s/configmap.yaml -n ${K8S_NAMESPACE}
              kubectl apply -f k8s/secret.yaml -n ${K8S_NAMESPACE}

              echo ">>> Substituting image in deployment-eks.yaml..."
              sed -i "s|YOUR_REGISTRY/springboot-cicd-eks:0.0.1|${IMAGE}|" k8s/deployment-eks.yaml

              echo ">>> Applying deployment & service..."
              kubectl apply -f k8s/deployment-eks.yaml -n ${K8S_NAMESPACE}
              kubectl apply -f k8s/service.yaml -n ${K8S_NAMESPACE}

              echo ">>> Waiting for rollout..."
              kubectl rollout status deployment/${APP_NAME} -n ${K8S_NAMESPACE}
            """
          } else {
            error "Unrecognized REGISTRY: ${env.REGISTRY}"
          }
        }
      }
    }
  }

  post {
    success { echo '✅ Build & Deploy completed successfully.' }
    failure { echo '❌ Build or Deploy failed. Check stage logs.' }
  }
}
