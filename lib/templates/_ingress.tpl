{{- define "dracolich-service.ingress" -}}
{{- if .Values.ingress.enabled -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "dracolich-service.fullname" . }}
  labels:
    {{- include "dracolich-service.labels" . | nindent 4 }}
  {{- with .Values.ingress.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  ingressClassName: {{ .Values.ingress.className | default "nginx" }}
  {{- with .Values.ingress.tls }}
  tls:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  rules:
    - host: {{ .Values.ingress.host | quote }}
      http:
        paths:
          - path: {{ .Values.ingress.path | quote }}
            pathType: Prefix
            backend:
              service:
                name: {{ include "dracolich-service.fullname" . }}
                port:
                  name: http
{{- end -}}
{{- end -}}
