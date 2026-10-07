'use strict';

/*
 *   ucode dpi.uc bin  <byedpi|zapret>   — путь к бинарнику
 *   ucode dpi.uc args <byedpi|zapret>   — аргументы выбранного в UCI пресета
 *   ucode dpi.uc list <byedpi|zapret>   — все пресеты: id<TAB>аргументы (для тестера)
 */

import { cursor } from 'uci';
import { readfile, access } from 'fs';

const c = cursor();
c.load('keylink');
const PRESETS = json(readfile('/usr/share/keylink/dpi_presets.json') || '{}');

/* Голос Discord: фейки только для STUN и discovery-пакетов, остальной UDP не трогается */
const DISCORD = '--new --filter-udp=50000-65535 --filter-l7=discord,stun ' +
	'--payload=stun,discord_ip_discovery ' +
	'--lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2';

function first(list, mode) {
	for (let p in list)
		if (p && access(p, mode)) return p;
	return null;
}

function which(names) {
	let dirs = [ '/usr/bin', '/usr/sbin', '/bin', '/sbin', '/opt/bin' ];
	for (let n in names)
		for (let d in dirs)
			if (access(d + '/' + n, 'x')) return d + '/' + n;
	return null;
}

function section(engine) {
	return c.get_all('keylink', engine) || {};
}

function zapretPaths() {
	let z = section('zapret');
	let lua = first([ z.lua_dir, '/opt/zapret2/lua', '/usr/share/zapret2/lua', '/usr/lib/zapret2/lua' ], 'r');
	let fake = first([ z.fake_dir, lua ? replace(lua, /\/lua$/, '/files/fake') : null,
		'/opt/zapret2/files/fake', '/usr/share/zapret2/files/fake' ], 'r');
	return { lua: lua, fake: fake };
}

function binary(engine) {
	let s = section(engine);
	if (s.bin && access(s.bin, 'x')) return s.bin;
	if (engine == 'byedpi')
		return which([ 'ciadpi', 'byedpi' ]);
	return which([ 'nfqws2' ]) ||
		first([ '/opt/zapret2/nfq2/nfqws2', '/opt/zapret2/binaries/my/nfqws2' ], 'x');
}

function zapretPrefix(zp) {
	return sprintf("--lua-init=@%s/zapret-lib.lua --lua-init=@%s/zapret-antidpi.lua " +
		"--lua-init=fake_default_tls=tls_mod(fake_default_tls,'rnd,rndsni')", zp.lua, zp.lua);
}

function expand(engine, args, zp) {
	args = replace(args || '', /[\r\n\t]+/g, ' ');
	if (engine != 'zapret') return args;
	return zapretPrefix(zp) + ' ' + replace(replace(args, '${LUA}', zp.lua), '${FAKE}', zp.fake || '');
}

function preset(engine, id) {
	for (let p in PRESETS[engine] || [])
		if (p.id == id) return p;
	return (PRESETS[engine] || [])[0];
}

let engine = ARGV[1];
if (engine != 'byedpi' && engine != 'zapret') {
	warn('usage: dpi.uc bin|args|list byedpi|zapret\n');
	exit(2);
}

let zp = engine == 'zapret' ? zapretPaths() : null;
if (zp && !zp.lua) {
	warn('zapret2 Lua scripts not found (zapret-lib.lua)\n');
	exit(1);
}

switch (ARGV[0]) {
case 'bin': {
	let b = binary(engine);
	if (!b) {
                warn('Binary not found: ' + (engine == 'byedpi' ? 'ciadpi' : 'nfqws2') + '\n');
		exit(1);
	}
	print(b, '\n');
	break;
}
case 'args': {
	let s = section(engine);
	let a = s.preset == 'custom' ? s.custom_args : (preset(engine, s.preset) || {}).args;
	let out = expand(engine, a, zp);
	if (engine == 'zapret' && s.discord_voice == '1')
		out += ' ' + DISCORD;
	print(out, '\n');
	break;
}
case 'list':
	for (let p in PRESETS[engine] || [])
		print(p.id, '\t', expand(engine, p.args, zp), '\n');
	break;
default:
	exit(2);
}
