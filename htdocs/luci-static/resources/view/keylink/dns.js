'use strict';
'require view';
'require form';
'require uci';

return view.extend({
	load: function() {
		return uci.load('keylink');
	},

	render: function() {
		var m, s, o;

		m = new form.Map('keylink', _('DNS'),
			_("Xray handles DNS queries itself: domains listed below are resolved directly using local DNS; all others use encrypted DNS through the default route. This prevents your ISP from reading or modifying queries for blocked sites."));

		s = m.section(form.NamedSection, 'main', 'general');

		o = s.option(form.Flag, 'dns_enabled', _("Use Xray DNS"));

		o = s.option(form.Flag, 'dns_hijack', _("Use it for router and LAN DNS"),
			_("dnsmasq will forward all queries to Xray. Previous dnsmasq settings are restored when Xray stops. DNS resolution is unavailable while Xray is down; the service restarts automatically after a failure."));
		o.default = '1';
		o.depends('dns_enabled', '1');

		o = s.option(form.Value, 'dns_remote', _("Remote DNS"),
			_("Uses the default route. Specify an IP address, not a domain."));
		o.value('https://1.1.1.1/dns-query', 'Cloudflare DoH');
		o.value('https://8.8.8.8/dns-query', 'Google DoH');
		o.value('https://9.9.9.9/dns-query', 'Quad9 DoH');
		o.value('tcp://1.1.1.1', 'Cloudflare TCP');
		o.placeholder = 'https://1.1.1.1/dns-query';
		o.depends('dns_enabled', '1');

		o = s.option(form.Value, 'dns_local', _("Local DNS"),
			_("For the domains below and server hostnames. Use an IP address or a URL with +local; a domain here would cause a loop."));
		o.value('77.88.8.8', _("Yandex"));
		o.value('https+local://1.1.1.1/dns-query', _("Cloudflare DoH (direct)"));
		o.placeholder = '77.88.8.8';
		o.depends('dns_enabled', '1');
		o.validate = function(sid, v) {
			if (!v || /^\d+\.\d+\.\d+\.\d+$/.test(v) || /^(udp|tcp):\/\/\d+\.\d+\.\d+\.\d+/.test(v) || /\+local:\/\//.test(v))
				return true;
			return _("Specify an IP address, such as 77.88.8.8, or a URL with +local");
		};

		o = s.option(form.DynamicList, 'dns_local_domains', _("Domains for local DNS"),
			_('geosite:category-ru, domain:example.ru, full:host.example.com'));
		o.depends('dns_enabled', '1');

		o = s.option(form.ListValue, 'dns_query_strategy', _("Address types"),
			_("The transparent proxy only supports IPv4, so IPv6 addresses are not returned by default."));
		o.value('UseIPv4', _("IPv4 only"));
		o.value('UseIP', _("IPv4 and IPv6"));
		o.value('UseIPv6', _("IPv6 only"));
		o.default = 'UseIPv4';
		o.depends('dns_enabled', '1');

		o = s.option(form.Value, 'dns_port', _("Xray DNS port"));
		o.datatype = 'port';
		o.placeholder = '5353';
		o.depends('dns_enabled', '1');

		return m.render();
	}
});
