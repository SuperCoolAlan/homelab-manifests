{{- define "vpn-gluetun.container" }}
- name: gluetun
  image: qmcgaw/gluetun:latest
  imagePullPolicy: Always
  env:
    - name: DNS_ADDRESS
      value: 10.255.255.1
    - name: TZ
      value: America/Chicago
    - name: VPN_SERVICE_PROVIDER
      value: {{ .Values.general.vpn.provider }}
    - name: VPN_TYPE
      value: {{ .Values.general.vpn.type }}
    - name: SERVER_REGIONS
      value: {{ .Values.general.vpn.region }}
  {{- if or (.Values.general.vpn.existingSecret) (.Values.general.vpn.password) }}
  {{- include "vpn-gluetun.openvpnSecret.env" . | nindent 2 }}
  {{- end }}
  ports:
    - containerPort: 9091
      protocol: TCP
  resources: {}
  securityContext:
    capabilities:
      add:
        - NET_ADMIN
  terminationMessagePath: /dev/termination-log
  terminationMessagePolicy: File
{{- end }}

{{- define "vpn-gluetun.openvpnSecret.env" }}
envFrom:
- secretRef:
    name: {{ .Values.general.vpn.existingSecret | default "windscribe-openvpn-creds" }}

{{- end }}

