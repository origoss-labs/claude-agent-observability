require 'json'
require 'yaml'

# Claude Code Metrics (Prometheus) — grafana.com/dashboards/25255. Authored against
# Prometheus-normalised metric names, which is exactly what the PROMETHEUS stack
# stores, so the only adaptation is resolving the datasource input to our Prometheus
# uid and stripping the grafana.com import scaffolding.

SRC = 'dashboards/upstream/claude-code-metrics-prometheus-25255.json'
OUT = 'manifests/dashboards/claude-code-metrics-prometheus.configmap.yaml'

# our provisioned datasource uids, keyed by the dashboard's datasource type
UID = { 'prometheus' => 'prometheus' }

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

# drop the datasource-picker template var (DS_PROMETHEUS): provisioned, uid is fixed
d['templating']['list'].reject! { |v| v['type'] == 'datasource' } if d['templating']

# strip import-time scaffolding so the sidecar loads it directly
%w[__inputs __requires __elements id].each { |k| d.delete(k) }
d['uid'] = 'claude-code-metrics-prometheus'
d['version'] = 1

cm = {
  'apiVersion' => 'v1',
  'kind'       => 'ConfigMap',
  'metadata'   => {
    'name'      => 'claude-code-metrics-prometheus-dashboard',
    'namespace' => 'observability',
    'labels'    => { 'grafana_dashboard' => '1' },
  },
  'data' => { 'claude-code-metrics-prometheus.json' => JSON.pretty_generate(d) },
}

header = <<~TXT
  # Claude Code Metrics (Prometheus) dashboard — grafana.com/dashboards/25255.
  # PROMETHEUS stack: queries Prometheus-normalised names against our Prometheus
  # datasource. Adapted only by resolving the datasource uid -> prometheus and
  # stripping import scaffolding.
  # Regenerate with: ruby scripts/adapt-25255.rb
TXT

File.write(OUT, header + cm.to_yaml)
puts "wrote #{OUT} (#{File.size(OUT)} bytes)"
puts "panels: #{d['panels'].size}, uid: #{d['uid']}"
