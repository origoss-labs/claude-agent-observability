require 'json'
require 'yaml'

# ColeMurray/claude-code-otel dashboard. PROMETHEUS stack: metric panels query
# Prometheus-normalised names against our Prometheus datasource; log panels query
# Loki. Two mechanical changes from upstream, verified against a live `claude -p` run:
#   - metric panels: job="otel-collector" -> job="claude-code" (Prometheus OTLP
#     receiver sets job from service.name)
#   - datasource uids -> prometheus / loki / tempo (our provisioned uids)

d = JSON.parse(File.read('dashboards/upstream/colemurray-claude-code-dashboard.json'))

# our provisioned datasource uids, keyed by datasource type
UID = { 'prometheus' => 'prometheus', 'loki' => 'loki', 'tempo' => 'tempo' }

def walk(o)
  case o
  when Hash
    o.each do |k, v|
      if k == 'datasource' && v.is_a?(Hash) && v['type']
        v['uid'] = UID[v['type']] || v['uid']        # point at our datasources
      elsif k == 'expr' && v.is_a?(String)
        o[k] = v.gsub('job="otel-collector"', 'job="claude-code"')  # our job label
      else
        walk(v)
      end
    end
  when Array
    o.each { |e| walk(e) }
  end
end

walk(d)
d['uid'] = 'claude-code-otel'
d.delete('id')
d['version'] = 1

cm = {
  'apiVersion' => 'v1',
  'kind'       => 'ConfigMap',
  'metadata'   => {
    'name'      => 'claude-code-dashboard',
    'namespace' => 'observability',
    'labels'    => { 'grafana_dashboard' => '1' },
  },
  'data' => { 'claude-code.json' => JSON.pretty_generate(d) },
}

header = <<~TXT
  # Claude Code Observability dashboard — adapted from ColeMurray/claude-code-otel.
  # PROMETHEUS stack. Two mechanical changes from upstream, verified against a live
  # `claude -p` run:
  #   - metric panels: job="otel-collector" -> job="claude-code" (our service.name)
  #   - datasource uids -> prometheus / loki / tempo (our provisioned uids)
  # Loki panels were already correct (service_name="claude-code" label exists).
  # Regenerate with: ruby scripts/adapt-colemurray.rb
TXT

File.write('manifests/dashboards/claude-code-dashboard.configmap.yaml', header + cm.to_yaml)
puts "wrote configmap (#{File.size('manifests/dashboards/claude-code-dashboard.configmap.yaml')} bytes)"
puts "panels: #{d['panels'].size}, uid: #{d['uid']}"
