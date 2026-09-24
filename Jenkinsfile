// ============================================================
// 项目 E · damo-app Jenkinsfile —— Helm 化改造版
// （项目 F 安全加固：Stage 4 增加 -f chart/damo-app/values-prod.yaml）
//
// 对比项目 B（裸部署版）的变化：
//   Stage 4: sed 替换 __IMAGE__ + kubectl apply  →  helm upgrade --install --set image.tag
//   Stage 5: kubectl get pods                    →  kubectl get pods + helm history
//   Agent 容器: kubectl 容器                     →  helm 容器（dtzar/helm-kubectl 镜像，
//                同时含 helm 与 kubectl，Jenkins PodTemplate 需同步改名）
//   发布语义: apply 是"当前状态对齐"               →  upgrade 生成 revision，可 history/rollback，
//                且 --atomic 失败自动回滚（坏版本进不了"已发布"状态）
//
// 项目 F 的变化（★ 只改了 Stage 4 一行参数 + 注释）：
//   加 `-f chart/damo-app/values-prod.yaml` —— 让日常发布也带上安全加固。
//   为什么必须加：加固开关 networkPolicy.enabled 默认是 false（保留"新人友好"默认），
//   生产配置固化在 values-prod.yaml 里。若不加这个 -f：
//     ① NetworkPolicy 不会渲染；
//     ② 更糟的是 —— Helm 发现上一次 manifest 有、这次没有 →【删除】那 5 条策略，
//        并把 externalTrafficPolicy 重置回 Cluster（规则① 失效、外部访问断）。
//        而且【不会报错】（Pod 照常起），--atomic 也救不了。
//        → 这就是"加固被流水线静默冲掉"。详见项目 F 实战文档 §4.7 / §4.7.5。
//
// 未变化：Stage 1-3（Checkout / Render / Kaniko Build）原样保留。
// 前置：Jenkins PodTemplate 的容器镜像换为 11.0.1.128:30000/helm-kubectl:3.19.1
//       （中转自 dtzar/helm-kubectl:3.19.1，Docker tag 无 v 前缀，见项目 E 文档阶段 2）。
// ============================================================

def REGISTRY = "11.0.1.128:30000"
def APP_NAME = "damo-app"
def NAMESPACE = "damo-app"
def CHART_DIR = "chart/damo-app"          // Chart 在仓库中的路径（随本 Chart 一起提交到仓库）
def PROD_VALUES = "chart/damo-app/values-prod.yaml"   // ★ 项目 F：生产 values（加固开关固化在此）

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
                         -f ${PROD_VALUES} \
                         --set image.tag=${IMAGE_TAG} \
                         --atomic --timeout 120s
                         # ★ ② 删掉 --create-namespace（新 SA 只给了 namespaces 的 get，没有 create）
                         # ★ ③ 项目 F：加 -f ${PROD_VALUES}
                         #     它把 networkPolicy.enabled: true / service.externalTrafficPolicy: Local
                         #     等生产配置固化在 git 里 —— 少了它，加固会被本次发布会静默删除。
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
                          echo '---- ★ 加固是否还在（项目 F 新增的验证项）----'
                          kubectl get netpol -n ${NAMESPACE}
                          kubectl get svc damo-app -n ${NAMESPACE} -o jsonpath='{.spec.externalTrafficPolicy}{"\\n"}'
                          echo "---- 访问验证 ----"
                          echo "curl http://11.0.1.129:30090/ 应显示 Build #${env.BUILD_NUMBER}（注意：Local 策略下要打有 Pod 的节点）"
                      """
                  }
              }
          }
      }
    }   // ★ 修复：关闭 stages 块 —— 原 Jenkinsfile 漏了这个右花括号，
        //   导致 Groovy 编译报错 "expecting right brace, found EOF"。
        //   post 必须是 pipeline 的直接子块，不能落在 stages 里面。

    post {
        success {
            echo "✅ Helm 发布成功: ${REGISTRY}/${APP_NAME}:${IMAGE_TAG}"
            echo "访问: http://11.0.1.129:30090/ 或 http://11.0.1.130:30090/（有 Pod 的节点）"
        }
        failure {
            echo "❌ 发布失败；若在 Stage 4 失败，--atomic 已自动回滚到上一版本"
        }
    }
}
