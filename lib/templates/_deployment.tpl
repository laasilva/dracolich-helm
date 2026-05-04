{{- define "dracolich-service.deployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "dracolich-service.fullname" . }}
  labels:
    {{- include "dracolich-service.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount | default 1 }}
  selector:
    matchLabels:
      {{- include "dracolich-service.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "dracolich-service.selectorLabels" . | nindent 8 }}
    spec:
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy | default "IfNotPresent" }}
          ports:
            - name: http
              containerPort: {{ .Values.service.appPort | default 8080 }}
              protocol: TCP
            - name: management
              containerPort: {{ .Values.service.managementPort | default 7980 }}
              protocol: TCP
          {{- with .Values.env }}
          env:
            {{- range $k, $v := . }}
            - name: {{ $k }}
              value: {{ $v | quote }}
            {{- end }}
          {{- end }}
          {{- with .Values.envFrom }}
          envFrom:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          livenessProbe:
            httpGet:
              path: {{ .Values.probes.livenessPath | default "/actuator/health/liveness" }}
              port: management
            initialDelaySeconds: {{ .Values.probes.livenessInitialDelaySeconds | default 30 }}
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: {{ .Values.probes.readinessPath | default "/actuator/health/readiness" }}
              port: management
            initialDelaySeconds: {{ .Values.probes.readinessInitialDelaySeconds | default 10 }}
            periodSeconds: 5
          {{- with .Values.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .Values.volumeMounts }}
          volumeMounts:
            {{- toYaml . | nindent 12 }}
          {{- end }}
      {{- with .Values.volumes }}
      volumes:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end -}}
