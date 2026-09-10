# damo-app — K8s CI/CD 全自动交付流水线的演示应用

> 一个刻意做"简单"的静态页应用，用来把一整套云原生交付链路**跑通、跑稳、讲清楚**：
> **git push → Jenkins 动态 Agent → Kaniko 非特权构建 → 私有镜像仓库 → Helm 标准化发布 → 页面验证**，全程无人值守，约 3–5 分钟完成一次发布。

运行环境：自建三节点 Kubernetes 集群（1 master + 2 worker，v1.35 / containerd 2.x / Ubuntu 24.04）。

---

## 架构与数据流

```
 开发者                    Jenkins (K8s 内)                 三节点 K8s 集群
   │                            │                               │
   │ git push (index.html)      │ Poll SCM (每 5 min)           │
   ▼                            ▼                               │
 GitHub ──────────────► Jenkins Master :30080                   │
                                │ 按需拉起动态 Agent Pod           │
                                ▼                               │
                     ┌─────────────────────────┐                │
                     │  动态 Agent Pod（用完销毁） │                │
                     │  ├─ jnlp    控制通道        │                │
                     │  ├─ kaniko  镜像构建        │──push──►  私有仓库 registry :30000
                     │  └─ helm   集群发布        │
                     └─────────────────────────┘                │
                              helm upgrade --install --set image.tag=N --atomic
                                                  kubelet ──pull──┘ (containerd 私有源)
                                                     │
                                                     ▼
                                  Deployment damo-app ×2 ──► Service NodePort :30090
                                                     │
                                                     ▼
                                     页面显示 Build #N / 构建时间 → 肉眼验证发布
```

**页面即验收**：`index.html` 中的 `__BUILD_NUMBER__` / `__BUILD_TIME__` 由流水线渲染为真实值，访问 `:30090` 看到 `Build #N` 即表示"这次 push 的代码已经上线"。

## ✨ 亮点

- **全链路自动化**：代码提交到页面更新 3–5 分钟，无人工干预；`kubectl rollout status --timeout=120s` 卡住即流水线失败，坏版本进不去"已发布"状态。
- **Kaniko 非特权构建**：Pod 内直接构建镜像，不依赖 DinD 特权容器、不挂载 `docker.sock`，与节点运行时（containerd 2.x）完全解耦。
- **动态 Agent**：构建资源按需拉起、用完销毁，Jenkins Master 零闲置负载。
- **不可变交付物**：镜像 tag = Jenkins 构建号（`damo-app:2`、`damo-app:3`…），任何时刻可精确回滚，不存在 `latest` 漂移。
- **真实集群沉淀**：构建过程中踩过的 8 类故障全部有"现象 → 根因 → 修复 → 复盘"记录（见下文踩坑实录）。

## 🔧 关键技术决策

| 决策 | 选择 | 为什么 |
|------|------|--------|
| 构建工具 | Kaniko | DinD 需要特权容器（安全隐患）；挂 `docker.sock` 等于把宿主机 root 交出去且强绑 Docker 运行时。Kaniko 在用户态执行 `Dockerfile`，三者全避开 |
| Agent 模式 | 动态 Pod Agent（jnlp + kaniko + kubectl 三容器共享 workspace） | 静态从节点常年空跑、环境漂移；动态 Agent 每次构建都是干净环境，Job 结束即销毁 |
| 镜像 tag | `BUILD_NUMBER` 不可变 tag | `latest` 无法回滚、无法审计"线上到底跑的哪版"；构建号即版本，`imagePullPolicy: Always` 保证一定重新拉取 |
| 基础镜像 | `FROM <私有仓库>/nginx:1.27-alpine` | 国内节点直连 Docker Hub 拉不动，且 DNS 污染曾把域名解析到假 IP 导致 Kaniko 静默卡死——基础镜像私有化是根治解 |
| 触发方式 | Poll SCM（5 min） | 集群在内网，无公网回调入口，GitHub webhook 打不进来。说清限制与替代方案，比假装"配了 webhook"更诚实 |
| 探针 | 三探针全部 `tcpSocket` | 前序项目实测：`httpGet` 默认 1s 超时会误杀冷启动应用。探针管"进程存活"，页面健康交给监控 |
| 发布机制 | Helm Chart + `helm upgrade --install --set image.tag=N --atomic` | 裸 apply 时代的 sed 替换不可审计、回滚粒度粗；Chart 化后"发布=报一个参数"，天然获得 revision 发布台账、`helm rollback` 一键回退与失败自动回滚（`--atomic`）。手动跑通四种状态（install/upgrade/rollback/failed）后才交给流水线 |

## 🔄 流水线五阶段（对应 `Jenkinsfile`）

| Stage | 做什么 | 关键细节 |
|-------|--------|---------|
| 1. Checkout | `checkout scm` 拉代码 | 共享 workspace，三容器可见 |
| 2. Render Index | `sed` 渲染 `__BUILD_NUMBER__` / `__BUILD_TIME__` | 让"构建产物"自带版本指纹 |
| 3. Build Image | kaniko 容器执行 `/kaniko/executor` | `--insecure-registry` 对接内网 HTTP 仓库，产物 `damo-app:<BUILD_NUMBER>` |
| 4. Deploy via Helm | helm 容器执行 `helm upgrade --install --set image.tag=${BUILD_NUMBER} --atomic` | revision 台账可审计；120s 内未 Ready 自动回滚，坏版本进不了"已发布"状态 |
| 5. Verify | `kubectl get pods` + `helm history` | 副本分布、Ready 状态、发布台账一眼核验 |

## 📁 仓库结构

```
damo-app/
├── index.html          # 静态页（含构建号/时间占位符）
├── Dockerfile          # FROM 私有仓库 nginx:1.27-alpine，COPY 页面，EXPOSE 80
├── Jenkinsfile         # 声明式流水线：Checkout → Render → Kaniko Build → Helm Deploy → Verify
├── chart/damo-app/     # ★ Helm Chart（发布标准形态：templates + values 全参数化）
│   ├── Chart.yaml      # apiVersion v2 / version 与 appVersion 分离
│   ├── values.yaml     # 副本/镜像/探针/资源全参数化，流水线 --set image.tag 注入
│   └── templates/      # _helpers.tpl（标签三处同源）/ deployment / service / NOTES.txt
└── k8s/                # 前裸部署清单（保留作 Helm 化改造前的对照与回退预案）
    ├── deployment.yaml # 2 副本 / __IMAGE__ 占位 / 三探针 tcpSocket / 资源 requests+limits
    └── service.yaml    # NodePort :30090
```

## 🚀 复现指南（概要）

前置：一套可用的 K8s 集群（任意 ≥1.28 版本均可）+ 节点可访问的镜像仓库。

1. **私有仓库**：`registry:2` 部署进集群（NodePort），三节点 containerd 配置 insecure 私有源（2.x 用 `config_path` + `hosts.toml`），`crictl pull` 验证。
2. **Jenkins Master**：Deployment + SA/RBAC + PVC 方式部署，装 Kubernetes 插件并配置 Pod Template（jnlp 留空 Command + kaniko/kubectl 容器 `sleep infinity`，标签 `ci-agent`）。
3. **Pipeline Job**：SCM 指向本仓库 + Poll SCM；Agent label 填 `ci-agent`。
4. **发布**：`git push` 后等 Poll 命中，或手动 Build Now → 访问 `:30090` 看 Build #N。

> 完整分阶段手册（含每一步的验证命令与预期输出）见同目录项目实战文档。

## 🩹 踩坑实录（精选）

<details>
<summary><b>① Kaniko 构建静默卡死 —— DNS 污染 + Docker Hub 不可达</b></summary>

**现象**：Stage 3 长时间无输出，Pod 不退出也不报错。
**排查**：进 kaniko 容器看日志 + 在节点 `nslookup registry-1.docker.io` → 域名被解析到污染 IP。
**修复**：基础镜像 `docker pull` 后 tag/push 进私有仓库，Dockerfile 改 `FROM 11.0.1.128:30000/nginx:1.27-alpine`。
**复盘**：国内自建集群的镜像供应链必须"一次中转、全程私有化"，构建与运行用同一来源。
</details>

<details>
<summary><b>② 动态 Agent 起不来 —— jnlp Command 未留空</b></summary>

**现象**：Kubernetes Cloud 配置正确，但 Agent Pod 起来后立即退出。
**根因**：jnlp 容器的 Command 被显式设置，覆盖了 Jenkins 自动注入的启动参数，Agent 永远连不上 Master。
**修复**：jnlp 容器 **Args 与 Command 全部留空**；额外容器（kaniko/kubectl）用 `sleep infinity` 保活，由 jnlp 进程统一调度。
**复盘**：排障两大金标准——K8s 侧 `kubectl get events`，Jenkins 侧 grep `JNLP4-connect`。
</details>

<details>
<summary><b>③ Pod 反复重建 ≠ 容器反复重启</b></summary>

**现象**：Agent Pod RESTARTS 不涨，但 Pod 名一直变。
**根因**：Jenkins 的 Pod Reaper 认为"孤儿 Pod"循环删除并重建，和容器崩溃是两回事。
**修复**：修正 Cloud 模板配置（容器保活命令）后消失。
**复盘**：先分清是 **kubelet 在重启容器** 还是 **控制器在重建 Pod**，两者根因完全不同。
</details>

<details>
<summary><b>④ 探针 1s 超时误杀（源自前序项目 WordPress 实测）</b></summary>

**现象**：应用反复被 Killing，日志无异常。
**根因**：`httpGet` 探针默认 `timeoutSeconds: 1`，冷启动响应超时即判死。
**修复**：三个探针全部改 `tcpSocket`（本项目 deployment.yaml 即定版写法）。
**复盘**：探针的职责是"进程是否存活"，页面/接口健康交给监控与告警，不要让探针兼职。
</details>

## 🗺 Roadmap

- [x] **Helm 化**：`k8s/` 手写清单升级为 Chart，`helm upgrade --set image.tag=N --atomic` 替代 sed 替换（2026-09-10 完成全链路：手动验证 install/upgrade/rollback/failed 四状态 → 流水线自动化）
- [ ] **HPA**：基于 CPU 的自动扩缩容 + 压测演示
- [ ] **GitOps**：Argo CD 接管部署，Git 仓库成为唯一事实来源
- [ ] 演示 GIF：滚动更新 Build #N → #N+1 的页面变化

## 🧭 系列项目

这是"K8s 运维四部曲"的第 2 站，完整闭环：**应用容器化部署 → CI/CD 流水线（本项目）→ 监控告警 → 日志收集**。配套的 Prometheus/Grafana/Alertmanager 与 Fluent Bit/Loki 均部署在同一个三节点集群上，对本应用形成完整的可观测覆盖。
