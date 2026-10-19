{{/*
Active features for this service, as YAML: {<feature>: [<user>, ...]}.
Looks up services.<name> from features.yaml, drops users not in the
top-level `users` allowlist, then drops features left with no users.

Fails the render on a feature name Kubernetes would reject: it becomes
part of a Service name (DNS-1035 label) and a container name (63-char
label), so catch it here rather than at apply time.
*/}}
{{- define "chart.features" -}}
{{- $name := .Values.name -}}
{{- $known := .Values.users | default list -}}
{{- $features := get (.Values.services | default dict) $name | default dict -}}
{{- $out := dict -}}
{{- range $feature, $users := $features -}}
{{- if not (regexMatch "^[a-z]([-a-z0-9]*[a-z0-9])?$" $feature) -}}
{{- fail (printf "features.yaml: feature %q under %q must be lowercase letters, digits and '-', starting with a letter" $feature $name) -}}
{{- end -}}
{{- $app := printf "%s-%s-app" $name $feature -}}
{{- if gt (len $app) 63 -}}
{{- fail (printf "features.yaml: %q is %d chars, over Kubernetes' 63 -- shorten feature %q" $app (len $app) $feature) -}}
{{- end -}}
{{- $allowed := list -}}
{{- range $users -}}
{{- if has . $known -}}{{- $allowed = append $allowed . -}}{{- end -}}
{{- end -}}
{{- if $allowed -}}{{- $_ := set $out $feature $allowed -}}{{- end -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
route.env, required whenever route.enabled -- it's part of every
external hostname, and an empty one renders "<name>..apps...".
*/}}
{{- define "chart.routeEnv" -}}
{{- required "route.env is required when route.enabled is true (e.g. dev, stage, prod)" .Values.route.env -}}
{{- end -}}

{{/*
Deployment shared by the main build and every feature build. Takes a
dict: Values, app (the app label / object name), tag (image tag),
replicas, resources -- the last two differ so feature builds don't
inherit the main build's scale.
*/}}
{{- define "chart.deployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .app }}
  labels:
    app: {{ .app }}
spec:
  replicas: {{ .replicas }}
  selector:
    matchLabels:
      app: {{ .app }}
  template:
    metadata:
      labels:
        app: {{ .app }}
    spec:
      containers:
        - name: {{ .app }}
          image: "{{ .Values.image.repository }}:{{ .tag }}"
          ports:
            - containerPort: {{ .Values.port }}
          env:
            - name: ENVIRONMENT
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            # Same source as the image field above -- no separate
            # "read the tag back off myself" trick needed, unlike the
            # Kustomize `replacements:` version this chart replaces.
            - name: IMAGE_TAG
              value: "{{ .tag }}"
            {{- range $k, $v := .Values.env }}
            - name: {{ $k }}
              value: {{ $v | quote }}
            {{- end }}
          resources:
            {{- toYaml .resources | nindent 12 }}
{{- end -}}
