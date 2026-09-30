#!/usr/bin/env bash
# ============================================================
# 项目 G · 一键采集展示项素材（文本类）
#
# 用法（在 master 上）：
#   bash collect-g-materials.sh              # 常规采集（G-1/G-2/G-3/G-5/G-8/G-11）
#   bash collect-g-materials.sh g6           # 展示项 G-6：零中断验证（约 2 分钟）
#   bash collect-g-materials.sh g7-before    # 展示项 G-7 前图：压测中（REPLICAS 高、冷却计时中）
#   bash collect-g-materials.sh g7-after     # 展示项 G-7 后图：冷却结束（已缩回 2）
#
# 产出：~/g-materials-<日期>/ 目录，内含各项的文本证据（.txt）
#
# ★ 仍需手工的 3 项：
#   G-4  扩容过程 GIF（ScreenToGif 录三终端：get pods -w / get hpa -w / 循环 curl）
#   G-9  Grafana 扩容曲线全屏截图
#   G-10 Grafana 大盘导出 JSON（Dashboard → Share → Export → Save to file）
#
# ★ 前置（G 文档「执行前必读」）：
#   ① loadgen.yaml 已删 nodeSelector（压力分散到 work1/work2）
#   ② 已临时关闭 Jenkins 定时触发器（否则观测会被发布打断）
#   ③ damo-app 的标签是 app.kubernetes.io/name=damo-app（★ 不是 app=damo-app）
# ============================================================
set -uo pipefail

OUT="$HOME/g-materials-$(date +%m%d-%H%M)"
mkdir -p "$OUT"
STAGE="${1:-base}"

APP_SEL="app.kubernetes.io/name=damo-app"
# 自动挑「有 Pod 的节点」（externalTrafficPolicy: Local 下必须打有 Pod 的节点，且要 --noproxy）
NODE="$(kubectl -n damo-app get pods -l "$APP_SEL" -o jsonpath='{.items[0].status.hostIP}' 2>/dev/null)"

snap() {  # snap <文件名> <命令...>
  local f="$OUT/$1"; shift
  { echo "# \$ $*"; echo "# 时间: $(date '+%F %T')"; "$@"; } > "$f" 2>&1
  echo "  ✅ $1"
}

echo "==> 采集目录: $OUT   （阶段: $STAGE）"
echo "==> 节点(有 Pod 的): ${NODE:-<未取到>}"
echo

# ---------- G-1 指标链路四道关 ----------
{
  echo "=== 关① APIService（★ HPA 读的就是它）==="
  kubectl get apiservice v1beta1.metrics.k8s.io
  echo; echo "=== 关② 节点指标 ==="
  kubectl top nodes
  echo; echo "=== 关③ Pod 指标（HPA 用的粒度）==="
  kubectl top pods -n damo-app
  echo; echo "=== 关④ 直接问 API ==="
  kubectl get --raw "/apis/metrics.k8s.io/v1beta1/namespaces/damo-app/pods" | head -c 500; echo
} > "$OUT/G1-metrics-ok.txt" 2>&1
echo "  ✅ G1-metrics-ok.txt   （★ 检查四道关是否全绿，截图改名 G1-metrics-ok.png）"

# ---------- G-2 一个开关，两种产物 ----------
{
  echo "=== HPA 关闭（Deployment 有 replicas、无 HPA）==="
  helm template damo-app ~/damo-app-chart -n damo-app --set autoscaling.enabled=false 2>&1 \
    | grep -nE "replicas:|kind: HorizontalPodAutoscaler"
  echo
  echo "=== HPA 打开（Deployment 无 replicas、有 HPA）★ replicas 消失是设计意图 ==="
  helm template damo-app ~/damo-app-chart -n damo-app --set autoscaling.enabled=true 2>&1 \
    | grep -nE "replicas:|kind: HorizontalPodAutoscaler"
} > "$OUT/G2-switch-on-off.txt" 2>&1
echo "  ✅ G2-switch-on-off.txt"

# ---------- G-3 HPA 就绪四要素 ----------
snap "G3-hpa-ready.txt" kubectl -n damo-app get hpa
{ echo; echo "=== Conditions（AbleToScale / ScalingActive / ScalingLimited）==="; \
  kubectl -n damo-app describe hpa damo-app | sed -n '/Conditions:/,/^$/p'; } >> "$OUT/G3-hpa-ready.txt" 2>&1
echo "  ✅ G3-hpa-ready.txt   （★ TARGETS 必须是 x%/75%，不能是 <unknown>）"

# ---------- G-5 扩容因果链（describe hpa 的 Events）----------
{ echo "=== 扩容因果链：时间 + reason + 新副本数 ==="; \
  kubectl -n damo-app describe hpa damo-app | sed -n '/Events:/,$p'; } > "$OUT/G5-rescale-events.txt" 2>&1
echo "  ✅ G5-rescale-events.txt   （★ 找 SuccessfulRescale 的 reason）"

# ---------- G-8 maxReplicas 边界 ----------
snap "G8-max-limit.txt" kubectl -n damo-app describe hpa damo-app

# ---------- G-11 helm history 发布台账 ----------
{ echo "=== helm history（发布审计台账，与项目 E 素材呼应）==="; \
  helm history damo-app -n damo-app; } > "$OUT/G11-helm-history.txt" 2>&1
echo "  ✅ G11-helm-history.txt"

# ---------- 业务可用性（对照：所有演示期间业务都应可用）----------
if [ -n "$NODE" ]; then
  { echo "=== 经 NodePort 打「有 Pod 的节点」（Local 策略下的正确姿势）==="; \
    curl --noproxy '*' -s --max-time 5 "http://$NODE:30090/" | grep -o 'Build #[0-9]*'; \
    echo; echo "=== 集群内直连 Service ==="; \
    kubectl -n damo-app exec deploy/loadgen -- sh -c \
      'wget -qO- --timeout=5 http://damo-app.damo-app.svc.cluster.local/ 2>&1 | head -2'; \
  } > "$OUT/availability.txt" 2>&1
  echo "  ✅ availability.txt"
else
  echo "  ⚠️ 未取到节点 IP，跳过 availability.txt"
fi

# ---------- 可选阶段 ----------
case "$STAGE" in
  g6)
    echo "==> G-6 零中断验证：600 次循环 curl（约 2 分钟，期间请勿停止 loadgen）"
    {
      echo "=== G-6 零中断：600 次循环 curl，统计成功/失败 ==="
      OK=0; FAIL=0
      for i in $(seq 1 600); do
        if curl --noproxy '*' -s --max-time 3 "http://$NODE:30090/" >/dev/null 2>&1; then
          OK=$((OK+1)); else FAIL=$((FAIL+1)); echo "  第 $i 次失败"
        fi
      done
      echo "成功: $OK   失败: $FAIL"
      echo "（失败 0 = 扩缩容全程零中断；★ 期望值见实战文档 §5.4）"
    } > "$OUT/G6-zero-downtime.txt" 2>&1
    echo "  ✅ G6-zero-downtime.txt"
    ;;
  g7-before)
    { echo "=== G-7 前图：压测中（REPLICAS 高、冷却计时中）==="; \
      date '+%F %T'; \
      kubectl -n damo-app get hpa; \
      kubectl -n damo-app get pods -l "$APP_SEL"; \
      kubectl -n damo-app describe hpa damo-app | sed -n '/Metrics:/,/Events:/p'; \
    } > "$OUT/G7-cooldown-before.txt" 2>&1
    echo "  ✅ G7-cooldown-before.txt   （★ 现在执行：kubectl -n damo-app scale deploy/loadgen --replicas=0）"
    ;;
  g7-after)
    { echo "=== G-7 后图：冷却结束（已缩回 2）★ 距停压应已过 5 分钟以上 ==="; \
      date '+%F %T'; \
      kubectl -n damo-app get hpa; \
      kubectl -n damo-app get pods -l "$APP_SEL"; \
      kubectl -n damo-app describe hpa damo-app | sed -n '/Events:/,$p'; \
    } > "$OUT/G7-cooldown-after.txt" 2>&1
    echo "  ✅ G7-cooldown-after.txt   （★ 期望 Events 里有 SuccessfulRescale 缩到 2 的记录）"
    ;;
esac

echo
echo "==> 完成。剩余手工项："
echo "    G-4  扩容过程 GIF（三终端并排录：get pods -w / get hpa -w / 循环 curl）"
echo "    G-9  Grafana 扩容曲线全屏截图"
echo "    G-10 Grafana 大盘导出 JSON"
echo "    （G-7 需按 before/after 各跑一次本脚本）"
