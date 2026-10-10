{{/*
Expand the name of the chart.
*/}}
{{- define "paperclip.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "paperclip.fullname" -}}
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
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "paperclip.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "paperclip.labels" -}}
helm.sh/chart: {{ include "paperclip.chart" . }}
{{ include "paperclip.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "paperclip.selectorLabels" -}}
app.kubernetes.io/name: {{ include "paperclip.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Server-only selector: the bundled Postgres carries the same name/instance labels
(paperclip.labels), so without the component the server Service, Deployment and
NetworkPolicy also selected the Postgres pod (measured on the render, 2026-10-08).
*/}}
{{- define "paperclip.serverSelectorLabels" -}}
{{ include "paperclip.selectorLabels" . }}
app.kubernetes.io/component: server
{{- end }}

{{/*
ExternalSecret of the pull secret for our private images (vault.imagePullSecret)
in the namespace given: the release namespace (server image) and, with
kubernetesExecution.sandboxImagePullSecret, every sandbox namespace (runtime
image). Same template as alebrije-infra k8s/prod/regcred-external-secret.yaml
(Vault ci/dockerhub). The inner {{ "{{ }}" }} are ESO's template, escaped for Helm.
Usage: include "paperclip.pullSecretExternalSecret" (dict "root" $ "namespace" $ns)
*/}}
{{- define "paperclip.pullSecretExternalSecret" -}}
{{- $root := .root -}}
{{- with $root.Values.vault.imagePullSecret -}}
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: {{ .name }}-eso
  namespace: {{ $.namespace }}
  labels:
    {{- include "paperclip.labels" $root | nindent 4 }}
spec:
  refreshInterval: {{ $root.Values.vault.refreshInterval }}
  secretStoreRef:
    name: {{ $root.Values.vault.clusterSecretStoreName | default (printf "%s-vault-store" (include "paperclip.fullname" $root)) }}
    kind: ClusterSecretStore
  target:
    name: {{ .name }}
    creationPolicy: Owner
    deletionPolicy: Retain
    template:
      type: kubernetes.io/dockerconfigjson
      engineVersion: v2
      data:
        .dockerconfigjson: |
          {
            "auths": {
              {{ .registry | quote }}: {
                "username": "{{ "{{ .username }}" }}",
                "password": "{{ "{{ .token }}" }}",
                "auth": "{{ "{{ printf \"%s:%s\" .username .token | b64enc }}" }}"
              }
            }
          }
  data:
    - secretKey: username
      remoteRef:
        key: {{ .vaultKey }}
        property: {{ .usernameProperty }}
    - secretKey: token
      remoteRef:
        key: {{ .vaultKey }}
        property: {{ .tokenProperty }}
{{- end }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "paperclip.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "paperclip.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the name of the secret for auth credentials
*/}}
{{- define "paperclip.secretName" -}}
{{- if .Values.auth.existingSecret -}}
{{- .Values.auth.existingSecret -}}
{{- else -}}
{{- include "paperclip.fullname" . -}}-secret
{{- end -}}
{{- end -}}

{{/*
Create the name of the database secret
Priority: postgresql.auth.existingSecret > externalDatabase.existingSecret > generated
*/}}
{{- define "paperclip.dbSecretName" -}}
{{- if .Values.postgresql.auth.existingSecret -}}
{{- .Values.postgresql.auth.existingSecret -}}
{{- else if .Values.externalDatabase.existingSecret -}}
{{- .Values.externalDatabase.existingSecret -}}
{{- else -}}
{{- include "paperclip.fullname" . -}}-db-secret
{{- end -}}
{{- end -}}

{{/*
Create the PostgreSQL service name
*/}}
{{- define "paperclip.postgresServiceName" -}}
{{- printf "%s-postgres" (include "paperclip.fullname" .) }}
{{- end -}}

{{/*
Construct the database URL
Uses external URL if provided, otherwise constructs from embedded PostgreSQL
*/}}
{{- define "paperclip.databaseURL" -}}
{{- if .Values.externalDatabase.url -}}
{{- .Values.externalDatabase.url -}}
{{- else -}}
{{- printf "postgresql://%s:%s@%s:5432/%s" .Values.postgresql.auth.username .Values.postgresql.auth.password (include "paperclip.postgresServiceName" .) .Values.postgresql.auth.database -}}
{{- end -}}
{{- end -}}

{{/*
Create checksum annotations for pod restart on config/secret changes
*/}}
{{- define "paperclip.checksumAnnotations" -}}
checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
checksum/secret: {{ include (print $.Template.BasePath "/secret.yaml") . | sha256sum }}
{{- end }}
