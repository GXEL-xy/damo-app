{{- /* ============================================================
项目 E · damo-app Helm Chart —— 可复用模板片段（_helpers.tpl）

_helpers.tpl 不渲染出任何 K8s 资源，它只是一本"函数手册"：
define 定义函数，include 在别处调用。为什么要抽出来？
—— Deployment 和 Service 的 labels、selector 必须逐字一致，
   写两遍早晚改一处漏一处（经典坑：Endpoints 为空）。
   收敛成一个函数，两处 include，永不失配。

Go template 语法速记：
  {{- ... }}   左边的 - 表示"吃掉前面的空白/换行"（渲染整齐的关键）
  .Values      values.yaml 的值      .Chart  Chart.yaml 的元数据
  .Release     本次安装的信息（Name/Namespace/Service/Revision）
============================================================ */ -}}

{{- /* name：Chart 短名（可被 values.nameOverride 覆盖）———— */ -}}
{{- define "damo-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{- /* fullname：资源实际用的名字 = Release 名相关组合
     本项目 Release 名就叫 damo-app，contains 分支命中 → fullname=damo-app，
     与项目 B 裸部署的资源名完全一致，升级无缝。 */ -}}
{{- define "damo-app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end -}}

{{- /* selectorLabels：Service.selector 与 Pod labels 的"共同基因"
     ★ 这两个键必须完全一致，否则 Endpoints 为空、Service 404。
     官方推荐标签：app.kubernetes.io/name + instance（Helm 官方规范） */ -}}
{{- define "damo-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "damo-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- /* labels：完整标签集 = selectorLabels + 出处信息（审计/筛选用） */ -}}
{{- define "damo-app.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "damo-app.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}   {{/* = "Helm"，资源归属标识 */}}
{{- end -}}
