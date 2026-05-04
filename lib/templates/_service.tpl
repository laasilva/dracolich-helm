{{- define "dracolich-service.service" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "dracolich-service.fullname" . }}
  labels:
    {{- include "dracolich-service.labels" . | nindent 4 }}
spec:
  type: ClusterIP
  ports:
    - port: {{ .Values.service.appPort | default 8080 }}
      targetPort: http
      protocol: TCP
      name: http
    - port: {{ .Values.service.managementPort | default 7980 }}
      targetPort: management
      protocol: TCP
      name: management
  selector:
    {{- include "dracolich-service.selectorLabels" . | nindent 4 }}
{{- end -}}
