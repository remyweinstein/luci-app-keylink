'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require rpc';
'require keylink.common as common';

var callUpdate = rpc.declare({
	object: 'keylink',
	method: 'update_sub',
	params: [ 'sid' ]
});

function fmtBytes(n) {
	var u = [ _("B"), _("KB"), _("MB"), _("GB"), _("TB") ], i = 0;
	n = +n || 0;
	while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
	return '%s %s'.format(i ? n.toFixed(1) : n, u[i]);
}

function fmtDate(ts) {
	return ts > 0 ? new Date(ts * 1000).toLocaleDateString() : null;
}

function fmtAgo(ts) {
	if (!(ts > 0)) return _("never updated");
	var m = Math.round((Date.now() / 1000 - ts) / 60);
	if (m < 1) return _("updated just now");
	if (m < 60) return _("updated %d min ago").format(m);
	if (m < 48 * 60) return _("updated %d h ago").format(Math.round(m / 60));
	return _("updated %s").format(fmtDate(ts));
}

return view.extend({
	load: function() {
		return uci.load('keylink');
	},

	updateOne: function(sid) {
		return callUpdate(sid).then(function(r) {
			if (!r || r.error)
                                throw new Error(r ? common.formatError(r.error) : _("No response"));
			return r;
		});
	},

	report: function(name, r) {
		return _("%s: %d servers (%d added, %d updated, %d removed)").format(
			name, r.total, r.added, r.updated, r.removed);
	},

	handleUpdate: function(sid) {
		var name = uci.get('keylink', sid, 'name') || sid;
		return this.updateOne(sid).then(L.bind(function(r) {
			ui.addNotification(null, E('p', this.report(name, r)), 'info');
			window.setTimeout(function() { location.reload(); }, 1500);
		}, this)).catch(function(e) {
			ui.addNotification(null, E('p', _('%s: %s').format(name, e.message)), 'danger');
		});
	},

	handleUpdateAll: function() {
		var self = this, lines = [], failed = false;
		var subs = uci.sections('keylink', 'subscription').filter(function(s) { return s.enabled != '0'; });

		return subs.reduce(function(p, s) {
			var name = s.name || s['.name'];
			return p.then(function() {
				return self.updateOne(s['.name']).then(function(r) {
					lines.push(E('li', self.report(name, r)));
				}).catch(function(e) {
					failed = true;
					lines.push(E('li', _('%s: %s').format(name, e.message)));
				});
			});
		}, Promise.resolve()).then(function() {
			if (!lines.length) return;
			ui.addNotification(null, E('ul', lines), failed ? 'warning' : 'info');
			window.setTimeout(function() { location.reload(); }, 2000);
		});
	},

	render: function() {
		var m, s, o, view = this;

		m = new form.Map('keylink', _("Subscriptions"),
			_("Subscription servers appear on the Servers tab and update automatically. Manual edits to these servers are overwritten on the next update. Rules and balancers keep their server references as long as the name, address, and port remain unchanged."));

		s = m.section(form.GridSection, 'subscription');
		s.anonymous = true;
		s.addremove = true;
		s.nodescriptions = true;
		s.modaltitle = function(sid) {
			return uci.get('keylink', sid, 'name') || _("New subscription");
		};

		/* удаляем вместе с подпиской и её серверы */
		s.handleRemove = function(sid, ev) {
			uci.sections('keylink', 'outbound').forEach(function(o) {
				if (o.subscription == sid)
					uci.remove('keylink', o['.name']);
			});
			return form.GridSection.prototype.handleRemove.apply(this, [ sid, ev ]);
		};

		s.renderRowActions = function(sid) {
			var td = form.GridSection.prototype.renderRowActions.apply(this, [ sid ]);
			var box = td.firstChild || td;
			box.insertBefore(E('button', {
				'class': 'cbi-button cbi-button-action',
				'click': ui.createHandlerFn(view, 'handleUpdate', sid)
			}, _("Update")), box.firstChild);
			return td;
		};

		o = s.option(form.Value, 'name', _("Name"));
		o.rmempty = false;

		o = s.option(form.Flag, 'enabled', _("Enabled"));
		o.default = '1';
		o.editable = true;
		o.rmempty = false;

		o = s.option(form.DummyValue, '_info', _("Status"));
		o.modalonly = false;
		o.textvalue = function(sid) {
			var sub = uci.get('keylink', sid) || {};
			var count = uci.sections('keylink', 'outbound').filter(function(x) { return x.subscription == sid; }).length;
			var lines = [ E('div', _("servers: %d, %s").format(count, fmtAgo(+sub.updated))) ];

			if (+sub.info_total > 0)
				lines.push(E('div', _("traffic: %s of %s").format(fmtBytes(sub.info_used), fmtBytes(sub.info_total))));
			else if (+sub.info_used > 0)
				lines.push(E('div', _("traffic: %s").format(fmtBytes(sub.info_used))));

			if (+sub.info_expire > 0) {
				var left = Math.floor((+sub.info_expire - Date.now() / 1000) / 86400);
				lines.push(E('div', { 'style': left < 3 ? 'color:red' : '' },
					left >= 0 ? _("expires %s (%d days left)").format(fmtDate(+sub.info_expire), left)
					          : _("expired %s").format(fmtDate(+sub.info_expire))));
			}
			return E('div', lines);
		};

		o = s.option(form.Value, 'url', _("Subscription URL"));
		o.modalonly = true;
		o.rmempty = false;
		o.placeholder = 'https://…';
		o.validate = function(sid, v) {
			return /^https?:\/\/\S+$/.test(v || '') ? true : _("Enter a URL such as https://...");
		};

		o = s.option(form.Value, 'update_interval', _("Update interval (hours)"),
			_("0 or empty for manual updates only."));
		o.modalonly = true;
		o.datatype = 'uinteger';
		o.placeholder = '12';
		o.default = '12';

		o = s.option(form.Flag, 'via_proxy', _("Download through proxy"),
			_("Use this if the subscription URL is blocked. Requires an enabled SOCKS5 port on the General tab and a working server."));
		o.modalonly = true;

		o = s.option(form.Value, 'user_agent', _('User-Agent'),
			_("Many panels return link lists only to recognized clients."));
		o.modalonly = true;
		o.placeholder = 'v2rayN/7.0';
		[ 'v2rayN/7.0', 'v2rayNG/1.9', 'Streisand', 'Happ/1.0' ].forEach(function(v) { o.value(v); });

		o = s.option(form.Value, 'include', _("Include servers whose names match"),
			_("Case-insensitive regular expression, for example: Netherlands|Germany|DE"));
		o.modalonly = true;

		o = s.option(form.Value, 'exclude', _("Exclude servers whose names match"),
			_("For example: RU|Russia|traffic|expires"));
		o.modalonly = true;

		return m.render().then(L.bind(function(mapEl) {
			return E([], [
				E('div', { 'class': 'cbi-section', 'style': 'display:flex;gap:.5em;align-items:center' }, [
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': ui.createHandlerFn(this, 'handleUpdateAll')
					}, _("Update all")),
					E('span', { 'class': 'cbi-section-descr', 'style': 'margin:0' },
						_("Save and apply a new subscription first."))
				]),
				mapEl
			]);
		}, this));
	}
});
