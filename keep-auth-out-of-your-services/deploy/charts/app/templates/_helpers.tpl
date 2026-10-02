{{- define "app.name" -}}
{{- .Values.nameOverride | default .Chart.Name -}}
{{- end -}}

{{- define "app.labels" -}}
app: {{ include "app.name" . }}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/part-of: keep-auth-out
{{- end -}}

{{- define "app.probe" -}}
{{- if .Values.probePath -}}
httpGet:
  path: {{ .Values.probePath }}
  port: http
{{- else -}}
tcpSocket:
  port: http
{{- end -}}
{{- end -}}
