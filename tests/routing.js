'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const options = {};
const config = {};
const uci = {
        get: (conf, sid, key) => config[sid]?.[key],
        set: (conf, sid, key, value) => { config[sid][key] = value; },
        unset: (conf, sid, key) => { delete config[sid][key]; }
};
const section = {
        option: (type, name) => {
                options[name] = { type, value() {} };
                return options[name];
        }
};
const form = {
        TextValue: 'textarea',
        DynamicList: 'list',
        Map: function() {
                this.section = () => section;
                this.render = () => options;
        }
};
const source = fs.readFileSync(path.join(__dirname,
        '../htdocs/luci-static/resources/view/keylink/routing.js'), 'utf8');
const view = new Function('view', 'form', 'uci', 'common', '_', source)(
        { extend: value => value }, form, uci, { fillOutbounds() {} }, value => value
);
view.render();

const domain = options.domain;
assert.equal(domain.type, form.TextValue);
assert.equal(options.ip.type, form.DynamicList);
assert.equal(options.source.type, form.DynamicList);

config.rule = { domain: ['geosite:category-ru', 'domain:example.com'] };
assert.equal(domain.cfgvalue('rule'), 'geosite:category-ru\ndomain:example.com');
domain.write('rule', domain.cfgvalue('rule'));
assert.deepEqual(config.rule.domain, ['geosite:category-ru', 'domain:example.com']);

config.rule.domain = 'full:example.com';
assert.equal(domain.cfgvalue('rule'), 'full:example.com');
assert.equal(domain.cfgvalue('new_rule'), '');

domain.write('rule', '  domain:example.com \r\n\n full:other.example\t\rkeyword:google\n');
assert.deepEqual(config.rule.domain, ['domain:example.com', 'full:other.example', 'keyword:google']);

const regexp = 'regexp:^a{1,3}\\.example\\.com$';
domain.write('rule', regexp);
assert.deepEqual(config.rule.domain, [regexp]);

for (const value of ['', ' \r\n\t\n']) {
        domain.write('rule', value);
        assert.equal(config.rule.domain, undefined);
        assert.equal(domain.cfgvalue('rule'), '');
}

console.log('OK: domain textarea preserves UCI lists and handles multiline input');
