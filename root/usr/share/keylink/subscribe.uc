'use strict';

/*
 * Подписки keylink.
 *   ucode subscribe.uc update <sid>  — обновить одну подписку
 *   ucode subscribe.uc all           — обновить все включённые
 *   ucode subscribe.uc cron          — обновить те, у которых подошёл срок
 * Печатает JSON с итогом. Код выхода 10 — список серверов изменился (нужен reload).
 */

import { cursor } from 'uci';
import { popen, readfile, unlink } from 'fs';

const c = cursor();
c.load('keylink');
const g = c.get_all('keylink', 'main') || {};

/* Поля сервера, которыми управляет подписка */
const FIELDS = [
	'protocol', 'alias', 'address', 'port', 'uuid', 'password', 'method', 'flow',
	'network', 'security', 'sni', 'fp', 'alpn', 'public_key', 'short_id', 'spider_x',
	'path', 'host', 'service_name', 'mode', 'insecure',
	'obfs_password', 'hop_ports', 'up', 'down', 'link'
];

function nz(v) { return v == null ? '' : v; }

function urldec(s) {
	if (s == null) return null;
	return replace(s, /%([0-9A-Fa-f]{2})/g, (m, h) => chr(hex(h)));
}

function b64(s) {
	s = replace(s, /[ \t\r\n]/g, '');
	s = replace(replace(s, /-/g, '+'), /_/g, '/');
	while (length(s) % 4)
		s += '=';
	return b64dec(s);
}

function query(qs) {
	let q = {};
	for (let kv in split(qs || '', '&')) {
		if (!length(kv)) continue;
		let i = index(kv, '=');
		if (i < 0) q[urldec(kv)] = '';
		else q[urldec(substr(kv, 0, i))] = urldec(substr(kv, i + 1));
	}
	return q;
}

function hostport(hp) {
	let m = match(hp, /^\[([^\]]+)\](:([0-9,-]+))?$/);
	if (!m) m = match(hp, /^([^:]+)(:([0-9,-]+))?$/);
	return m ? { host: m[1], port: m[3] } : null;
}

/* scheme://auth?query#frag */
function splitLink(link) {
	let m = match(link, /^([a-zA-Z0-9]+):\/\/([^?#]*)(\?([^#]*))?(#(.*))?$/);
        if (!m) die('Invalid link');
	return { scheme: lc(m[1]), auth: m[2], q: query(m[4]), frag: urldec(m[6]) };
}

function authority(l) {
	let at = rindex(l.auth, '@');
	let cred = at >= 0 ? urldec(substr(l.auth, 0, at)) : '';
	let rest = at >= 0 ? substr(l.auth, at + 1) : l.auth;
	let hp = hostport(replace(rest, /\/.*$/, ''));
        if (!hp) die('Server address is missing');
	return { cred: cred, host: hp.host, port: hp.port };
}

function parseStd(l, proto) {
	let a = authority(l), q = l.q;
	let o = {
		protocol: proto, alias: l.frag, address: a.host, port: a.port || '443',
		network: q.type || 'tcp',
		security: q.security || (proto == 'trojan' ? 'tls' : 'none'),
		sni: q.sni || q.peer, fp: q.fp, alpn: q.alpn,
		public_key: q.pbk, short_id: q.sid, spider_x: q.spx,
		flow: q.flow, path: q.path, host: q.host,
		service_name: q.serviceName, mode: q.mode,
		insecure: (q.allowInsecure == '1' || q.insecure == '1') ? '1' : null
	};
	if (proto == 'vless') o.uuid = a.cred;
	else o.password = a.cred;
	return o;
}

function parseHy2(l) {
	let a = authority(l), q = l.q;
	let port = a.port || '443', hop = q.mport;
	if (match(port, /[,-]/)) {
		hop = port;
		port = split(port, /[,-]/)[0];
	}
	return {
		protocol: 'hysteria2', alias: l.frag, address: a.host, port: port,
		password: a.cred, sni: q.sni || q.peer, alpn: q.alpn,
		insecure: q.insecure == '1' ? '1' : null,
		obfs_password: q.obfs == 'salamander' ? q['obfs-password'] : null,
		hop_ports: hop,
		up: q.upmbps ? q.upmbps + 'mbps' : null,
		down: q.downmbps ? q.downmbps + 'mbps' : null
	};
}

function parseVmess(link) {
	let raw = b64(substr(link, 8));
        if (!raw) die('vmess: invalid base64');
	let j = json(raw);
	return {
		protocol: 'vmess', alias: j.ps, address: j.add, port: '' + nz(j.port),
		uuid: j.id, method: j.scy || 'auto', network: j.net || 'tcp',
		security: j.tls == 'tls' ? 'tls' : 'none',
		sni: j.sni, fp: j.fp, alpn: j.alpn, host: j.host,
		path: j.net == 'grpc' ? null : j.path,
		service_name: j.net == 'grpc' ? j.path : null
	};
}

function parseSS(link) {
	let rest = substr(link, 5), alias = null;
	let i = index(rest, '#');
	if (i >= 0) {
		alias = urldec(substr(rest, i + 1));
		rest = substr(rest, 0, i);
	}
	rest = replace(split(rest, '?')[0], /\/$/, '');

	let at = rindex(rest, '@'), userinfo, hp;
	if (at < 0) {
		let d = b64(rest) || '';
		at = rindex(d, '@');
		userinfo = substr(d, 0, at);
		hp = substr(d, at + 1);
	}
	else {
		userinfo = urldec(substr(rest, 0, at));
		hp = substr(rest, at + 1);
		if (index(userinfo, ':') < 0)
			userinfo = b64(userinfo) || '';
	}

	let ci = index(userinfo, ':'), h = hostport(hp);
	if (ci < 0 || !h || !h.port) die('Could not parse the ss link');

	return {
		protocol: 'shadowsocks', alias: alias, address: h.host, port: h.port,
		method: substr(userinfo, 0, ci), password: substr(userinfo, ci + 1),
		network: 'tcp', security: 'none'
	};
}

function parse(link) {
	let scheme = lc(split(link, '://')[0]), o;
	switch (scheme) {
	case 'vless':  o = parseStd(splitLink(link), 'vless'); break;
	case 'trojan': o = parseStd(splitLink(link), 'trojan'); break;
	case 'hy2':
	case 'hysteria2': o = parseHy2(splitLink(link)); break;
	case 'vmess':  o = parseVmess(link); break;
	case 'ss':     o = parseSS(link); break;
        default: die('Unsupported scheme: ' + scheme);
	}

	let r = {};
	for (let k, v in o)
		if (v != null && v !== '')
			r[k] = '' + v;
	if (!r.address || !r.port || !(r.uuid || r.password))
                die('The link is missing an address, port, or key');
	r.alias ??= r.address;
	r.link = link;
	return r;
}

/* Сервер узнаётся по протоколу, адресу, порту и названию — так теги
 * (а значит, правила и балансировщики) переживают обновление подписки */
function key(o) {
	return join('|', [ o.protocol, o.address, o.port, o.alias ]);
}

function shq(s) {
	return "'" + replace(s, "'", "'\\''") + "'";
}

function fetch(s) {
	let hdr = '/tmp/keylink-sub.' + s['.name'] + '.hdr';
	let cmd = sprintf('curl -fsSL --max-time 25 -A %s -D %s',
		shq(s.user_agent || 'v2rayN/7.0'), shq(hdr));

	if (s.via_proxy == '1') {
		if (!(+g.socks_port))
			die('Enable the SOCKS5 port on the General tab to download through the proxy');
		cmd += sprintf(' -x socks5h://127.0.0.1:%d', +g.socks_port);
	}
	cmd += ' ' + shq(s.url) + ' 2>/dev/null';

	let p = popen(cmd, 'r');
	let body = p ? p.read('all') : null;
	let rc = p ? p.close() : -1;
	let headers = readfile(hdr) || '';
	unlink(hdr);

	if (rc != 0 || !length(body))
		die(sprintf('Could not download the subscription (curl: %d)', rc));
	return { body: body, headers: headers };
}

function decodeBody(body) {
	body = trim(body);
	if (!match(body, /:\/\//)) {
		let d = b64(body);
		if (d) body = d;
	}
	return filter(map(split(body, /\r?\n/), l => trim(l)),
		l => length(l) && match(l, /^[a-zA-Z0-9]+:\/\//));
}

/* subscription-userinfo: upload=…; download=…; total=…; expire=… */
function userinfo(h) {
	let m = match(h, /subscription-userinfo:[ \t]*([^\r\n]*)/i);
	if (!m) return null;
	let r = {};
	for (let part in split(m[1], ';')) {
		let kv = match(trim(part), /^([a-z]+)=([0-9]+)/);
		if (kv) r[kv[1]] = +kv[2];
	}
	return r;
}

function update(sid) {
	let s = c.get_all('keylink', sid);
	if (!s || s['.type'] != 'subscription')
		die('Subscription not found; save the settings');
	if (!s.url)
		die('Subscription URL is missing');

	let res = fetch(s);
	let inc = s.include ? regexp(s.include, 'i') : null;
	let exc = s.exclude ? regexp(s.exclude, 'i') : null;
	let parsed = [], skipped = 0, seen = {};

	for (let l in decodeBody(res.body)) {
		let o;
		try { o = parse(l); }
		catch (e) { skipped++; continue; }
		if (inc && !match(o.alias, inc)) continue;
		if (exc && match(o.alias, exc)) continue;
		let k = key(o);
		if (seen[k]) continue;
		seen[k] = true;
		push(parsed, o);
	}

	if (!length(parsed))
		die('No supported servers in the response; try a different User-Agent');

	let existing = {}, stale = [];
	c.foreach('keylink', 'outbound', o => {
		if (o.subscription != sid) return;
		let k = key(o);
		if (existing[k]) push(stale, o['.name']);
		else existing[k] = o;
	});

	let added = 0, updated = 0;
	for (let o in parsed) {
		let k = key(o), cur = existing[k];
		if (cur) {
			let diff = false;
			for (let f in FIELDS) {
				if (nz(cur[f]) === nz(o[f])) continue;
				diff = true;
				if (o[f] == null) c.delete('keylink', cur['.name'], f);
				else c.set('keylink', cur['.name'], f, o[f]);
			}
			if (diff) updated++;
			delete existing[k];
		}
		else {
			let name = c.add('keylink', 'outbound');
			c.set('keylink', name, 'subscription', sid);
			for (let f in FIELDS)
				if (o[f] != null)
					c.set('keylink', name, f, o[f]);
			added++;
		}
	}

	for (let k, o in existing)
		push(stale, o['.name']);
	for (let n in stale)
		c.delete('keylink', n);

	let info = userinfo(res.headers);
	c.set('keylink', sid, 'updated', '' + time());
	c.set('keylink', sid, 'count', '' + length(parsed));
	if (info) {
		c.set('keylink', sid, 'info_used', '' + ((info.upload || 0) + (info.download || 0)));
		c.set('keylink', sid, 'info_total', '' + (info.total || 0));
		c.set('keylink', sid, 'info_expire', '' + (info.expire || 0));
	}
	c.commit('keylink');

	return {
		sid: sid, total: length(parsed), added: added, updated: updated,
		removed: length(stale), skipped: skipped,
		changed: !!(added || updated || length(stale))
	};
}

/* --- точка входа --- */
let mode = ARGV[0], results = [], changed = false, failed = false;

function run(sid) {
	try {
		let r = update(sid);
		changed ||= r.changed;
		push(results, r);
	}
	catch (e) {
		failed = true;
		push(results, { sid: sid, error: e.message });
	}
}

if (mode == 'update') {
	run(ARGV[1]);
	printf('%J\n', results[0]);
}
else if (mode == 'all' || mode == 'cron') {
	let now = time();
	c.foreach('keylink', 'subscription', s => {
		if (s.enabled == '0') return;
		if (mode == 'cron') {
			let h = +(s.update_interval || 0);
			if (h <= 0 || now - +(s.updated || 0) < h * 3600 - 300) return;
		}
		run(s['.name']);
	});
	printf('%J\n', results);
}
else {
	warn('usage: subscribe.uc update <sid> | all | cron\n');
	exit(2);
}

exit(changed ? 10 : (failed ? 1 : 0));
