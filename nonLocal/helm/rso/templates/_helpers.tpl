{{/* Resource name for a component: <release>-<component> */}}
{{- define "rso.name" -}}
{{- printf "%s-%s" .root.Release.Name .name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "rso.labels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/part-of: rso
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version }}
{{- end -}}

{{- define "rso.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end -}}

{{- define "rso.image" -}}
{{- printf "%s/%s:%s" .root.Values.global.imageRegistry .cfg.image.repository .cfg.image.tag -}}
{{- end -}}

{{- define "rso.pullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
Deployment + Service for one component. Params (dict):
  root, name, cfg, ports (list of {name, port}), env (rendered yaml list items, may be empty),
  httpPort (the plain HTTP port serving /health/live, /health/ready and /metrics; not the gRPC one)
startupProbe holds off the other probes while the service starts (migrations run at startup); liveness restarts a
hung process; readiness takes the pod out of the Service while Postgres is unreachable.
*/}}
{{- define "rso.workload" -}}
{{- $full := include "rso.name" (dict "root" .root "name" .name) -}}
{{- $httpPort := required "rso.workload needs httpPort" .httpPort -}}
{{- $ctx := dict "root" .root "name" .name -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $full }}
  labels:
    {{- include "rso.labels" $ctx | nindent 4 }}
spec:
  replicas: {{ .cfg.replicas }}
  selector:
    matchLabels:
      {{- include "rso.selectorLabels" $ctx | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "rso.selectorLabels" $ctx | nindent 8 }}
      {{- if .root.Values.global.metrics.scrape }}
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: {{ $httpPort | quote }}
        prometheus.io/path: /metrics
      {{- end }}
    spec:
      {{- include "rso.pullSecrets" .root | nindent 6 }}
      securityContext:
        runAsNonRoot: true
        runAsUser: 1654   # $APP_UID of the dotnet aspnet image
      containers:
        - name: {{ .name }}
          image: {{ include "rso.image" (dict "root" .root "cfg" .cfg) }}
          imagePullPolicy: {{ .root.Values.global.imagePullPolicy }}
          ports:
            {{- range .ports }}
            - name: {{ .name }}
              containerPort: {{ .port }}
            {{- end }}
          env:
            - name: ASPNETCORE_ENVIRONMENT
              value: Production
            {{- with .root.Values.global.logging.existingSecret }}
            - name: APPLICATIONINSIGHTS_CONNECTION_STRING
              valueFrom:
                secretKeyRef:
                  name: {{ . }}
                  key: APPLICATIONINSIGHTS_CONNECTION_STRING
            {{- end }}
            {{- with .env }}
            {{- . | nindent 12 }}
            {{- end }}
          startupProbe:
            httpGet:
              path: /health/live
              port: {{ $httpPort }}
            periodSeconds: 5
            failureThreshold: 36   # up to 3 minutes
          readinessProbe:
            httpGet:
              path: /health/ready
              port: {{ $httpPort }}
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /health/live
              port: {{ $httpPort }}
            periodSeconds: 20
            timeoutSeconds: 5
            failureThreshold: 3
          resources:
            {{- toYaml .cfg.resources | nindent 12 }}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ $full }}
  labels:
    {{- include "rso.labels" $ctx | nindent 4 }}
spec:
  type: ClusterIP
  selector:
    {{- include "rso.selectorLabels" $ctx | nindent 4 }}
  ports:
    {{- range .ports }}
    - name: {{ .name }}
      port: {{ .port }}
      targetPort: {{ .name }}
    {{- end }}
{{- end -}}

{{/*
Keycloak's OpenID discovery document (cluster-internal): where the services get the token signing keys.
*/}}
{{- define "rso.keycloakMetadata" -}}
{{- printf "http://%s:8080/realms/%s/.well-known/openid-configuration" (include "rso.name" (dict "root" . "name" "keycloak")) .Values.keycloak.realm -}}
{{- end -}}

{{/*
The token issuer (`iss`): the realm URL as the browser sees it.
*/}}
{{- define "rso.authIssuer" -}}
{{- if .Values.auth.issuer -}}
{{- .Values.auth.issuer -}}
{{- else -}}
{{- printf "http://%s/realms/%s" (required "keycloak.hostname is required (or set auth.issuer)" .Values.keycloak.hostname) .Values.keycloak.realm -}}
{{- end -}}
{{- end -}}
