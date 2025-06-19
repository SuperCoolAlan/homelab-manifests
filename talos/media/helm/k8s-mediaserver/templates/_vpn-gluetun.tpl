{{ define "vpn-gluetun.container" }}
name: gluetun
image: qmcgaw/gluetun:latest
imagePullPolicy: Always
env:
  - name: TZ
    value: America/Chicago
  - name: VPN_SERVICE_PROVIDER
    value: {{ .Values.general.vpn.provider }}
  - name: VPN_TYPE
    value: {{ .Values.general.vpn.type }}
  - name: SERVER_REGIONS
    value: {{ .Values.general.vpn.region }}
{{- if or (.Values.general.vpn.existingSecret) (.Values.general.vpn.password) }}
{{ include "vpn-gluetun.openvpnSecret.env" . }}
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

{{ define "vpn-gluetun.dnsConfig" }}
dnsConfig:
  nameservers:
    - 10.255.255.1
  options:
    - name: ndots
      value: '5'
  searches:
    - media.svc.cluster.local
    - svc.cluster.local
    - cluster.local
dnsPolicy: None
{{- end }}

{{ define "vpn-gluetun.openvpnSecret.env" }}
envFrom:
- secretRef:
    name: {{ .Values.general.vpn.existingSecret | default "windscribe-openvpn-creds" }}

{{- end }}

{{ define "vpn-gluetun.resolv-conf.initContainer" }}
#- name: resolv-conf-dns
  #image: busybox
  #command: [sed, -i, -e, 's/nameservers .*/nameservers 10.255.255.1/', /etc/resolv.conf]
  #restartPolicy: Always
{{- end }}
