{{/*
Service fullname — defaults to the Helm release name; can be overridden
via .Values.fullnameOverride. Truncated to 63 chars (k8s name limit).
*/}}
{{- define "dracolich-service.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Common metadata labels.
*/}}
{{- define "dracolich-service.labels" -}}
app.kubernetes.io/name: {{ include "dracolich-service.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/*
Selector labels — subset of full labels. Must match the deployment's
spec.selector exactly; changing these requires a new Deployment.
*/}}
{{- define "dracolich-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "dracolich-service.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
