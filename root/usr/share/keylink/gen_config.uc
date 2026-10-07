'use strict';

/*
 * Генерация config.json для Xray из /etc/config/keylink.
 *   ucode gen_config.uc                   — полный конфиг
 *   ucode gen_config.uc test <sid> <port> — один сервер + SOCKS на 127.0.0.1:<port>
 */

import { cursor } from 'uci';
import { popen, access } from 'fs';

const c = cursor();
c.load('keylink');
const g = c.get_all('keylink', 'main') || {};
const probe = g.probe_url || 'https://www.gstatic.com/generate_204';

/* Формат прыжков по портам Hysteria2 зависит от версии Xray:
 * до 26.9.9 — finalmask.quicParams.udpHop, начиная с 26.9.9 — маска «udphop» в finalmask.udp */
function xrayVersion() {
	let p = popen('xray version 2>/dev/null', 'r');
	let out = p ? p.read('all') : '';
	if (p) p.close();
	let m = match(out || '', /Xray ([0-9]+)\.([0-9]+)\.([0-9]+)/);
	return m ? [ +m[1], +m[2], +m[3] ] : null;
}

function atLeast(v, a, b, c) {
	if (!v) return false;
	if (v[0] != a) return v[0] > a;
	if (v[1] != b) return v[1] > b;
	return v[2] >= c;
}

const XRAY_VER = xrayVersion();
const hopAsMask = atLeast(XRAY_VER, 26, 9, 9);
/* Hysteria2 появилась в 26.3.27; на старой версии такой сервер не даст Xray запуститься вовсе.
 * Если версию определить не удалось — не мешаем (пусть решает сам Xray) */
const hy2Supported = !XRAY_VER || atLeast(XRAY_VER, 26, 3, 27);

/* Базы geoip/geosite необязательны (на роутерах с малой памятью их может не быть) */
const ASSETS = '/usr/share/v2ray';
const hasGeoip = !!access(ASSETS + '/geoip.dat', 'r');
const hasGeosite = !!access(ASSETS + '/geosite.dat', 'r');
const PRIVATE_NETS = [ '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8',
	'169.254.0.0/16', '172.16.0.0/12', '192.168.0.0/16', '224.0.0.0/4', '240.0.0.0/4',
	'::1/128', 'fc00::/7', 'fe80::/10' ];
let skipped = {}, skippedServers = {};

/* Убирает значения, для которых нет базы: geoip:private заменяется явными подсетями */
function geo(values) {
	if (values == null) return null;
	let out = [];
	for (let v in values) {
		if (substr(v, 0, 6) == 'geoip:' && !hasGeoip) {
			if (v == 'geoip:private') { for (let n in PRIVATE_NETS) push(out, n); }
			else skipped[v] = true;
		}
		else if (substr(v, 0, 8) == 'geosite:' && !hasGeosite)
			skipped[v] = true;
		else
			push(out, v);
	}
	return out;
}

/* Убирает null, пустые строки, пустые массивы и объекты */
function clean(v) {
	if (type(v) == 'object') {
		let r = {};
		for (let k, x in v) {
			x = clean(x);
			if (x == null || x === '' ||
			    (type(x) == 'array' && !length(x)) ||
			    (type(x) == 'object' && !length(keys(x))))
				continue;
			r[k] = x;
		}
		return r;
	}
	if (type(v) == 'array')
		return filter(map(v, clean), x => x != null && x !== '');
	return v;
}

function list(v) {
	if (v == null || v === '') return null;
	return type(v) == 'array' ? v : split(v, /[ ,]+/);
}

function stream(s) {
	let net = s.network || 'tcp', sec = s.security || 'none';
	let st = { network: net, security: sec };

	if (sec == 'tls')
		st.tlsSettings = {
			serverName: s.sni, fingerprint: s.fp, alpn: list(s.alpn),
			allowInsecure: s.insecure == '1'
		};
	else if (sec == 'reality')
		st.realitySettings = {
			serverName: s.sni, fingerprint: s.fp || 'chrome',
			publicKey: s.public_key, shortId: s.short_id, spiderX: s.spider_x
		};

	if (net == 'ws')
		st.wsSettings = { path: s.path, host: s.host };
	else if (net == 'grpc')
		st.grpcSettings = { serviceName: s.service_name };
	else if (net == 'httpupgrade')
		st.httpupgradeSettings = { path: s.path, host: s.host };
	else if (net == 'xhttp')
		st.xhttpSettings = { path: s.path, host: s.host, mode: s.mode };

	return st;
}

/* Hysteria2: TLS обязателен, пароль — в hysteriaSettings.auth,
 * скорость, обфускация и прыжки по портам — в finalmask */
function hy2stream(s) {
	let st = {
		network: 'hysteria',
		security: 'tls',
		tlsSettings: {
			serverName: s.sni || s.address,
			alpn: list(s.alpn) || [ 'h3' ],
			allowInsecure: s.insecure == '1'
		},
		hysteriaSettings: { version: 2, auth: s.password }
	};

	let udp = [], qp = { brutalUp: s.up, brutalDown: s.down };
	let interval = s.hop_interval || '5-30';

	if (s.hop_ports) {
		if (hopAsMask)
			/* udphop обязан идти первым в списке */
			push(udp, { type: 'udphop', settings: {
				mode: 'intervalLocal,intervalRemote',
				remotePorts: s.hop_ports,
				interval: interval
			} });
		else
			qp.udpHop = { ports: s.hop_ports, interval: interval };
	}
	if (s.obfs_password)
		push(udp, { type: 'salamander', settings: { password: s.obfs_password } });

	st.finalmask = { udp: udp, quicParams: qp };
	return st;
}

function outbound(s) {
	let port = +s.port;
	let o = { tag: s['.name'], protocol: s.protocol };

	switch (s.protocol) {
	case 'vless':
		o.settings = { vnext: [ { address: s.address, port: port,
			users: [ { id: s.uuid, encryption: 'none', flow: s.flow } ] } ] };
		o.streamSettings = stream(s);
		break;
	case 'vmess':
		o.settings = { vnext: [ { address: s.address, port: port,
			users: [ { id: s.uuid, security: s.method || 'auto' } ] } ] };
		o.streamSettings = stream(s);
		break;
	case 'trojan':
		o.settings = { servers: [ { address: s.address, port: port, password: s.password } ] };
		o.streamSettings = stream(s);
		break;
	case 'shadowsocks':
		o.settings = { servers: [ { address: s.address, port: port,
			method: s.method, password: s.password } ] };
		o.streamSettings = stream(s);
		break;
	case 'hysteria2':
		if (!hy2Supported) {
			skippedServers[s.alias || s.address] = true;
			return null;
		}
		o.protocol = 'hysteria';
		o.settings = { version: 2, address: s.address, port: port };
		o.streamSettings = hy2stream(s);
		break;
	default:
		return null;
	}
	return o;
}

/* --- Тестовый режим для проверки задержки --- */
if (ARGV[0] == 'test') {
	let s = c.get_all('keylink', ARGV[1]);
	let o = (s && s['.type'] == 'outbound') ? outbound(s) : null;
	if (!o) {
		warn((s && s.protocol == 'hysteria2' && !hy2Supported)
			? 'Hysteria2 requires Xray 26.3.27 or later\n'
			: 'Server not found; save the settings\n');
		exit(1);
	}
	printf('%.J\n', clean({
		log: { loglevel: 'none' },
		inbounds: [ { listen: '127.0.0.1', port: +ARGV[2], protocol: 'socks', settings: { udp: false } } ],
		outbounds: [ o ]
	}));
	exit(0);
}

/* --- Серверы --- */
let servers = [], known = { direct: true, block: true }, bySub = {}, serverDomains = {};
c.foreach('keylink', 'outbound', s => {
	let o = outbound(s);
	if (!o) return;
	push(servers, o);
	known[o.tag] = true;
	if (s.subscription)
		push(bySub[s.subscription] ??= [], o.tag);
	if (s.address && !match(s.address, /^[0-9.]+$/) && index(s.address, ':') < 0)
		serverDomains['full:' + s.address] = true;
});

/* --- Обход DPI: исходящие, на которые можно направлять правила --- */
const ZAPRET_MARK = 0x00200000;   /* должна совпадать с init.d/keylink */
let dpiOutbounds = [];
let bye = c.get_all('keylink', 'byedpi') || {};
if (bye.enabled == '1') {
	push(dpiOutbounds, { tag: 'byedpi', protocol: 'socks',
		settings: { servers: [ { address: '127.0.0.1', port: +(bye.port || 10801) } ] } });
	known.byedpi = true;
}
let zap = c.get_all('keylink', 'zapret') || {};
if (zap.enabled == '1') {
	push(dpiOutbounds, { tag: 'zapret', protocol: 'freedom',
		streamSettings: { sockopt: { mark: ZAPRET_MARK } } });
	known.zapret = true;
}
for (let o in dpiOutbounds)
	push(servers, o);

/* --- Балансировщики --- */
let balancers = [], isBalancer = {};
c.foreach('keylink', 'balancer', b => {
	let pick = {};
	for (let t in list(b.servers) || [])
		if (known[t] && t != 'direct' && t != 'block' && t != 'byedpi' && t != 'zapret') pick[t] = true;
	for (let sub in list(b.subscriptions) || [])
		for (let t in bySub[sub] || []) pick[t] = true;
	let sel = sort(keys(pick));
	if (!length(sel)) return;

	let strategy = b.strategy || 'random';
	isBalancer[b['.name']] = true;

	push(balancers, {
		tag: b['.name'],
		selector: sel,             /* теги вида cfgXXXXXX одной длины, префиксы не пересекаются */
		strategy: { type: strategy },
		fallbackTag: known[b.fallback] ? b.fallback : null
	});
});

function target(tag) {
	if (isBalancer[tag]) return { balancerTag: tag };
	if (known[tag]) return { outboundTag: tag };
	return null;
}

/* --- Порядок исходящих: первым идёт маршрут по умолчанию --- */
let main = g.main_outbound || 'direct';
let first = main;
if (isBalancer[main]) {
	/* для балансировщика маршрут по умолчанию задаётся правилом в конце */
	let b = c.get_all('keylink', main);
	first = (b && known[b.fallback]) ? b.fallback : 'direct';
}
else if (!known[main]) {
	first = main = 'direct';
}

const direct = { tag: 'direct', protocol: 'freedom' };
let outbounds = [];
if (first == 'direct') push(outbounds, direct);
for (let o in servers) if (o.tag == first) push(outbounds, o);
for (let o in servers) if (o.tag != first) push(outbounds, o);
if (first != 'direct') push(outbounds, direct);
push(outbounds, { tag: 'block', protocol: 'blackhole' });

/* --- Правила --- */
let rules = [];
const dnsOn = g.dns_enabled == '1';

if (dnsOn) {
	/* запросы от клиентов → встроенный DNS Xray */
	push(rules, { type: 'field', inboundTag: [ 'dns-in' ], outboundTag: 'dns-out' });

	/* собственные запросы DNS Xray: локальный сервер — напрямую, удалённый — по основному маршруту */
	let localIP = match(g.dns_local || '77.88.8.8', /([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/);
	if (localIP)
		push(rules, { type: 'field', inboundTag: [ 'dns-internal' ], ip: [ localIP[1] ], outboundTag: 'direct' });

	let t = target(main) || { outboundTag: 'direct' };
	push(rules, { type: 'field', inboundTag: [ 'dns-internal' ],
		outboundTag: t.outboundTag, balancerTag: t.balancerTag });
}

push(rules, { type: 'field', ip: geo([ 'geoip:private' ]), outboundTag: 'direct' });

c.foreach('keylink', 'rule', r => {
	if (r.enabled == '0') return;
	if (!r.domain && !r.ip && !r.port && !r.network && !r.protocol && !r.source) return;
	let t = target(r.outbound);
	if (!t) return;   /* правило ссылается на удалённый сервер */

	/* Условия внутри правила объединяются через «И». Если список доменов или IP
	 * опустел из-за отсутствующей базы, правило сработало бы шире задуманного —
	 * поэтому оно пропускается целиком */
	let domain = geo(list(r.domain)), ip = geo(list(r.ip));
	if ((r.domain && !length(domain)) || (r.ip && !length(ip))) return;

	push(rules, {
		type: 'field',
		domain: domain, ip: ip, port: r.port,
		network: r.network, protocol: list(r.protocol), source: list(r.source),
		outboundTag: t.outboundTag, balancerTag: t.balancerTag
	});
});

if (isBalancer[main])
	push(rules, { type: 'field', network: 'tcp,udp', balancerTag: main });

/* В конфигурацию идут только балансировщики, на которые ссылается правило или
 * основной маршрут: для остальных Xray впустую проверял бы серверы */
let used = {};
for (let r in rules)
	if (r.balancerTag) used[r.balancerTag] = true;
balancers = filter(balancers, b => used[b.tag]);

let observe = {}, burst = {};
for (let b in balancers) {
	if (b.strategy.type == 'leastPing')
		for (let t in b.selector) observe[t] = true;
	else if (b.strategy.type == 'leastLoad')
		for (let t in b.selector) burst[t] = true;
}

/* --- Входящие --- */
const sniff = { enabled: true, destOverride: [ 'http', 'tls', 'quic' ], routeOnly: true };
let inbounds = [];

if (+g.socks_port)
	push(inbounds, { tag: 'socks', listen: '0.0.0.0', port: +g.socks_port,
		protocol: 'socks', settings: { udp: true }, sniffing: sniff });

if (+g.http_port)
	push(inbounds, { tag: 'http', listen: '0.0.0.0', port: +g.http_port,
		protocol: 'http', sniffing: sniff });

if (g.tproxy == '1')
	push(inbounds, { tag: 'tproxy', listen: '0.0.0.0', port: +(g.tproxy_port || 12345),
		protocol: 'dokodemo-door',
		settings: { network: 'tcp,udp', followRedirect: true },
		streamSettings: { sockopt: { tproxy: 'tproxy' } },
		sniffing: sniff });

if (dnsOn) {
	push(inbounds, { tag: 'dns-in', listen: '127.0.0.1', port: +(g.dns_port || 5353),
		protocol: 'dokodemo-door',
		settings: { address: '1.1.1.1', port: 53, network: 'tcp,udp' } });
	push(outbounds, { tag: 'dns-out', protocol: 'dns' });
}

/* --- Итог --- */
let cfg = {
	log: { loglevel: g.loglevel || 'warning' },
	inbounds: inbounds,
	outbounds: outbounds,
	routing: {
		domainStrategy: g.domain_strategy || 'IPIfNonMatch',
		rules: rules,
		balancers: balancers
	}
};

if (dnsOn) {
        /* Домены самих серверов резолвятся локальным DNS — иначе получится петля:
	 * чтобы подключиться к серверу, нужен DNS, а DNS идёт через этот сервер */
	let localDomains = geo(list(g.dns_local_domains) || [ 'geosite:category-ru' ]);
	cfg.dns = {
		tag: 'dns-internal',
		queryStrategy: g.dns_query_strategy || 'UseIPv4',
		servers: [
			{
				address: g.dns_local || '77.88.8.8',
				domains: [ ...localDomains, ...sort(keys(serverDomains)) ],
				skipFallback: true
			},
			g.dns_remote || 'https://1.1.1.1/dns-query'
		]
	};
}

if (length(keys(observe)))
	cfg.observatory = {
		subjectSelector: keys(observe),
		probeURL: probe,
		probeInterval: g.probe_interval || '1m',
		enableConcurrency: true
	};

if (length(keys(burst)))
	cfg.burstObservatory = {
		subjectSelector: keys(burst),
		pingConfig: {
			destination: probe,
			interval: g.probe_interval || '1m',
			sampling: 3,
			timeout: '5s'
		}
	};

if (length(keys(skippedServers)))
	warn('keylink: серверы Hysteria2 пропущены — нужен Xray 26.3.27 или новее, установлен ' +
		join('.', XRAY_VER) + ': ' + join(', ', sort(keys(skippedServers))) + '\n');

if (length(keys(skipped)))
        warn('keylink: нет базы для ' + join(', ', sort(keys(skipped))) +
		' — эти условия пропущены (установите v2ray-geoip / v2ray-geosite)\n');

printf('%.J\n', clean(cfg));
