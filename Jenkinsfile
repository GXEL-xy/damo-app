def REGISTRY = "11.0.1.128:30000"          // master IP（已确认）
def APP_NAME = "damo-app"
def NAMESPACE = "damo-app"

pipeline {
    agent { label 'ci-agent' }

    environment {
        // 本次构建的完整镜像地址：11.0.1.128:30000/damo-app:<构建号>
        IMAGE = "${REGISTRY}/${APP_NAME}:${env.BUILD_NUMBER}"
        // 页面显示的构建时间
        BUILD_TIME = sh(script: "date '+%Y-%m-%d %H:%M:%S'", returnStdout: true).trim()
    }

    stages {
        // ---------- Stage 1: 拉取代码 ----------
        stage('1. Checkout') {
            steps {
                // 从 Job 的 SCM 配置里拉代码（git clone 到共享 workspace）
                checkout scm
                echo "代码已拉取，构建号: ${env.BUILD_NUMBER}"
            }
        }

        // ---------- Stage 2: 渲染页面占位符 ----------
        stage('2. Render Index') {
            steps {
                // 把 index.html 里的 __BUILD_NUMBER__ / __BUILD_TIME__ 替换成真实值
                sh """
                    sed -i 's/__BUILD_NUMBER__/${env.BUILD_NUMBER}/g' index.html
                    sed -i 's/__BUILD_TIME__/${BUILD_TIME}/g' index.html
                """
            }
        }

        // ---------- Stage 3: Kaniko 构建镜像 ----------
        stage('3. Build Image') {
            steps {
                container('kaniko') {
                    sh """
                        /kaniko/executor \
                            --context . \
                            --dockerfile Dockerfile \
                            --destination ${IMAGE} \
                            --insecure-registry ${REGISTRY} \
                            --skip-tls-verify
                    """
                }
            }
        }

        // ---------- Stage 4: 部署到 K8s ----------
        stage('4. Deploy to K8s') {
            steps {
                container('kubectl') {
                    sh """
                        # 创建/确保命名空间
                        kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
                        # 把 k8s/deployment.yaml 里的 __IMAGE__ 占位符替换为本次构建的镜像地址
                        sed -i 's|__IMAGE__|${IMAGE}|g' k8s/deployment.yaml
                        # 应用全部清单（相对路径，cwd 默认即共享 workspace）
                        kubectl apply -f k8s/
                        # 等待滚动更新完成（120 秒超时）
                        kubectl rollout status deployment/${APP_NAME} -n ${NAMESPACE} --timeout=120s
                    """
                }
            }
        }

        // ---------- Stage 5: 验证 ----------
        stage('5. Verify') {
            steps {
                container('kubectl') {
                    sh """
                        kubectl get pods -n ${NAMESPACE} -o wide
                        echo "---- 访问验证 ----"
                        echo "curl http://11.0.1.128:30090/ 应显示 Build #${env.BUILD_NUMBER}"
                    """
                }
            }
        }
    }

    post {
        success {
            echo "✅ 构建部署成功: ${IMAGE}"
            echo "访问: http://11.0.1.128:30090/"
        }
        failure {
            echo "❌ 构建失败，检查上述日志"
        }
    }
}
