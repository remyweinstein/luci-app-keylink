'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require rpc';
'require fs';
'require keylink.common as common';

var callStart = rpc.declare({ object: 'keylink', method: 'dpi_test_start', params: [ 'engine', 'presets' ] });
var callStatus = rpc.declare({ object: 'keylink', method: 'dpi_test_status' });
var callStop = rpc.declare({ object: 'keylink', method: 'dpi_test_stop' });

var ENGINES = {
	byedpi: { title: _('ByeDPI') },
	zapret: { title: _('Zapret 2') }
};

function hostOf(url) {
	var m = String(url).match(/^\w+:\/\/([^\/:?#]+)/);
	return m ? m[1].replace(/^www\./, '') : url;
}

function score(r) {
	var ok = 0, t = 0;
	(r.ok || []).forEach(function(v, i) { if (v) { ok++; t += (r.ms || [])[i] || 0; } });
	return { ok: ok, t: t };
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('keylink'),
			L.resolveDefault(fs.read('/usr/share/keylink/dpi_presets.json'), '{}')
				.then(function(t) { try { return JSON.parse(t); } catch (e) { return {}; } }),
			L.resolveDefault(callStatus(), {})
		]);
	},

	presetName: function(engine, id) {
		if (id == '_direct') return _("Without bypass");
		var p = (this.presets[engine] || []).filter(function(x) { return x.id == id; })[0];
                return p ? _(p.name) : id;
	},

	handleApply: function(engine, id) {
		uci.set('keylink', engine, 'preset', id);
		uci.set('keylink', engine, 'enabled', '1');
		return uci.save().then(function() {
			ui.addNotification(null, E('p',
				_("Preset selected. Click Save & Apply at the top of the page.")), 'info');
			window.setTimeout(function() { location.reload(); }, 1200);
		});
	},

	handleAddRule: function(engine) {
		var name = engine == 'zapret' ? 'Zapret 2' : 'ByeDPI';
		var sid = uci.add('keylink', 'rule');
		uci.set('keylink', sid, 'name', _("YouTube and Discord via %s").format(name));
		uci.set('keylink', sid, 'enabled', '1');
		uci.set('keylink', sid, 'outbound', engine);
		uci.set('keylink', sid, 'domain', [ 'geosite:youtube', 'geosite:discord' ]);

		if (engine == 'zapret' && uci.get('keylink', 'zapret', 'discord_voice') == '1') {
			var v = uci.add('keylink', 'rule');
			uci.set('keylink', v, 'name', _("Discord voice via Zapret 2"));
			uci.set('keylink', v, 'enabled', '1');
			uci.set('keylink', v, 'outbound', 'zapret');
			uci.set('keylink', v, 'network', 'udp');
			uci.set('keylink', v, 'port', '50000-65535');
		}

		uci.set('keylink', engine, 'enabled', '1');
		return uci.save().then(function() {
			ui.addNotification(null, E('p',
				_("The rule was added at the end of the Routing tab. Click Save & Apply.")), 'info');
			window.setTimeout(function() { location.reload(); }, 1200);
		});
	},

	handleTest: function(engine) {
		var box = document.getElementById('xl-dpi-results');
		if (box) box.replaceChildren(E('p', { 'class': 'spinning' }, _("Starting test...")));
		return callStart(engine, '').then(L.bind(function(r) {
                        if (r && r.error) throw new Error(common.formatError(r.error));
			/* дать тестеру время записать первые данные */
			return new Promise(function(resolve) { window.setTimeout(resolve, 1500); });
		}, this)).then(L.bind(this.poll, this)).catch(L.bind(function(e) {
			if (box) box.replaceChildren(E('p', { 'style': 'color:red' }, e.message));
			ui.addNotification(null, E('p', e.message), 'danger');
		}, this));
	},

	handleStop: function() {
		return callStop().then(L.bind(this.poll, this));
	},

	poll: function() {
		window.clearTimeout(this.timer);
		return callStatus().then(L.bind(function(st) {
			this.renderStatus(st || {});
			if (st && st.running)
				this.timer = window.setTimeout(L.bind(this.poll, this), 2000);
		}, this));
	},

	renderStatus: function(st) {
		var box = document.getElementById('xl-dpi-results');
		if (!box) return;

		var info = st.info || {}, engine = info.engine;
		var results = st.results || [];

		if (!engine && st.error) {
                        var nodes = [ E('p', { 'style': 'color:red' }, _("Could not start the test: %s").format(common.formatError(st.error))) ];
			if (/ciadpi|nfqws2|zapret-lib/.test(st.error))
				nodes.push(E('p', { 'class': 'cbi-section-descr' },
					_("The engine is not installed. Install it with: wget -qO- https://github.com/remyweinstein/luci-app-keylink/releases/latest/download/install.sh | sh -s -- --with-byedpi --with-zapret")));
			box.replaceChildren.apply(box, nodes);
			return;
		}

		if (!engine) {
			box.replaceChildren(E('p', { 'class': 'cbi-section-descr' },
				_("The tester runs each preset in turn and opens the sites listed above through it. This takes a few minutes.")));
			return;
		}

		var done = results.filter(function(r) { return r.id != '_direct'; }).length;
		var head = E('p', {}, st.running
			? _("%s: tested %d of %d...").format(ENGINES[engine].title, done, info.total)
			: _("%s: test complete, %d presets.").format(ENGINES[engine].title, done));

		if (st.error)
                        head = E('p', { 'style': 'color:red' }, _("Test failed: %s").format(common.formatError(st.error)));

		var direct = results.filter(function(r) { return r.id == '_direct'; })[0];
		var rows = results.filter(function(r) { return r.id != '_direct'; }).sort(function(a, b) {
			var sa = score(a), sb = score(b);
			return sb.ok - sa.ok || sa.t - sb.t;
		});
		if (direct) rows.unshift(direct);

		var sites = info.sites || [];
		var table = E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [ E('th', { 'class': 'th' }, _("Preset")) ]
				.concat(sites.map(function(u) { return E('th', { 'class': 'th' }, hostOf(u)); }))
				.concat([ E('th', { 'class': 'th' }, _("Result")), E('th', { 'class': 'th' }, '') ]))
		]);

		rows.forEach(L.bind(function(r) {
			var s = score(r), all = s.ok == sites.length && sites.length > 0;
			var cells = [ E('td', { 'class': 'td' }, this.presetName(engine, r.id)) ];

			if (r.error) {
                                cells.push(E('td', { 'class': 'td', 'colspan': sites.length + 1, 'style': 'color:red' }, common.formatError(r.error)));
			}
			else {
				sites.forEach(function(u, i) {
					var ok = (r.ok || [])[i];
					cells.push(E('td', { 'class': 'td', 'style': 'color:' + (ok ? 'green' : 'red') },
						ok ? _("✓ %.1f s").format(((r.ms || [])[i] || 0) / 1000) : '✗'));
				});
				cells.push(E('td', { 'class': 'td' }, '%d/%d'.format(s.ok, sites.length)));
			}

			cells.push(E('td', { 'class': 'td' }, (r.id != '_direct' && !r.error && s.ok > 0) ? E('button', {
				'class': 'cbi-button ' + (all ? 'cbi-button-positive' : ''),
				'click': ui.createHandlerFn(this, 'handleApply', engine, r.id)
			}, _("Use")) : ''));

			table.appendChild(E('tr', { 'class': 'tr', 'style': all && r.id != '_direct' ? 'font-weight:bold' : '' }, cells));
		}, this));

		var nodes = [ head ];
		if (direct && score(direct).ok == sites.length)
			nodes.push(E('p', { 'class': 'cbi-section-descr' },
				_("All sites work without bypass, so they are not currently blocked and comparing presets may not help. YouTube throttling may not be visible on the home page: add a URL that downloads a substantial amount of data.")));
		nodes.push(table);
		box.replaceChildren.apply(box, nodes);
	},

	engineSection: function(m, engine, descr) {
		var s = m.section(form.NamedSection, engine, engine, ENGINES[engine].title, descr), o;
		var presets = this.presets[engine] || [];

		o = s.option(form.Flag, 'enabled', _("Enable"));
		o.rmempty = false;

		o = s.option(form.ListValue, 'preset', _("Strategy"));
                presets.forEach(function(p) { o.value(p.id, _(p.name)); });
		o.value('custom', _("Custom arguments"));
		o.description = _("Use the tester below to find a strategy: different ISPs require different strategies.");

		return s;
	},

	render: function(data) {
		this.presets = data[1] || {};
		var m, s, o, view = this;

		m = new form.Map('keylink', _("DPI Bypass"),
			_("Both engines bypass blocking and throttling on the router without a VPN server: they alter the start of a connection so your ISP's DPI cannot identify the site. Helps with domain-based blocking and throttling (YouTube, Discord), but not IP-based blocking. Route traffic to an engine using the Routing tab or the buttons below."));

		s = this.engineSection(m, 'byedpi',
			_("A local SOCKS proxy operating at the connection level with low CPU usage. Requires the byedpi package (ciadpi binary)."));

		o = s.option(form.Value, 'custom_args', _("ciadpi arguments"),
			_("For example: --disorder 1 --tlsrec 1+s. Omit -i and -p; the service sets them."));
		o.depends('preset', 'custom');

		o = s.option(form.Value, 'port', _("Port"));
		o.datatype = 'port';
		o.placeholder = '10801';

		s = this.engineSection(m, 'zapret',
			_("Operates at the packet level through NFQUEUE and modifies the handshake on the fly; handles QUIC better. Requires zapret2 (nfqws2) and kmod-nft-queue. Disable the standalone zapret2 service if installed; Xray manages the traffic."));

		o = s.option(form.TextValue, 'custom_args', _("nfqws2 arguments"),
			_("Separate profiles with --new, for example: --filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=multidisorder:pos=1,midsld. Omit --qnum and --lua-init; the service sets them. ${FAKE} is replaced with the zapret2 fake packet directory."));
		o.rows = 4;
		o.depends('preset', 'custom');

		o = s.option(form.Flag, 'discord_voice', _("Discord voice bypass"),
			_("Adds fake packets for Discord voice UDP traffic (ports 50000-65535). The button below also creates a routing rule for it."));

		o = s.option(form.Value, 'qnum', _("NFQUEUE number"));
		o.datatype = 'range(0,65535)';
		o.placeholder = '200';

		s = m.section(form.NamedSection, 'main', 'general', _("Strategy Tester"));

		o = s.option(form.DynamicList, 'dpi_test_sites', _("Test sites"),
			_("A site passes if it responds within the timeout. Sites blocked by IP will fail with every preset."));
		o.datatype = 'string';
		o.validate = function(sid, v) {
			return (!v || /^https?:\/\/[^\s"\\]+$/.test(v)) ? true : _("Enter a URL such as https://...");
		};

		o = s.option(form.Value, 'dpi_test_timeout', _("Timeout (seconds)"));
		o.datatype = 'range(2,30)';
		o.placeholder = '8';

		return m.render().then(L.bind(function(mapEl) {
			var buttons = E('div', { 'class': 'cbi-section' }, [
				E('h3', _("Quick Actions")),
				E('div', { 'style': 'display:flex;gap:.5em;flex-wrap:wrap' }, [
					E('button', { 'class': 'cbi-button cbi-button-add', 'click': ui.createHandlerFn(this, 'handleAddRule', 'byedpi') },
						_("YouTube and Discord via ByeDPI")),
					E('button', { 'class': 'cbi-button cbi-button-add', 'click': ui.createHandlerFn(this, 'handleAddRule', 'zapret') },
						_("YouTube and Discord via Zapret 2"))
				]),
				E('h3', { 'style': 'margin-top:1em' }, _("Preset Tests")),
				E('p', { 'class': 'cbi-section-descr' },
					_("Tests use saved settings: apply changes first if you edited the site list. Testing puts a noticeable load on the router.")),
				E('div', { 'style': 'display:flex;gap:.5em;flex-wrap:wrap' }, [
					E('button', { 'class': 'cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, 'handleTest', 'byedpi') },
						_("Test ByeDPI presets")),
					E('button', { 'class': 'cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, 'handleTest', 'zapret') },
						_("Test Zapret 2 presets")),
					E('button', { 'class': 'cbi-button cbi-button-reset', 'click': ui.createHandlerFn(this, 'handleStop') },
						_("Stop"))
				]),
				E('div', { 'id': 'xl-dpi-results', 'style': 'margin-top:1em;overflow-x:auto' })
			]);

			window.setTimeout(L.bind(function() {
				this.renderStatus(data[2] || {});
				if (data[2] && data[2].running) this.poll();
			}, this), 0);

			return E([], [ mapEl, buttons ]);
		}, this));
	}
});
