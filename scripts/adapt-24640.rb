require 'json'
require 'yaml'

# Claude Code (VictoriaStack) — grafana.com/dashboards/24640. Runs natively on the
# VICTORIA stack (VM dotted OTLP names + VictoriaLogs), so the only adaptation is
# resolving the dashboard's datasource inputs to our provisioned uids and stripping
# the grafana.com import scaffolding so the sidecar can load it directly.

SRC = 'dashboards/upstream/claude-code-victoriastack-24640.json'
OUT = 'manifests/dashboards/claude-code-victoriastack.configmap.yaml'

# our provisioned datasource uids, keyed by the dashboard's datasource plugin type
UID = {
  'victoriametrics-metrics-datasource' => 'vmetrics',
  'victoriametrics-logs-datasource'    => 'vlogs',
}

d = JSON.parse(File.read(SRC))

def walk(o)
  case o
  when Hash
    o.each do |k, v|
      if k == 'datasource' && v.is_a?(Hash) && v['type']
        v['uid'] = UID[v['type']] || v['uid']   # point at our datasources
      else
        walk(v)
      end
    end
  when Array
    o.each { |e| walk(e) }
  end
end

walk(d)

# drop the datasource-picker template vars (mds/lds): provisioned, uids are fixed
d['templating']['list'].reject! { |v| v['type'] == 'datasource' } if d['templating']

# strip import-time scaffolding so the sidecar loads it directly
%w[__inputs __requires __elements id].each { |k| d.delete(k) }
d['uid'] = 'claude-code-victoriastack'
d['version'] = 1

cm = {
  'apiVersion' => 'v1',
  'kind'       => 'ConfigMap',
  'metadata'   => {
    'name'      => 'claude-code-victoriastack-dashboard',
    'namespace' => 'observability',
    'labels'    => { 'grafana_dashboard' => '1' },
  },
  'data' => { 'claude-code-victoriastack.json' => JSON.pretty_generate(d) },
}

header = <<~TXT
  # Claude Code (VictoriaStack) dashboard — grafana.com/dashboards/24640.
  # VICTORIA stack: metrics from VictoriaMetrics (dotted OTLP names) via the VM
  # metrics datasource plugin; logs from VictoriaLogs (LogsQL). Adapted only by
  # resolving datasource uids -> vmetrics / vlogs and stripping import scaffolding.
  # Regenerate with: ruby scripts/adapt-24640.rb
TXT

File.write(OUT, header + cm.to_yaml)
puts "wrote #{OUT} (#{File.size(OUT)} bytes)"
puts "panels: #{d['panels'].size}, uid: #{d['uid']}"
