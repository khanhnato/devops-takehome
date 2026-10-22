{{- define "quote-api.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "quote-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "quote-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "quote-api.labels" -}}
{{ include "quote-api.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | trunc 12 | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
