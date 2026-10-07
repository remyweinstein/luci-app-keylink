'use strict';
'require view';
'require form';
'require uci';
'require keylink.common as common';

return view.extend({
	load: function() {
		return uci.load('keylink');
	},

	render: function() {
		var m, s, o;

		m = new form.Map('keylink', _("Routing"),
			_("Rules are evaluated from top to bottom; the first match wins. Drag rows to reorder them. Conditions within a rule use AND; values within a list use OR."));

		s = m.section(form.GridSection, 'rule');
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;
		s.nodescriptions = true;
		s.modaltitle = function(sid) {
                        return _(uci.get('keylink', sid, 'name') || '') || _("New rule");
		};

		o = s.option(form.Value, 'name', _("Name"));
                o.textvalue = function(sid) {
                        return _(this.cfgvalue(sid) || '');
                };

		o = s.option(form.Flag, 'enabled', _("Enabled"));
		o.default = '1';
		o.editable = true;
		o.rmempty = false;

		o = s.option(form.ListValue, 'outbound', _("Route to"));
		common.fillOutbounds(o, true, true);
		o.rmempty = false;

                o = s.option(form.TextValue, 'domain', _("Domains"),
                        _("One entry per line: geosite:category-ru, domain:example.com (including subdomains), full:example.com, keyword:google, regexp:..."));
		o.modalonly = true;
                o.rows = 10;
                o.monospace = true;
                o.cfgvalue = function(sid) {
                        var domains = uci.get('keylink', sid, 'domain');
                        return Array.isArray(domains) ? domains.join('\n') : (domains || '');
                };
                o.write = function(sid, value) {
                        var domains = value.split(/\r\n?|\n/).map(function(line) {
                                return line.trim();
                        }).filter(Boolean);
                        if (domains.length)
                                uci.set('keylink', sid, 'domain', domains);
                        else
                                uci.unset('keylink', sid, 'domain');
                };

		o = s.option(form.DynamicList, 'ip', _("Destination IP addresses"),
			_('geoip:ru, 1.2.3.0/24, 8.8.8.8'));
		o.modalonly = true;

		o = s.option(form.DynamicList, 'source', _("Clients (source IP)"),
			_("For example, 192.168.1.50 applies the rule only to that device."));
		o.modalonly = true;
		o.datatype = 'cidr4';

		o = s.option(form.Value, 'port', _("Destination ports"), _('53, 443, 1000-2000'));
		o.modalonly = true;

		o = s.option(form.ListValue, 'network', _("Network"));
		o.modalonly = true;
		o.value('', _("any"));
		o.value('tcp', 'TCP');
		o.value('udp', 'UDP');

		o = s.option(form.MultiValue, 'protocol', _("Protocol (sniffing)"));
		o.modalonly = true;
		o.value('http', 'HTTP');
		o.value('tls', 'TLS');
		o.value('quic', 'QUIC');
		o.value('bittorrent', 'BitTorrent');

		return m.render();
	}
});
