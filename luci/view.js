'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require poll';
'require ui';
'require dom';
'require tools.googlewifi_led as monitor';

return view.extend({
    load: function() {
        return Promise.all([uci.load('googlewifi_led'), monitor.loadStatus()]);
    },
    render: function(data) {
        var m = new form.Map('googlewifi_led');
        var s = m.section(form.NamedSection, 'main', 'monitor', _('Monitor settings'));
        s.addremove = false;
        var o = s.option(form.Flag, 'enabled', _('Enable monitor'));
        o.default = '1'; o.rmempty = false;
        var numeric = function(name, title, description, minimum, maximum, fallback) {
            var option = s.option(form.Value, name, title, description);
            option.datatype = 'and(uinteger,range(' + minimum + ',' + maximum + '))';
            option.default = String(fallback);
            option.rmempty = false;
            return option;
        };
        numeric('brightness', _('Brightness'), _('1–255. The default is 64.'), 1, 255, 64);
        numeric('interval', _('Check interval'), _('Seconds between completed checks.'), 5, 3600, 30);
        numeric('slow_ms', _('Slow response threshold'), _('Milliseconds to the first response byte. Slower successful checks show yellow.'), 1, 60000, 1200);
        numeric('failure_threshold', _('Failures before red'), _('Consecutive failed checks required before blinking red.'), 1, 10, 2);
        numeric('recovery_threshold', _('Successes before recovery'), _('Consecutive successful checks required after a failure.'), 1, 10, 1);
        numeric('socks_port', _('Local SOCKS port'), _('0 follows the port configured in Passwall2. The listener must be on 127.0.0.1.'), 0, 65535, 0);
        numeric('connect_timeout', _('Connection timeout'), _('Seconds allowed to establish each endpoint connection.'), 1, 30, 3);
        numeric('request_timeout', _('Request timeout'), _('Maximum total seconds for each endpoint request.'), 1, 60, 8);
        o = s.option(form.DynamicList, 'check_url', _('HTTPS check URLs'),
            _('One to three HTTPS endpoints returning HTTP 204. Later URLs are fallbacks.'));
        o.rmempty = false;
        o.validate = function(section, value) {
            // DynamicList also validates its empty add-item field when saving.
            var urls = this.formvalue(section) || [];
            urls = Array.isArray(urls) ? urls.slice() : [urls];
            if (Array.isArray(value)) urls = value;
            else if (value && urls.indexOf(value) < 0) urls.push(value);
            if (!urls.length || urls.length > 3) return _('Use one to three URLs.');
            for (var i = 0; i < urls.length; i++) {
                try {
                    var parsed = new URL(urls[i]);
                    if (parsed.protocol !== 'https:' || !parsed.hostname || parsed.username || parsed.password || /\s/.test(urls[i]))
                        return _('Use an HTTPS URL without credentials or whitespace.');
                }
                catch (e) { return _('Enter a valid HTTPS URL.'); }
            }
            return true;
        };
        var statusNode = E('div', {}, monitor.renderStatus(data[1]));
        var refresh = function() {
            return monitor.loadStatus().then(function(status) { dom.content(statusNode, monitor.renderStatus(status)); });
        };
        var action = function(name, label) {
            return E('button', { 'class': 'cbi-button cbi-button-action', 'type': 'button',
                'click': ui.createHandlerFn(this, function(ev) {
                    var button = ev.currentTarget;
                    button.disabled = true;
                    button.classList.add('spinning');
                    return fs.exec('/etc/init.d/googlewifi-led', [name]).then(function(result) {
                        if (result.code !== 0) throw new Error(result.stderr || _('The controller action failed.'));
                        if (name === 'probe') ui.addNotification(null, E('p', {}, _('Check requested. Live status will refresh automatically.')), 'info');
                        return refresh();
                    }).catch(function(error) {
                        ui.addNotification(null, E('p', {}, error.message), 'error');
                    }).finally(function() {
                        button.disabled = false;
                        button.classList.remove('spinning');
                    });
                }) }, label);
        };
        return m.render().then(function(formNode) {
            poll.add(refresh, 5);
            return E('div', {}, [
                E('h2', {}, _('Passwall2 LED Monitor')),
                E('p', {}, _('Show real HTTPS connectivity through Passwall2 on the Google WiFi RGB ring. Settings apply to all three channels.')),
                statusNode,
                E('div', { 'class': 'cbi-page-actions' }, [
                    action('probe', _('Check now')), ' ', action('restart', _('Restart controller'))
                ]),
                E('p', {}, [
                    E('a', { 'href': L.url('admin/system/leds') }, _('Open LED Configuration')),
                    ' — ', _('Green: connected; yellow: slow; blinking red: failed; blue: disabled or starting.')
                ]),
                formNode
            ]);
        });
    }
});
