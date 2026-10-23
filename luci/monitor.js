'use strict';
'require baseclass';
'require fs';
'require rpc';

var callService = rpc.declare({ object: 'service', method: 'list', params: ['name'], expect: { '': {} } });
var labels = {
    starting: _('Starting'), healthy: _('Healthy'), slow: _('Connected, slow response'),
    unreachable: _('Connection failed'), disabled: _('Passwall2 disabled'), stopped: _('Stopped'),
    unavailable: _('Status unavailable')
};
var colors = {
    starting: _('Blinking blue'), healthy: _('Green'), slow: _('Yellow'),
    unreachable: _('Blinking red'), disabled: _('Blue'), stopped: _('Previous LED settings restored'),
    unavailable: _('Unknown until status can be read')
};
var reasons = {
    starting: _('Waiting for the first check'), disabled: _('Monitoring or Passwall2 is disabled'),
    connection_failed: _('Could not connect through the local SOCKS listener'),
    request_timeout: _('The HTTPS check timed out'), tls_failed: _('TLS certificate or connection failed'),
    socks_failed: _('The SOCKS proxy rejected the connection'),
    unexpected_http_status: _('The endpoint did not return HTTP 204'),
    socks_port_missing: _('Passwall2 has no valid local SOCKS port'),
    passwall2_config_missing: _('Passwall2 configuration is unavailable'),
    request_failed: _('The HTTPS check failed'), invalid_timing: _('The response timing was invalid'),
    status_unavailable: _('The controller is running, but its status could not be read. Refresh the page or sign in again.')
};

return baseclass.extend({
    parseStatus: function(text, service) {
        var status = {}, instances = ((service || {})['googlewifi-led'] || {}).instances || {};
        String(text || '').split('\n').forEach(function(line) {
            var match = line.match(/^(state|sample|latency_ms|http_code|curl_exit|reason|failures|updated_at)=(.*)$/);
            if (match) status[match[1]] = match[2];
        });
        status.running = Object.keys(instances).some(function(key) { return instances[key].running === true; });
        if (!status.running) status.state = 'stopped';
        else if (!labels[status.state] || status.state === 'stopped') status.state = 'starting';
        return status;
    },
    loadStatus: function() {
        return Promise.all([
            fs.read('/var/run/googlewifi-led/status').then(function(text) { return { text: text }; },
                function() { return { text: '', failed: true }; }),
            L.resolveDefault(callService('googlewifi-led'), {})
        ]).then(L.bind(function(data) {
            var status = this.parseStatus(data[0].text, data[1]);
            if (status.running && data[0].failed) {
                status.state = 'unavailable';
                status.reason = 'status_unavailable';
            }
            return status;
        }, this));
    },
    renderStatus: function(status) {
        var latency = /^\d+$/.test(status.latency_ms || '') && ['healthy', 'slow'].indexOf(status.sample) >= 0
            ? status.latency_ms + ' ms' : _('Unavailable');
        var updated = status.updated_at ? new Date(status.updated_at) : null;
        var reason = /^endpoint_[1-3]$/.test(status.reason || '')
            ? _('HTTPS check succeeded through Passwall2') : (reasons[status.reason] || _('No check result yet'));
        var rows = [
            [_('Controller'), status.running ? _('Running') : _('Stopped')],
            [_('LED state'), colors[status.state] || _('Unknown')],
            [_('Last check'), labels[status.sample] || _('Not checked yet')],
            [_('Response time'), latency],
            [_('Details'), reason],
            [_('Last update'), updated && !isNaN(updated.getTime()) ? updated.toLocaleString() : _('Unavailable')]
        ];
        return E('div', {}, [
            E('h3', {}, _('Live status')),
            E('p', { 'role': 'status', 'aria-live': 'polite', 'aria-atomic': 'true' },
                _('Passwall2 LED monitor: ') + (labels[status.state] || _('Unknown'))),
            E('table', { 'class': 'table' }, rows.map(function(row) {
                return E('tr', { 'class': 'tr' }, [
                    E('th', { 'class': 'th', 'scope': 'row' }, row[0]), E('td', { 'class': 'td' }, row[1])
                ]);
            }))
        ]);
    }
});
