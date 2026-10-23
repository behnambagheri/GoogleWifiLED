'use strict';
'require baseclass';
'require form';

return baseclass.extend({
    trigger: _('Passwall2 monitor (Google WiFi RGB ring)'),
    description: _('The monitor controls all three RGB channels. Use the linked settings page to change brightness, checks, and thresholds.'),
    kernel: false,
    addFormOptions: function(s) {
        var o = s.option(form.DummyValue, '_googlewifi_settings', _('Monitor settings'));
        o.modalonly = true;
        o.depends('trigger', 'googlewifi');
        o.renderWidget = function() {
            return E('a', { 'href': L.url('admin/system/googlewifi_led'), 'class': 'cbi-button cbi-button-action' },
                _('Open Passwall2 LED Monitor'));
        };
    }
});
