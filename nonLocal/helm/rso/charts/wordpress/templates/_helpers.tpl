{{/* Release-scoped name. The tenant name is validated here because it becomes a host name. */}}
{{- define "wordpress.tenant" -}}
{{- $n := required "tenant.name is required" .Values.tenant.name -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]{0,28}[a-z0-9])?$" $n) -}}
{{- fail "tenant.name must be a DNS label (lowercase letters, digits, '-'; max 30 chars)" -}}
{{- end -}}
{{- $n -}}
{{- end -}}

{{- define "wordpress.fullname" -}}
{{- printf "wp-%s" (include "wordpress.tenant" .) -}}
{{- end -}}

{{- define "wordpress.labels" -}}
app.kubernetes.io/name: wordpress
app.kubernetes.io/instance: {{ include "wordpress.tenant" . }}
app.kubernetes.io/part-of: rso
rso/tenant: {{ include "wordpress.tenant" . }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "wordpress.selectorLabels" -}}
app.kubernetes.io/name: wordpress
app.kubernetes.io/instance: {{ include "wordpress.tenant" . }}
{{- end -}}

{{- define "wordpress.dbSecret" -}}
{{- default (printf "%s-db" (include "wordpress.fullname" .)) .Values.database.existingSecret -}}
{{- end -}}
