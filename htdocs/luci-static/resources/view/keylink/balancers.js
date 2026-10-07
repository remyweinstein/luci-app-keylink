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
		var m, s, o, subs;

		var needMembers = function(sid) {
			var sel = this.section.formvalue(sid, 'subscriptions');
			var own = this.section.formvalue(sid, 'servers');
			return (L.toArray(sel).length || L.toArray(own).length) ? true : _("Select a subscription or at least one server");
		};

		m = new form.Map('keylink', _("Balancers"),
			_("A balancer distributes traffic across multiple servers. Select it as the default route on the General tab or as a target in a routing rule."));

		s = m.section(form.GridSection, 'balancer');
		s.anonymous = true;
		s.addremove = true;
		s.nodescriptions = true;
		s.modaltitle = function(sid) {
			return uci.get('keylink', sid, 'name') || _("New balancer");
		};

		o = s.option(form.Value, 'name', _("Name"));
		o.rmempty = false;

		o = s.option(form.ListValue, 'strategy', _("Strategy"),
			_("Lowest latency and Least load regularly check servers and automatically select the best one, switching to the next if it fails."));
		o.value('leastPing', _("Lowest latency"));
		o.value('leastLoad', _("Least load (stability)"));
		o.value('random', _("Random"));
		o.value('roundRobin', _("Round-robin"));
		o.default = 'leastPing';

		o = subs = s.option(form.MultiValue, 'subscriptions', _("All servers from subscriptions"),
			_("Membership updates with the subscription."));
		uci.sections('keylink', 'subscription').forEach(function(sub) {
			o.value(sub['.name'], sub.name || sub['.name']);
		});
		o.textvalue = function(sid) {
			var v = L.toArray(this.cfgvalue(sid));
			return v.length ? v.map(function(x) { return uci.get('keylink', x, 'name') || x; }).join(', ') : '—';
		};
		common.emptyHint(o, _("No subscriptions"));

		o = s.option(form.MultiValue, 'servers', _("Individual servers"));
		common.fillServers(o);
		o.textvalue = function(sid) {
			var v = L.toArray(this.cfgvalue(sid));
			return v.length ? _("%d selected").format(v.length) : '—';
		};
		common.emptyHint(o, _("No servers. Add them on the Servers tab."));
		/* проверку несёт список серверов, а если серверов нет и он отрисован
		 * подсказкой — список подписок */
		(o.keylist && o.keylist.length ? o : subs).validate = needMembers;

		o = s.option(form.ListValue, 'fallback', _("If all servers are unavailable"),
			_("Works with latency- and load-based strategies."));
		o.value('', _("do nothing"));
		common.fillOutbounds(o, true, false);
		o.modalonly = true;

		return m.render();
	}
});
