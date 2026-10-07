'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.join(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const po = read('po/ru/keylink.po');
const catalog = new Map();
const placeholders = text => text.match(/%(?:\.\d+)?[sdif]/g) || [];

// Entries are deliberately single-line; the PO header uses continuation lines.
for (const m of po.matchAll(/^msgid (".+")\nmsgstr (".*")$/gm)) {
        const key = JSON.parse(m[1]), value = JSON.parse(m[2]);
        assert(!catalog.has(key), `Duplicate translation: ${key}`);
        assert(value, `Empty translation: ${key}`);
        assert(!/[А-Яа-яЁё]/.test(key), `Non-English source: ${key}`);
        assert.deepEqual(placeholders(value), placeholders(key), `Format mismatch: ${key}`);
        catalog.set(key, value);
}
assert.equal(catalog.size, (po.match(/^msgid /gm) || []).length - 1);

const files = ['htdocs/luci-static/resources/keylink/common.js',
        ...fs.readdirSync(path.join(root, 'htdocs/luci-static/resources/view/keylink'))
                .filter(file => file.endsWith('.js'))
                .map(file => 'htdocs/luci-static/resources/view/keylink/' + file)];
const requireTranslation = key => {
        assert(catalog.has(key), `Missing translation: ${key}`);
};
for (const file of files) {
        const source = read(file);
        assert(!/[А-Яа-яЁё]/.test(source.replace(/\/\*[\s\S]*?\*\//g, '')),
                `Russian text outside comments: ${file}`);
        for (const m of source.matchAll(/\b_\(\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')\s*\)/g))
                requireTranslation(vm.runInNewContext(m[1]));
}
const presets = JSON.parse(read('root/usr/share/keylink/dpi_presets.json'));
for (const list of Object.values(presets))
        for (const preset of list) requireTranslation(preset.name);
const menu = JSON.parse(read('root/usr/share/luci/menu.d/luci-app-keylink.json'));
for (const item of Object.values(menu)) requireTranslation(item.title);
for (const m of read('root/etc/config/keylink').matchAll(/option name '([^']+)'/g))
        requireTranslation(m[1]);

// Check backend messages passed to the UI, including errors from latency tests.
for (const file of ['root/usr/libexec/rpcd/keylink', 'root/usr/libexec/keylink/ping.sh',
        'root/usr/libexec/keylink/dpi-test.sh', 'root/usr/libexec/keylink/update.sh']) {
        const source = read(file);
        for (const m of source.matchAll(/"error": "([^"$]+)"|\bfail "([^"$]+)"|json_add_string error "([^"$]+)"/g)) {
                const message = m[1] || m[2] || m[3];
                if (message !== '%s') requireTranslation(message);
        }
}
for (const m of read('root/usr/share/keylink/subscribe.uc').matchAll(/\bdie\('([^']+)'\)/g))
        requireTranslation(m[1]);

// SuperFastHash, used by LuCI to look up UTF-8 keys in LMO catalogs.
function hash(text) {
        const data = Buffer.from(text);
        let h = data.length, offset = 0;
        for (; offset + 4 <= data.length; offset += 4) {
                h = (h + data.readUInt16LE(offset)) >>> 0;
                const tmp = (data.readUInt16LE(offset + 2) << 11) ^ h;
                h = ((h << 16) ^ tmp) >>> 0;
                h = (h + (h >>> 11)) >>> 0;
        }
        switch (data.length - offset) {
        case 3:
                h = (h + data.readUInt16LE(offset)) >>> 0;
                h ^= h << 16;
                h ^= data.readInt8(offset + 2) << 18;
                h = (h + (h >>> 11)) >>> 0;
                break;
        case 2:
                h = (h + data.readUInt16LE(offset)) >>> 0;
                h ^= h << 11;
                h = (h + (h >>> 17)) >>> 0;
                break;
        case 1:
                h = (h + data.readInt8(offset)) >>> 0;
                h ^= h << 10;
                h = (h + (h >>> 1)) >>> 0;
        }
        h ^= h << 3;
        h = (h + (h >>> 5)) >>> 0;
        h ^= h << 4;
        h = (h + (h >>> 17)) >>> 0;
        h ^= h << 25;
        return (h + (h >>> 6)) >>> 0;
}

const lmo = fs.readFileSync(path.join(root, 'i18n/keylink.ru.lmo'));
const index = lmo.readUInt32BE(lmo.length - 4);
assert(index < lmo.length - 4);
assert.equal((lmo.length - index - 4) % 16, 0);
const compiled = new Map();
for (let i = index; i < lmo.length - 4; i += 16) {
        const key = lmo.readUInt32BE(i);
        const offset = lmo.readUInt32BE(i + 8), length = lmo.readUInt32BE(i + 12);
        assert(offset + length <= index);
        assert(!compiled.has(key), `LMO hash collision: ${key}`);
        compiled.set(key, lmo.subarray(offset, offset + length).toString());
}
for (const [key, value] of catalog)
        assert.equal(compiled.get(hash(key)) || key, value, `Compiled translation mismatch: ${key}`);

async function testLanguage(language) {
        const translate = key => language === 'ru' ? (compiled.get(hash(key)) || key) : key;
        const labels = [], options = [];
        const config = {
                main: {}, rule: { name: 'Russian sites directly' },
                subscription: { name: 'My subscription', updated: '1', info_used: '1024', info_total: '2048' },
                outbound: { alias: 'My server', address: 'example.com', protocol: 'vless' }
        };
        const uci = {
                load: () => Promise.resolve(),
                get: (conf, sid, key) => key ? config[sid]?.[key] : config[sid],
                sections: (conf, type) => config[type] ? [{ '.name': type, ...config[type] }] : []
        };
        const section = {
                option(type, name, title, description) {
                        labels.push(title, description);
                        const option = {
                                section: this, name, value: (v, label) => labels.push(label),
                                depends() {}, cfgvalue: sid => uci.get('keylink', sid, name)
                        };
                        options.push(option);
                        return option;
                },
                tab: (name, title) => labels.push(title),
                taboption(tab, ...args) { return this.option(...args); }
        };
        function Map(conf, title, description) {
                labels.push(title, description);
                this.section = (type, name, kind, title, description) => {
                        labels.push(title, description);
                        return section;
                };
                this.render = () => Promise.resolve({});
        }
        function E(tag, attrs, children) {
                if (typeof attrs === 'string') labels.push(attrs);
                if (typeof children === 'string') labels.push(children);
                return { appendChild() {}, replaceChildren() {} };
        }
        const sandbox = vm.createContext({
                _: translate, E, uci, form: { Map, GridSection: function() {} },
                view: { extend: v => v }, baseclass: { extend: v => v },
                rpc: { declare: () => () => Promise.resolve({}) },
                fs: {}, ui: { createHandlerFn() {}, addNotification() {} },
                L: { bind: (fn, self) => fn.bind(self), toArray: v => v == null ? [] : [].concat(v) },
                window: { setTimeout() {}, clearTimeout() {} },
                document: { getElementById: () => E('div') }
        });
        vm.runInContext(String.raw`String.prototype.format = function(...args) {
                let i = 0;
                return this.replace(/%(?:\.\d+)?[sdif]/g, () => String(args[i++]));
        };`, sandbox);
        const load = file => vm.runInContext('(function() {\n' + read(file) + '\n})()', sandbox);
        sandbox.common = load(files[0]);
        assert.equal(sandbox.common.formatError('No response'), translate('No response'));
        assert.equal(sandbox.common.formatError('Binary not found: nfqws2'),
                translate('Binary not found: %s').replace('%s', 'nfqws2'));
        assert.equal(sandbox.common.formatError('Could not download the subscription (curl: 7)'),
                translate('Could not download the subscription (curl: %d)').replace('%d', '7'));
        assert.equal(sandbox.common.formatError('external engine detail'), 'external engine detail');

        for (const file of files.slice(1)) {
                labels.length = options.length = 0;
                const view = load(file);
                await view.render([{}, presets, {}]);
                const name = path.basename(file, '.js');
                const title = menu['admin/services/keylink/' + name].title;
                assert(labels.includes(translate(name === 'general' ? 'General Settings' : title)),
                        `${language}: missing title for ${name}`);
                if (language === 'en')
                        assert(!labels.some(label => typeof label === 'string' && /[А-Яа-яЁё]/.test(label)));
                if (name === 'dpi') {
                        assert.equal(view.presetName('byedpi', 'disorder1'), translate(presets.byedpi[0].name));
                        assert.equal(view.presetName('byedpi', 'user_preset'), 'user_preset');
                        view.renderStatus({ error: 'Binary not found: nfqws2' });
                        assert(labels.some(label => typeof label === 'string' &&
                                label.includes(sandbox.common.formatError('Binary not found: nfqws2'))));
                }
                if (name === 'routing') {
                        const option = options.find(o => o.name === 'name');
                        assert.equal(option.textvalue('rule'), translate('Russian sites directly'));
                        assert.equal(config.rule.name, 'Russian sites directly');
                }
        }
}

Promise.resolve().then(() => testLanguage('en')).then(() => testLanguage('ru')).then(() => {
        console.log(`OK: ${catalog.size} translations, LMO lookups, menus, presets, errors, and all seven views in English and Russian`);
}).catch(error => { console.error(error); process.exitCode = 1; });
