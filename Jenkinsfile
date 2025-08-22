pipeline {
  agent any

  environment {
    // --- App / Image ---
    APP_NAME      = 'springboot-cicd-eks'
    APP_VERSION   = '0.0.1'
    REGISTRY      = 'docker.io/youruser'        // change for ECR: <aws_account>.dkr.ecr.<region>.amazonaws.com/<repo>
    IMAGE         = "${REGISTRY}/${APP_NAME}:${APP_VERSION}"

    // --- Kubernetes / AWS ---
    K8S_NAMESPACE = 'team-app'
    AWS_REGION    = 'ap-south-1'                // change if needed
    CLUSTER_NAME  = 'YOUR_EKS_CLUSTER_NAME'     // change to your EKS cluster name
  }

  options { timestamps() }

  tools {
    // Configure this name in Jenkins: Manage Jenkins → Global Tool Configuration → Maven
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
        sh 'mvn -B -DskipTests=false clean verify'
      }
      post {
        always {
          junit 'target/surefire-reports/*.xml'
        }
      }
    }

    stage('Package JAR') {
      steps {
        sh 'mvn -B -DskipTests package'
      }
      post {
        success {
          archiveArtifacts artifacts: 'target/*.jar', fingerprint: true
        }
      }
    }

    stage('Docker Build') {
      steps {
        sh 'docker build -t ${IMAGE} .'
      }
    }

    stage('Docker Push (Docker Hub)') {
      when { expression { env.REGISTRY.contains('docker.io') } }
      steps {
        withCredentials([usernamePassword(credentialsId: 'dockerhub-creds',
                                          usernameVariable: 'DOCKER_USER',
                                          passwordVariable: 'DOCKER_PASS')]) {
          sh 'echo $DOCKER_PASS | docker login -u $DOCKER_USER --password-stdin'
          sh 'docker push ${IMAGE}'
        }
      }
    }

    stage('Docker Push (ECR)') {
      when { expression { env.REGISTRY.contains('amazonaws.com') } }
      steps {
        sh 'aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${REGISTRY}'
        sh 'docker push ${IMAGE}'
      }
    }

    // >>> The single conditional deploy stage you asked for <<<
    stage('Deploy to Kubernetes') {
      steps {
        script {
          if (env.REGISTRY.contains('docker.io')) {
            // ===== Local (kind/minikube) =====
            // Assumes your kubeconfig already points to your local cluster.
            sh '''
              echo ">>> Deploying to local cluster with deployment-local.yaml"
              kubectl apply -f k8s/deployment-local.yaml
              echo ">>> (Optional) apply local service/ingress if you keep them separate"
              if [ -f k8s/service-local.yaml ]; then kubectl apply -f k8s/service-local.yaml; fi
              if [ -f k8s/ingress.yaml ]; then kubectl apply -f k8s/ingress.yaml; fi
            '''
          } else if (env.REGISTRY.contains('amazonaws.com')) {
            // ===== AWS EKS =====
            sh '''
              echo ">>> Configuring kubectl for EKS..."
              aws eks update-kubeconfig --region ${AWS_REGION} --name ${CLUSTER_NAME}

              echo ">>> Applying base resources to namespace ${K8S_NAMESPACE}..."
              kubectl apply -f k8s/namespace.yaml
              kubectl apply -f k8s/configmap.yaml
              kubectl apply -f k8s/secret.yaml

              echo ">>> Substituting image in deployment-eks.yaml..."
              sed -i "s|YOUR_REGISTRY/springboot-cicd-eks:0.0.1|${IMAGE}|" k8s/deployment-eks.yaml

              echo ">>> Applying deployment & service..."
              kubectl apply -f k8s/deployment-eks.yaml
              kubectl apply -f k8s/service.yaml

              echo ">>> Waiting for rollout..."
              kubectl rollout status deployment/${APP_NAME} -n ${K8S_NAMESPACE}
            '''
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
