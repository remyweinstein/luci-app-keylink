'use strict';
'require baseclass';
'require uci';

function b64decode(s) {
	s = s.replace(/-/g, '+').replace(/_/g, '/').replace(/\s/g, '');
	while (s.length % 4)
		s += '=';
	var bin = atob(s);
	try { return decodeURIComponent(escape(bin)); }
	catch (e) { return bin; }
}

function safeDecode(s) {
	try { return decodeURIComponent(s); }
	catch (e) { return s; }
}

function compact(o) {
	Object.keys(o).forEach(function(k) {
		if (o[k] == null || o[k] === '')
			delete o[k];
	});
	return o;
}

/* vless:// и trojan:// — обычный URL с параметрами */
function parseUrlLink(link, proto) {
	var u = new URL(link), q = u.searchParams;
	var cred = safeDecode(u.username);
	var o = {
		protocol: proto,
		alias: safeDecode(u.hash.slice(1)),
		address: u.hostname.replace(/^\[|\]$/g, ''),
		port: u.port || '443',
		network: q.get('type') || 'tcp',
		security: q.get('security') || (proto == 'trojan' ? 'tls' : 'none'),
		sni: q.get('sni') || q.get('peer'),
		fp: q.get('fp'),
		alpn: q.get('alpn'),
		public_key: q.get('pbk'),
		short_id: q.get('sid'),
		spider_x: q.get('spx'),
		flow: q.get('flow'),
		path: q.get('path'),
		host: q.get('host'),
		service_name: q.get('serviceName'),
		mode: q.get('mode'),
		insecure: (q.get('allowInsecure') == '1' || q.get('insecure') == '1') ? '1' : null
	};
	if (proto == 'vless') o.uuid = cred;
	else o.password = cred;
	return o;
}

/* vmess:// — base64 от JSON (формат v2rayN) */
function parseVmess(link) {
	var j = JSON.parse(b64decode(link.slice(8)));
	return {
		protocol: 'vmess',
		alias: j.ps,
		address: j.add,
		port: String(j.port || ''),
		uuid: j.id,
		method: j.scy || 'auto',
		network: j.net || 'tcp',
		security: j.tls == 'tls' ? 'tls' : 'none',
		sni: j.sni,
		fp: j.fp,
		alpn: j.alpn,
		host: j.host,
		path: j.net == 'grpc' ? null : j.path,
		service_name: j.net == 'grpc' ? j.path : null
	};
}

/* ss:// — SIP002 (base64(method:pass)@host:port) и старый base64(всё целиком) */
function parseSS(link) {
	var rest = link.slice(5), alias = '', i = rest.indexOf('#');
	if (i >= 0) {
		alias = safeDecode(rest.slice(i + 1));
		rest = rest.slice(0, i);
	}
	rest = rest.split('?')[0].replace(/\/$/, '');

	var at = rest.lastIndexOf('@'), userinfo, hostport;
	if (at < 0) {
		var d = b64decode(rest);
		at = d.lastIndexOf('@');
		userinfo = d.slice(0, at);
		hostport = d.slice(at + 1);
	}
	else {
		userinfo = safeDecode(rest.slice(0, at));
		hostport = rest.slice(at + 1);
		if (userinfo.indexOf(':') < 0)
			userinfo = b64decode(userinfo);
	}

	var c = userinfo.indexOf(':');
	var m = hostport.match(/^\[?([^\]]+?)\]?:(\d+)$/);
	if (c < 0 || !m)
		throw new Error(_("Could not parse the ss link"));

	return {
		protocol: 'shadowsocks',
		alias: alias,
		address: m[1],
		port: m[2],
		method: userinfo.slice(0, c),
		password: userinfo.slice(c + 1),
		network: 'tcp',
		security: 'none'
	};
}

/* hysteria2:// и hy2:// — порт может быть списком/диапазоном для прыжков */
function parseHy2(link) {
	var m = link.match(/^(?:hysteria2|hy2):\/\/(?:([^@]*)@)?(\[[^\]]+\]|[^:\/?#]+)(?::([0-9,\-]+))?\/?(\?[^#]*)?(#.*)?$/i);
	if (!m)
		throw new Error(_("Could not parse the hysteria2 link"));

	var q = new URLSearchParams(m[4] || ''), ports = m[3] || '443';
	var port = ports, hop = q.get('mport');
	if (/[,\-]/.test(ports)) {
		hop = ports;
		port = ports.split(/[,\-]/)[0];
	}

	return {
		protocol: 'hysteria2',
		alias: safeDecode((m[5] || '#').slice(1)),
		address: m[2].replace(/^\[|\]$/g, ''),
		port: port,
		password: safeDecode(m[1] || ''),
		sni: q.get('sni') || q.get('peer'),
		alpn: q.get('alpn'),
		insecure: q.get('insecure') == '1' ? '1' : null,
		obfs_password: q.get('obfs') == 'salamander' ? q.get('obfs-password') : null,
		hop_ports: hop,
		up: q.get('upmbps') ? q.get('upmbps') + 'mbps' : null,
		down: q.get('downmbps') ? q.get('downmbps') + 'mbps' : null
	};
}

return baseclass.extend({
        formatError: function(message) {
                var text = String(message || '').trim(), m;
                if ((m = text.match(/^Could not download the subscription \(curl: (-?\d+)\)$/)))
                        return _('Could not download the subscription (curl: %d)').format(+m[1]);
                if ((m = text.match(/^Binary not found: (.+)$/)))
                        return _('Binary not found: %s').format(m[1]);
                return _(text);
        },

	parse: function(link) {
		link = link.trim();
		var scheme = link.split('://')[0].toLowerCase(), o;

		switch (scheme) {
		case 'vless':  o = parseUrlLink(link, 'vless');  break;
		case 'trojan': o = parseUrlLink(link, 'trojan'); break;
		case 'vmess':  o = parseVmess(link); break;
		case 'ss':     o = parseSS(link); break;
		case 'hy2':
		case 'hysteria2': o = parseHy2(link); break;
		default:
			throw new Error(_("Unsupported scheme: %s").format(scheme));
		}

		o = compact(o);
		if (!o.address || !o.port || !(o.uuid || o.password))
			throw new Error(_("The link is missing an address, port, or key"));
		if (!o.alias)
			o.alias = o.address;
		o.link = link;
		return o;
	},

	fillOutbounds: function(opt, withBlock, withBalancers) {
		opt.value('direct', _("Direct"));
		[ [ 'byedpi', _("DPI Bypass: ByeDPI") ], [ 'zapret', _("DPI Bypass: Zapret 2") ] ].forEach(function(e) {
			var on = uci.get('keylink', e[0], 'enabled') == '1';
			opt.value(e[0], on ? e[1] : _("%s (disabled)").format(e[1]));
		});
		if (withBlock)
			opt.value('block', _("Block"));
		if (withBalancers)
			uci.sections('keylink', 'balancer').forEach(function(s) {
				opt.value(s['.name'], _("Balancer: %s").format(s.name || s['.name']));
			});
		this.fillServers(opt);

		/* в таблице ListValue показывает само значение, то есть ID секции
		 * сервера или балансировщика — подставляем его название */
		opt.textvalue = function(sid) {
			var v = this.cfgvalue(sid), i = (this.keylist || []).indexOf(v);
			if (i >= 0)
				return '%h'.format(this.vallist[i]);
			return v ? '%h'.format(_("%s (not found)").format(v)) : '—';
		};
	},

	fillServers: function(opt) {
		uci.sections('keylink', 'outbound').forEach(function(s) {
			opt.value(s['.name'], '%s (%s)'.format(s.alias || s.address, s.protocol));
		});
	},

	/* MultiValue без вариантов LuCI отрисовать не может (ui.Dropdown падает
	 * на Object.keys(null)), поэтому вместо виджета выводится подсказка */
	emptyHint: function(opt, text) {
		var render = opt.renderWidget;
		opt.renderWidget = function() {
			if ((this.keylist || []).length)
				return render.apply(this, arguments);
			return E('em', {}, text);
		};
	}
});
