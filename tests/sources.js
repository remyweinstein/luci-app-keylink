'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

String.prototype.format = function(...args) {
	let i = 0;
	return this.replace(/%s/g, () => args[i++]);
};

const options = {};
const config = {
	main: { wg_enabled: '1', wg_ifaces: [ 'wg0', 'wg1', 'old0' ], tproxy_port: '12345' },
	interface: [
		{ '.name': 'lan', proto: 'static', addresses: [ '192.168.1.1/24' ] },
		{ '.name': 'wg0', proto: 'wireguard', addresses: [ '10.0.0.1/24' ] },
		{ '.name': 'wg1', proto: 'wireguard', addresses: [ '10.9.0.1/24' ],
			route_allowed_ips: '1', allowed_ips: [ '0.0.0.0/0' ] }
	],
	route: []
};

const uci = {
	load: () => Promise.resolve(),
	get: (conf, sid, key) => config[sid]?.[key],
	sections: (conf, type) => config[type] || []
};
const section = {
	option: (type, name, title, description) => {
		options[name] = {
			type, name, title, description, values: [],
			value(value, label) { this.values.push([ value, label ]); },
			depends() {}, placeholder: null, datatype: null
		};
		return options[name];
	}
};
const form = {
	Flag: 'flag',
	MultiValue: 'multi',
	DynamicList: 'list',
	DummyValue: 'dummy',
	Map: function() {
		this.section = () => section;
		this.render = () => options;
	}
};
function E(tag, attrs, children) {
	if (typeof attrs != 'object')
		children = attrs;
	return { tag, attrs, children };
}
function text(node) {
	if (node == null)
		return '';
	if (typeof node == 'string')
		return node;
	if (Array.isArray(node))
		return node.map(text).join(' ');
	return text(node.children);
}

const source = fs.readFileSync(path.join(__dirname,
	'../htdocs/luci-static/resources/view/keylink/sources.js'), 'utf8');
const view = new Function('view', 'form', 'uci', 'common', 'L', 'E', '_', source)(
	{ extend: value => value }, form, uci,
	{ emptyHint() {} }, { toArray: v => v == null ? [] : [].concat(v) }, E, value => value
);
view.render();

assert.equal(options.wg_enabled.type, form.Flag);
assert.equal(options.wg_ifaces.type, form.MultiValue);
assert.equal(options.wg_sources.type, form.DynamicList);
assert.equal(options.wg_sources.validate('main', '10.0.0.0/24'), true);
assert.equal(options.wg_sources.validate('main', '10.0.0.5'), true);
assert.notEqual(options.wg_sources.validate('main', '10.0.0.0/33'), true);
assert.notEqual(options.wg_sources.validate('main', 'not-an-ip'), true);

const ifaces = options.wg_ifaces.values.map(v => v[0]);
assert.deepEqual(ifaces, [ 'wg0', 'wg1', 'old0' ], 'only wireguard interfaces plus saved missing values');
assert(!ifaces.includes('lan'));

const labels = Object.fromEntries(options.wg_ifaces.values);
assert.match(labels.wg0, /10\.0\.0\.1\/24/);
assert.match(labels.wg1, /default route, possible loop/);
assert.match(labels.old0, /not found/);

const dns = text(options._wg_dns.textvalue());
assert.match(dns, /10\.0\.0\.1/, 'DNS hint uses the address of the selected WireGuard interface');
assert.match(dns, /dnsmasq/);
assert.match(dns, /Xray DNS is disabled/);

const limits = text(options._wg_limits.textvalue());
assert.match(limits, /IPv4 only/);
assert.match(limits, /routing loops are possible/);
assert.match(limits, /wg1/, 'selected uplink-like interface is called out');
assert.match(limits, /route back to WireGuard clients/);

console.log('OK: WireGuard sources UI filters interfaces and shows uplink/DNS warnings');
