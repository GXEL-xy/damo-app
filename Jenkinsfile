// ============================================================
// 项目 H · damo-app Jenkinsfile —— GitOps 分工版（CI only）
//
// 相对项目 E/F 的版本（Helm 部署版），只改两处：
//   Stage 4: helm upgrade --install ...        →  git commit + git push（只改 values-prod.yaml 的 tag 一行）
//   Stage 5: kubectl get pods / helm history   →  打印"已交接给 Argo CD"
//
// ★★ 为什么这么改：确立「每个资源只有一个写入者」
//   · 镜像                → Jenkins 写（Kaniko 推 registry）
//   · Git 里的期望状态     → Jenkins 写（只写 values-prod.yaml 的 image.tag 这一行）
//   · 集群里的实际状态     → Argo CD 写（唯一写入者）
//   · Deployment 副本数    → HPA 写（项目 G）
//   Jenkins 从此【不再持有 kubeconfig】，集群凭据不出集群 —— 项目 F 最小权限的延续。
//
// ★ 死循环防护（必须配，否则无限构建）：
//   回写的 commit 带 [skip ci]，同时在 Jenkins 里配置
//   Source Code Management → Additional Behaviours →
//   "Polling ignores commits with certain messages" = .*\[skip ci\].*
//
// ★ Stage 4 的两个必要条件：
//   ① 凭据 github-damo-app（Username with password，PAT 只给该仓库 Contents: Read and write）
//   ② 执行 sh 的容器里要有 git —— 默认的 jnlp 容器即可（checkout scm 就在它里面跑）
// ============================================================

def REGISTRY    = "11.0.1.128:30000"
def APP_NAME    = "damo-app"
def NAMESPACE   = "damo-app"
def PROD_VALUES = "chart/damo-app/values-prod.yaml"   // 镜像版本的唯一声明处
def REPO_URL    = "https://github.com/GXEL-xy/damo-app.git"

pipeline {
    agent { label 'ci-agent' }

    environment {
        // 镜像 tag = 构建号：不可变交付物，回滚/审计的锚点
        IMAGE_TAG  = "${env.BUILD_NUMBER}"
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

        // ---------- Stage 2: 渲染页面占位符（不变） ----------
        stage('2. Render Index') {
            steps {
                sh """
                    sed -i 's/__BUILD_NUMBER__/${env.BUILD_NUMBER}/g' index.html
                    sed -i 's/__BUILD_TIME__/${BUILD_TIME}/g' index.html
                """
            }
        }

        // ---------- Stage 3: Kaniko 构建镜像（不变） ----------
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

        // ---------- Stage 4: ★ 项目 H 核心改造 —— 把"部署"换成"回写 Git" ----------
        stage('4. Update GitOps Manifest') {
            steps {
                withCredentials([usernamePassword(
                        credentialsId:    'github-damo-app',
                        usernameVariable: 'GIT_USER',
                        passwordVariable: 'GIT_PASS')]) {
                    sh '''
                        set -e
                        # ★ 出网必须显式走代理（真实踩坑）：
                        #   Jenkins 日志里 "Setting http proxy: ..." 是 Git 插件在【它自己的】fetch 命令里
                        #   注入的 -c http.proxy，并不会变成容器里的环境变量；
                        #   手工执行的 git push 不继承它 → 直连 GitHub → Connection reset by peer。
                        export HTTP_PROXY=http://11.0.1.1:7890
                        export HTTPS_PROXY=http://11.0.1.1:7890
                        export NO_PROXY=localhost,127.0.0.1,11.0.1.128,10.244.0.0/16
                        git config user.name  "jenkins-bot"
                        git config user.email "jenkins-bot@ci.local"

                        echo "---- 改动前 ----"
                        grep -n "tag:" chart/damo-app/values-prod.yaml | head -3

                        # 只改 image.tag 这一行（两空格缩进、值带双引号），其它一律不动
                        sed -i 's/^  tag: .*/  tag: "'"${IMAGE_TAG}"'"/' chart/damo-app/values-prod.yaml

                        echo "---- 改动后 ----"
                        grep -n "tag:" chart/damo-app/values-prod.yaml | head -3

                        if git diff --quiet chart/damo-app/values-prod.yaml; then
                            echo "tag 未变化（${IMAGE_TAG} 已是当前值），本次跳过提交"
                        else
                            git add chart/damo-app/values-prod.yaml
                            git commit -m "ci: bump image.tag to ${IMAGE_TAG} [skip ci]"
                            git push "https://${GIT_USER}:${GIT_PASS}@github.com/GXEL-xy/damo-app.git" HEAD:main
                            echo "已回写 Git，等待 Argo CD 拉取"
                        fi
                    '''
                }
            }
        }

        // ---------- Stage 5: 交接说明（不再碰集群） ----------
        stage('5. Handover to Argo CD') {
            steps {
                echo "镜像已推送: ${REGISTRY}/${APP_NAME}:${IMAGE_TAG}"
                echo "期望状态已写入 Git: ${PROD_VALUES} -> image.tag=${IMAGE_TAG}"
                echo "★ Jenkins 到此结束，不执行任何 kubectl / helm 命令 —— 集群只由 Argo CD 写"
                echo "查看部署进度: kubectl -n argocd get application damo-app"
                echo "业务验证: curl -s http://11.0.1.129:30090/ | grep -o 'Build #[0-9]*'"
            }
        }
    }

    post {
        success {
            echo "CI 完成：镜像 ${IMAGE_TAG} 已推送，tag 已回写 Git"
            echo "CD 由 Argo CD 负责（默认 3 分钟内完成同步）"
        }
        failure {
            echo "CI 失败：镜像未推送或 tag 未回写，集群保持上一版本不变"
            echo "   —— 这正是 CI 与 CD 分界的好处：构建失败不会污染运行环境"
        }
    }
}
