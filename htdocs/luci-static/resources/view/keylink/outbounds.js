'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require rpc';
'require keylink.common as common';

var callPing = rpc.declare({
	object: 'keylink',
	method: 'ping',
	params: [ 'sid' ]
});

/* результаты живут, пока открыта страница, и переживают перерисовку таблицы */
var pingResults = {};

function pingLabel(sid) {
	var r = pingResults[sid];
	if (!r) return [ '—', '' ];
	if (r.pending) return [ _("checking..."), '' ];
	if (r.ms != null) return [ _("%d ms").format(r.ms), r.ms < 300 ? 'green' : (r.ms < 800 ? 'darkorange' : 'red') ];
        return [ common.formatError(r.error) || _("error"), 'red' ];
}

function updatePingCell(sid) {
	var el = document.querySelector('[data-xl-ping="%s"]'.format(sid));
	if (!el) return;
	var l = pingLabel(sid);
	el.textContent = l[0];
	el.style.color = l[1];
}

return view.extend({
	handlePing: function(sid) {
		pingResults[sid] = { pending: true };
		updatePingCell(sid);
		return callPing(sid).then(function(res) {
			pingResults[sid] = res || { error: _("No response") };
		}).catch(function(e) {
			pingResults[sid] = { error: e.message };
		}).then(function() {
			updatePingCell(sid);
		});
	},

	handlePingAll: function() {
		var sids = uci.sections('keylink', 'outbound').map(function(s) { return s['.name']; });
		var self = this, next = 0;

		function worker() {
			if (next >= sids.length)
				return Promise.resolve();
			return self.handlePing(sids[next++]).then(worker);
		}

		/* три проверки одновременно — роутеру хватит, а ждать меньше */
		return Promise.all([ worker(), worker(), worker() ]);
	},

	handleImport: function(m, ta) {
		var lines = ta.value.split(/\r?\n/).map(function(l) { return l.trim(); }).filter(Boolean);
		var added = 0, errors = [];

		lines.forEach(function(line) {
			try {
				var o = common.parse(line);
				var sid = uci.add('keylink', 'outbound');
				Object.keys(o).forEach(function(k) { uci.set('keylink', sid, k, o[k]); });
				added++;
			}
			catch (e) {
				errors.push(E('li', '%s… — %s'.format(line.substr(0, 40), e.message)));
			}
		});

		if (errors.length)
			ui.addNotification(_("Some links could not be imported"), E('ul', errors), 'warning');

		if (!added)
			return Promise.resolve();

		ta.value = '';
		return m.save().then(function() {
			ui.addNotification(null, E('p',
				_("Servers added: %d. Click Save & Apply to make them available to Xray.").format(added)), 'info');
		});
	},

	render: function() {
		var m, s, o;

		m = new form.Map('keylink', _("Servers"),
			_("Order does not matter: select the default server on the General tab; other servers are used in routing rules."));

		s = m.section(form.GridSection, 'outbound');
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;
		s.nodescriptions = true;
		s.modaltitle = function(sid) {
			return uci.get('keylink', sid, 'alias') || _("New server");
		};

		var view = this;
		s.renderRowActions = function(sid) {
			var td = form.GridSection.prototype.renderRowActions.apply(this, [ sid ]);
			var box = td.firstChild || td;
			box.insertBefore(E('button', {
				'class': 'cbi-button',
				'title': _("Check latency through this server"),
				'click': ui.createHandlerFn(view, 'handlePing', sid)
			}, _("Check")), box.firstChild);
			return td;
		};

		s.tab('main', _("Basic"));
		s.tab('transport', _("Transport and Encryption"));

		o = s.taboption('main', form.Value, 'alias', _("Name"));

		o = s.taboption('main', form.ListValue, 'protocol', _("Protocol"));
		o.value('vless', 'VLESS');
		o.value('vmess', 'VMess');
		o.value('trojan', 'Trojan');
		o.value('shadowsocks', 'Shadowsocks');
		o.value('hysteria2', 'Hysteria2');

		o = s.taboption('main', form.Value, 'address', _("Address"));
		o.datatype = 'host';
		o.rmempty = false;

		o = s.taboption('main', form.Value, 'port', _("Port"));
		o.datatype = 'port';
		o.rmempty = false;

		o = s.taboption('main', form.DummyValue, '_sub', _("Subscription"));
		o.modalonly = false;
		o.textvalue = function(sid) {
			var sub = uci.get('keylink', sid, 'subscription');
			return sub ? (uci.get('keylink', sub, 'name') || sub) : '—';
		};

		o = s.taboption('main', form.DummyValue, '_ping', _("Latency"));
		o.modalonly = false;
		o.textvalue = function(sid) {
			var l = pingLabel(sid);
			return E('span', { 'data-xl-ping': sid, 'style': 'color:' + l[1] }, l[0]);
		};

		o = s.taboption('main', form.Value, 'uuid', _('UUID'));
		o.modalonly = true;
		o.depends('protocol', 'vless');
		o.depends('protocol', 'vmess');

		o = s.taboption('main', form.Value, 'password', _("Password"));
		o.password = true;
		o.modalonly = true;
		o.depends('protocol', 'trojan');
		o.depends('protocol', 'shadowsocks');
		o.depends('protocol', 'hysteria2');

		o = s.taboption('main', form.Value, 'method', _("Encryption"));
		o.modalonly = true;
		[ 'auto', 'aes-128-gcm', 'aes-256-gcm', 'chacha20-poly1305', 'chacha20-ietf-poly1305',
		  '2022-blake3-aes-128-gcm', '2022-blake3-aes-256-gcm', 'none' ].forEach(function(v) { o.value(v); });
		o.depends('protocol', 'vmess');
		o.depends('protocol', 'shadowsocks');

		o = s.taboption('main', form.ListValue, 'flow', _('Flow'));
		o.modalonly = true;
		o.value('', _("none"));
		o.value('xtls-rprx-vision');
		o.depends('protocol', 'vless');

		o = s.taboption('transport', form.ListValue, 'network', _("Transport"));
		o.modalonly = true;
		[ 'tcp', 'ws', 'grpc', 'xhttp', 'httpupgrade' ].forEach(function(v) { o.value(v); });
		o.default = 'tcp';
		[ 'vless', 'vmess', 'trojan', 'shadowsocks' ].forEach(function(p) { o.depends('protocol', p); });

		o = s.taboption('transport', form.ListValue, 'security', _("Security"));
		o.modalonly = true;
		o.value('none', _("none"));
		o.value('tls', 'TLS');
		o.value('reality', 'REALITY');
		[ 'vless', 'vmess', 'trojan', 'shadowsocks' ].forEach(function(p) { o.depends('protocol', p); });

		o = s.taboption('transport', form.Value, 'sni', _('SNI'));
		o.modalonly = true;
		o.depends('security', 'tls');
		o.depends('security', 'reality');
		o.depends('protocol', 'hysteria2');

		o = s.taboption('transport', form.Value, 'fp', _("uTLS fingerprint"));
		o.modalonly = true;
		[ '', 'chrome', 'firefox', 'safari', 'ios', 'edge', 'random' ].forEach(function(v) { o.value(v); });
		o.depends('security', 'tls');
		o.depends('security', 'reality');

		o = s.taboption('transport', form.Value, 'public_key', _("Public key (pbk)"));
		o.modalonly = true;
		o.depends('security', 'reality');

		o = s.taboption('transport', form.Value, 'short_id', _('Short ID (sid)'));
		o.modalonly = true;
		o.depends('security', 'reality');

		o = s.taboption('transport', form.Value, 'spider_x', _('SpiderX (spx)'));
		o.modalonly = true;
		o.depends('security', 'reality');

		o = s.taboption('transport', form.Value, 'alpn', _('ALPN'), _("Comma-separated, for example h2,http/1.1. Hysteria2 defaults to h3."));
		o.modalonly = true;
		o.depends('security', 'tls');
		o.depends('protocol', 'hysteria2');

		o = s.taboption('transport', form.Flag, 'insecure', _("Skip certificate verification"));
		o.modalonly = true;
		o.depends('security', 'tls');
		o.depends('protocol', 'hysteria2');

		s.tab('hy2', _('Hysteria2'));

		o = s.taboption('hy2', form.Value, 'obfs_password', _("Salamander obfuscation password"),
			_("Leave empty if obfuscation is disabled on the server."));
		o.modalonly = true;
		o.password = true;
		o.depends('protocol', 'hysteria2');

		o = s.taboption('hy2', form.Value, 'hop_ports', _("Port hopping range"),
			_("For example, 20000-50000. The server must forward this range to its listening port."));
		o.modalonly = true;
		o.depends('protocol', 'hysteria2');

		o = s.taboption('hy2', form.Value, 'hop_interval', _("Hopping interval (seconds)"),
			_("A number or range, at least 5."));
		o.modalonly = true;
		o.placeholder = '5-30';
		o.depends('protocol', 'hysteria2');

		o = s.taboption('hy2', form.Value, 'up', _("Upload speed"),
			_("For example, 50mbps. Leave empty for automatic bandwidth control (BBR)."));
		o.modalonly = true;
		o.depends('protocol', 'hysteria2');

		o = s.taboption('hy2', form.Value, 'down', _("Download speed"),
			_("For example, 200mbps."));
		o.modalonly = true;
		o.depends('protocol', 'hysteria2');

		o = s.taboption('transport', form.Value, 'path', _("Path"));
		o.modalonly = true;
		o.depends('network', 'ws');
		o.depends('network', 'xhttp');
		o.depends('network', 'httpupgrade');

		o = s.taboption('transport', form.Value, 'host', _('Host'));
		o.modalonly = true;
		o.depends('network', 'ws');
		o.depends('network', 'xhttp');
		o.depends('network', 'httpupgrade');

		o = s.taboption('transport', form.Value, 'mode', _("XHTTP mode"));
		o.modalonly = true;
		[ '', 'auto', 'packet-up', 'stream-up', 'stream-one' ].forEach(function(v) { o.value(v); });
		o.depends('network', 'xhttp');

		o = s.taboption('transport', form.Value, 'service_name', _('gRPC serviceName'));
		o.modalonly = true;
		o.depends('network', 'grpc');

		return m.render().then(L.bind(function(mapEl) {
			var ta = E('textarea', {
				'class': 'cbi-input-textarea',
				'rows': 4,
				'style': 'width:100%;font-family:monospace',
				'placeholder': 'vless://…\nvmess://…\ntrojan://…\nss://…\nhysteria2://…'
			});

			var toolbar = E('div', { 'class': 'cbi-section', 'style': 'display:flex;gap:.5em;align-items:center' }, [
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, 'handlePingAll')
				}, _("Check all")),
				E('span', { 'class': 'cbi-section-descr', 'style': 'margin:0' },
					_("Checks use saved and applied settings."))
			]);

			return E([], [
				toolbar,
				mapEl,
				E('div', { 'class': 'cbi-section' }, [
					E('h3', _("Add from links")),
					E('p', { 'class': 'cbi-section-descr' },
						_("Paste one or more links, one per line.")),
					ta,
					E('div', { 'style': 'margin-top:.5em' },
						E('button', {
							'class': 'cbi-button cbi-button-add',
							'click': ui.createHandlerFn(this, 'handleImport', m, ta)
						}, _("Add servers")))
				])
			]);
		}, this));
	}
});
