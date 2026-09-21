// ============================================================
// 项目 E · damo-app Jenkinsfile —— Helm 化改造版
//
// 对比项目 B（裸部署版）的变化：
//   Stage 4: sed 替换 __IMAGE__ + kubectl apply  →  helm upgrade --install --set image.tag
//   Stage 5: kubectl get pods                    →  kubectl get pods + helm history
//   Agent 容器: kubectl 容器                     →  helm 容器（dtzar/helm-kubectl 镜像，
//                同时含 helm 与 kubectl，Jenkins PodTemplate 需同步改名）
//   发布语义: apply 是"当前状态对齐"               →  upgrade 生成 revision，可 history/rollback，
//                且 --atomic 失败自动回滚（坏版本进不了"已发布"状态）
//
// 未变化：Stage 1-3（Checkout / Render / Kaniko Build）原样保留。
// 前置：Jenkins PodTemplate 的容器镜像换为 11.0.1.128:30000/helm-kubectl:3.19.1
//       （中转自 dtzar/helm-kubectl:3.19.1，Docker tag 无 v 前缀，见项目 E 文档阶段 2）。
// ============================================================

def REGISTRY = "11.0.1.128:30000"
def APP_NAME = "damo-app"
def NAMESPACE = "damo-app"
def CHART_DIR = "chart/damo-app"          // Chart 在仓库中的路径（随本 Chart 一起提交到仓库）

pipeline {
    agent { label 'ci-agent' }

    environment {
        // 镜像 tag = 构建号：不可变交付物，回滚/审计的锚点（与项目 B 同一设计）
        IMAGE_TAG = "${env.BUILD_NUMBER}"
        BUILD_TIME = sh(script: "date '+%Y-%m-%d %H:%M:%S'", returnStdout: true).trim()
    }

    stages {
        // ---------- Stage 1: 拉取代码 ----------
        stage('1. Checkout') {
            steps {
                checkout scm
                echo "代码已拉取，构建号: ${env.BUILD_NUMBER}"
            }
        }

        // ---------- Stage 2: 渲染页面占位符 ----------
        stage('2. Render Index') {
            steps {
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
                            --destination ${REGISTRY}/${APP_NAME}:${IMAGE_TAG} \
                            --insecure-registry ${REGISTRY} \
                            --skip-tls-verify
                    """
                }
            }
        }

        // ---------- Stage 4: Helm 发布（本项目核心改造点） ----------
        stage('4. Deploy via Helm') {
           steps {
        // ★ ① 外层包一层 withCredentials，container('helm') 放进去
               withCredentials([file(credentialsId: 'kubeconfig-damo-deployer', variable: 'KUBECONFIG')]) {
                  container('helm') {
                      sh """
                         helm upgrade --install damo-app chart/damo-app \
                         --namespace damo-app \
                         --set image.tag=${IMAGE_TAG} \
                         --atomic --timeout 120s
                         # ★ ② 删掉 --create-namespace（新 SA 只给了 namespaces 的 get，没有 create）
                         """
                     }
                 }
             }
         }

        // ---------- Stage 5: 验证 ----------
        stage('5. Verify') {
            steps {
                withCredentials([file(credentialsId: 'kubeconfig-damo-deployer', variable: 'KUBECONFIG')]){
                  container('helm') {
                      sh """
                          kubectl get pods -n ${NAMESPACE} -o wide
                          echo '---- Helm 发布历史 ----'
                          helm history damo-app -n ${NAMESPACE}
                          echo "---- 访问验证 ----"
                          echo "curl http://11.0.1.128:30090/ 应显示 Build #${env.BUILD_NUMBER}"
                      """
                  }
              }
          }
      }

    post {
        success {
            echo "✅ Helm 发布成功: ${REGISTRY}/${APP_NAME}:${IMAGE_TAG}"
            echo "访问: http://11.0.1.128:30090/"
        }
        failure {
            echo "❌ 发布失败；若在 Stage 4 失败，--atomic 已自动回滚到上一版本"
        }
    }
}
