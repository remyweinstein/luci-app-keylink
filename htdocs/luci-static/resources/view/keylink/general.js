'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require keylink.common as common';

var callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: [ 'name' ],
	expect: { '': {} }
});

var callRestart = rpc.declare({ object: 'keylink', method: 'restart', expect: { '': {} } });

function isRunning(list) {
	try {
		var inst = list.keylink.instances;
		return Object.keys(inst).some(function(k) { return inst[k].running; });
	} catch (e) {
		return false;
	}
}

function statusText(running) {
	return running ? _("KeyLink is running.") : _("KeyLink is stopped.");
}

var callUpdateCheck = rpc.declare({ object: 'keylink', method: 'update_check', expect: { '': {} } });
var callUpdateStart = rpc.declare({ object: 'keylink', method: 'update_start', expect: { '': {} } });
var callUpdateStatus = rpc.declare({ object: 'keylink', method: 'update_status', expect: { '': {} } });

return view.extend({
	load: function() {
		return Promise.all([
			callServiceList('keylink'),
			uci.load('keylink'),
			callUpdateStatus().catch(function() { return {}; })
		]);
	},

	showUpdate: function(content, buttons) {
		ui.showModal(_("KeyLink update"), [
			E('div', {}, content),
			E('div', { 'class': 'right' }, buttons || [
				E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _("Close"))
			])
		]);
	},

	handleUpdate: function() {
		this.showUpdate(E('p', { 'class': 'spinning' }, _("Checking for updates...")), []);
		return callUpdateStatus().then(L.bind(function(st) {
			if (st.running)
				return this.pollUpdate();
			return callUpdateCheck().then(L.bind(function(res) {
				if (!res.latest) {
					this.showUpdate(E('p', {}, common.formatError(res.error || 'No response')));
					return;
				}
				var current = res.current || _("unknown");
				var fresh = res.current == res.latest;
				this.showUpdate([
					E('p', {}, _("Installed version: %s").format(current)),
					E('p', {}, _("Latest release: %s").format(res.latest)),
					E('p', {}, fresh ? _("You have the latest version.")
						: _("Settings are kept. KeyLink restarts at the end of the update; the connection may drop for a few seconds."))
				], [
					E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _("Cancel")), ' ',
					E('button', {
						'class': 'cbi-button ' + (fresh ? 'cbi-button-neutral' : 'cbi-button-positive'),
						'click': ui.createHandlerFn(this, 'startUpdate')
					}, fresh ? _("Reinstall") : _("Update and restart"))
				]);
			}, this));
		}, this)).catch(L.bind(function(err) {
			this.showUpdate(E('p', {}, common.formatError(err.message)));
		}, this));
	},

	startUpdate: function() {
		this.showUpdate(E('p', { 'class': 'spinning' }, _("Starting update...")), []);
		return callUpdateStart().then(L.bind(function(res) {
			if (res.error) {
				this.showUpdate(E('p', {}, common.formatError(res.error)));
				return;
			}
			return this.pollUpdate();
		}, this));
	},

	pollUpdate: function() {
		/* во время перезапуска rpcd запрос может не пройти — просто ждём следующего */
		return callUpdateStatus().catch(function() { return {}; }).then(L.bind(function(st) {
			var log = E('pre', { 'style': 'max-height:20em; overflow:auto; white-space:pre-wrap' }, st.log || '');
			if (st.running || st.rc == null) {
				this.showUpdate([ E('p', { 'class': 'spinning' }, _("Updating KeyLink...")), log ], []);
				window.setTimeout(L.bind(this.pollUpdate, this), 2000);
			}
			else if (st.rc == 0) {
				this.showUpdate([ E('p', {}, _("Update complete: %s. Reload the page to load the new interface.").format(st.current || _("unknown"))), log ], [
					E('button', { 'class': 'cbi-button cbi-button-positive', 'click': function() { location.reload(); } }, _("Reload page"))
				]);
			}
			else {
				this.showUpdate([ E('p', {}, _("Update failed. See the log below.")), log ]);
			}
			if (log.scrollHeight)
				log.scrollTop = log.scrollHeight;
		}, this));
	},

	handleRestart: function() {
		return callRestart().then(function() {
			/* procd запускает Xray асинхронно — даём ему секунду */
			return new Promise(function(resolve) { window.setTimeout(resolve, 1500); });
		}).then(function() {
			return callServiceList('keylink');
		}).then(function(list) {
			var running = isRunning(list), el = document.getElementById('keylink-status');
			if (el)
				el.textContent = statusText(running);
			ui.addNotification(null, E('p', {}, running ? _("KeyLink restarted.")
				: _("KeyLink is stopped: it is disabled or failed to start. See logread -e keylink.")), running ? 'info' : 'warning');
		}).catch(function(err) {
			ui.addNotification(null, E('p', {}, common.formatError(err.message)), 'error');
		});
	},

	render: function(data) {
		var m, s, o;

		m = new form.Map('keylink', _('KeyLink'),
			'<span id="keylink-status">%h</span>'.format(statusText(isRunning(data[0]))));

		s = m.section(form.NamedSection, 'main', 'general', _("General Settings"));

		o = s.option(form.Flag, 'enabled', _("Enable"));
		o.rmempty = false;

		o = s.option(form.Button, '_restart', _("Service"),
			_("Restarts Xray, DPI bypass engines, and firewall rules with the saved settings. Unsaved changes on this page are not applied."));
		o.inputtitle = _("Restart");
		o.inputstyle = 'reload';
		o.onclick = L.bind(this.handleRestart, this);

		var ver = (data[2] || {}).current;
		o = s.option(form.Button, '_update', _("Version"),
			ver ? _("Installed version: %s").format(ver) : _("Installed version is unknown (installed before v0.3.4 or from source)."));
		o.inputtitle = _("Check for updates");
		o.inputstyle = 'action';
		o.onclick = L.bind(this.handleUpdate, this);

		o = s.option(form.ListValue, 'main_outbound', _("Default route"),
			_("Where to send traffic that does not match any rule."));
		common.fillOutbounds(o, false, true);

		o = s.option(form.Flag, 'tproxy', _("Transparent proxy for LAN"),
			_("All IPv4 traffic from LAN clients passes through Xray and the routing rules."));

		o = s.option(form.Value, 'lan_iface', _("LAN interface"));
		o.placeholder = 'br-lan';
		o.depends('tproxy', '1');

		o = s.option(form.Value, 'tproxy_port', _("TPROXY port"));
		o.datatype = 'port';
		o.placeholder = '12345';
		o.depends('tproxy', '1');

		o = s.option(form.Value, 'socks_port', _("SOCKS5 port"), _("0 to disable."));
		o.datatype = 'port';

		o = s.option(form.Value, 'http_port', _("HTTP proxy port"), _("0 to disable."));
		o.datatype = 'port';

		o = s.option(form.ListValue, 'domain_strategy', _("Domain strategy"),
			_("IPIfNonMatch: if no domain rule matches, resolve the domain and check IP rules."));
		o.value('AsIs');
		o.value('IPIfNonMatch');
		o.value('IPOnDemand');
		o.default = 'IPIfNonMatch';

		o = s.option(form.Value, 'probe_url', _("Latency check URL"),
			_("Used by the Check button and the Lowest latency and Least load balancers. Must return HTTP 204 or 200."));
		o.placeholder = 'https://www.gstatic.com/generate_204';

		o = s.option(form.Value, 'probe_interval', _("Background check interval"),
			_("How often Xray checks servers in balancers: 30s, 1m, 5m."));
		o.placeholder = '1m';

		o = s.option(form.ListValue, 'loglevel', _("Log level"));
		[ 'debug', 'info', 'warning', 'error', 'none' ].forEach(function(l) { o.value(l); });
		o.default = 'warning';

		return m.render();
	}
});
