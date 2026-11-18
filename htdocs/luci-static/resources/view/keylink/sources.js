'use strict';
'require view';
'require form';
'require uci';
'require keylink.common as common';

function ifaceName(s) {
	return s.ifname || s['.name'];
}

function looksLikeUplink(s) {
	/* AllowedIPs и route_allowed_ips задаются не в интерфейсе, а в секциях
	 * его пиров (config wireguard_<интерфейс>) */
	var fullRoute = uci.sections('network', 'wireguard_' + s['.name']).some(function(p) {
		return p.disabled != '1' && p.route_allowed_ips == '1' &&
			L.toArray(p.allowed_ips).some(function(a) {
				return a == '0.0.0.0/0' || a == '::/0';
			});
	});
	if (fullRoute)
		return true;

	return uci.sections('network', 'route').some(function(r) {
		if (r.interface != s['.name'])
			return false;
		if (r.target == 'default' || r.target == '0.0.0.0/0')
			return true;
		return r.target == '0.0.0.0' && (r.netmask == '0.0.0.0' || !r.netmask);
	});
}

function isIPv4OrCIDR(value) {
	var m = String(value || '').match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?:\/(\d{1,2}))?$/);
	if (!m)
		return false;
	for (var i = 1; i <= 4; i++)
		if (+m[i] > 255)
			return false;
	return m[5] == null || +m[5] <= 32;
}

function firstIPv4(s) {
	var addrs = L.toArray(s.addresses);
	for (var i = 0; i < addrs.length; i++) {
		var m = String(addrs[i]).match(/^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)(?:\/\d+)?$/);
		if (m)
			return m[1];
	}
	return null;
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('keylink'),
			uci.load('network')
		]);
	},

	render: function() {
		var m, s, o;
		var wg = uci.sections('network', 'interface').filter(function(i) {
			return i.proto == 'wireguard';
		});

		m = new form.Map('keylink', _('Sources'),
			_('Extra interfaces whose IPv4 traffic KeyLink handles like LAN traffic: routing rules, the selected server or balancer, DNS, and DPI bypass. The rules are applied to incoming packets with nftables TPROXY. WireGuard is not configured here; create the tunnel in Network → Interfaces first.'));

		s = m.section(form.NamedSection, 'main', 'general', _('WireGuard Sources'));

		o = s.option(form.Flag, 'wg_enabled', _('Proxy traffic from WireGuard interfaces'),
			_('Uses the same TPROXY inbound and port as the LAN transparent proxy. The LAN toggle on the General tab is not required, and LAN handling stays unchanged when this option is off.'));
		o.rmempty = false;

		o = s.option(form.MultiValue, 'wg_ifaces', _('WireGuard interfaces'),
			_('Traffic entering the selected interfaces is proxied. Only interfaces with proto "wireguard" in /etc/config/network are listed.'));
		o.depends('wg_enabled', '1');

		var known = {};
		wg.forEach(function(i) {
			var name = ifaceName(i), label = name, addrs = L.toArray(i.addresses);
			known[name] = true;
			if (addrs.length)
				label += ' (' + addrs.join(', ') + ')';
			if (looksLikeUplink(i))
				label += ' — ' + _('default route, possible loop');
			o.value(name, label);
		});

		/* Keep a previously selected interface visible even if it was renamed or
		 * removed from the network configuration, so saving does not silently
		 * drop the user's setting. */
		L.toArray(uci.get('keylink', 'main', 'wg_ifaces')).forEach(function(name) {
			if (!known[name])
				o.value(name, _('%s (not found)').format(name));
		});
		common.emptyHint(o, _('No WireGuard interfaces found. Create one in Network → Interfaces.'));

		o = s.option(form.DynamicList, 'wg_sources', _('Source addresses inside the tunnel'),
			_('Optional. Proxy only these WireGuard client addresses or subnets, for example 10.0.0.0/24 or 10.0.0.5. Leave empty to proxy all IPv4 traffic entering the selected interfaces.'));
		o.depends('wg_enabled', '1');
		o.placeholder = '10.0.0.0/24';
		o.validate = function(sid, value) {
			return (!value || isIPv4OrCIDR(value)) ? true
				: _('Enter an IPv4 address or CIDR, for example 10.0.0.5 or 10.0.0.0/24');
		};

		o = s.option(form.DummyValue, '_wg_limits', _('Requirements and limitations'));
		o.depends('wg_enabled', '1');
		o.textvalue = function() {
			var items = [
				E('li', {}, _('IPv4 only. IPv6 traffic from WireGuard clients is not proxied by KeyLink.')),
				E('li', {}, _('The WireGuard interface must be in a firewall zone that accepts input, for example lan. Otherwise the router rejects the intercepted traffic.')),
				E('li', {}, _('The router needs a route back to WireGuard clients (normally created by WireGuard AllowedIPs). Otherwise replies cannot return to the tunnel.')),
				E('li', {}, _('If the WireGuard interface is the router uplink or carries traffic to the proxy server, routing loops are possible. Enable logging and check the external IP after applying.')),
				E('li', {}, _('Transparent proxying requires the kmod-nft-tproxy package and nftables (fw4).'))
			];

			var selected = L.toArray(uci.get('keylink', 'main', 'wg_ifaces'));
			var risky = wg.filter(function(i) {
				return selected.indexOf(ifaceName(i)) >= 0 && looksLikeUplink(i);
			});
			if (risky.length)
				items.push(E('li', { 'style': 'color:#c00' },
					_('Selected interface(s) %s look like an uplink (default route or AllowedIPs 0.0.0.0/0). Check for loops before relying on this setup.').format(
						risky.map(ifaceName).join(', '))));

			return E('div', {}, [ E('ul', {}, items) ]);
		};

		o = s.option(form.DummyValue, '_wg_dns', _('DNS for WireGuard clients'));
		o.depends('wg_enabled', '1');
		o.textvalue = function() {
			var lines = [
				E('p', {}, _('WireGuard does not push a DNS server to clients. Set it in each client configuration (or in the client app) manually.'))
			];

			var selected = L.toArray(uci.get('keylink', 'main', 'wg_ifaces'));
			var addresses = [];
			wg.forEach(function(i) {
				if (selected.indexOf(ifaceName(i)) < 0)
					return;
				var ip = firstIPv4(i);
				if (ip)
					addresses.push(ip + ' (' + ifaceName(i) + ')');
			});
			if (addresses.length)
				lines.push(E('p', {}, _('Router address inside the tunnel: %s. Use it as the DNS server on WireGuard clients.').format(addresses.join(', '))));

			lines.push(E('p', {}, _('On the DNS tab, enable Xray DNS and Use it for router and LAN DNS. Then dnsmasq accepts queries from WireGuard clients and forwards them to KeyLink.')));
			if (uci.get('keylink', 'main', 'dns_enabled') != '1')
				lines.push(E('p', { 'style': 'color:#c00' }, _('Xray DNS is disabled. Domain-based routing may not work for WireGuard clients.')));
			else if (uci.get('keylink', 'main', 'dns_hijack') != '1')
				lines.push(E('p', { 'style': 'color:#c00' }, _('DNS redirection for dnsmasq is disabled. WireGuard clients that use the router as DNS will not get KeyLink DNS.')));
			lines.push(E('p', {}, _('If WireGuard clients use a public DNS server directly, domain-based routing may not apply and DNS queries can leak outside the tunnel.')));

			return E('div', {}, lines);
		};

		return m.render();
	}
});
