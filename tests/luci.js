'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
let text = '', service = {}, readFails = false;
const monitor = new Function('baseclass', 'fs', 'rpc', 'L', '_', 'E',
    fs.readFileSync(path.join(root, 'luci/monitor.js'), 'utf8'))(
    { extend: value => value },
    { read: () => readFails ? Promise.reject(new Error('No status yet')) : Promise.resolve(text) },
    { declare: () => () => Promise.resolve(service) },
    { resolveDefault: (promise, fallback) => promise.catch(() => fallback), bind: (fn, owner) => fn.bind(owner) },
    value => value,
    (tag, attrs, children) => ({ tag, attrs, children })
);

async function main() {
    const options = {};
    const section = { option: (kind, name) => (options[name] = {}) };
    function Map() { this.section = () => section; this.render = () => Promise.resolve({}); }
    const settings = new Function('view', 'form', 'uci', 'monitor', '_', 'E', 'poll', 'ui', 'L',
        fs.readFileSync(path.join(root, 'luci/view.js'), 'utf8'))(
        { extend: value => value }, { Map }, {},
        { renderStatus: () => [] }, value => value, () => ({}), { add: () => {} },
        { createHandlerFn: () => () => {} }, { url: value => value }
    );
    await settings.render([null, {}]);
    const urlOption = options.check_url;
    let urls = ['https://www.google.com/generate_204', 'https://cp.cloudflare.com/generate_204'];
    urlOption.formvalue = () => urls;
    assert.equal(urlOption.validate('main', ''), true);
    assert.equal(urlOption.validate('main', urls[0]), true);
    assert.notEqual(urlOption.validate('main', 'http://example.com'), true);
    assert.notEqual(urlOption.validate('main', 'https://user:password@example.com'), true);
    urls = ['https://one.example', 'https://two.example', 'https://three.example'];
    assert.notEqual(urlOption.validate('main', 'https://four.example'), true);
    urls = [];
    assert.notEqual(urlOption.validate('main', ''), true);

    text = 'state=healthy\nsample=healthy\nlatency_ms=700\nreason=endpoint_1\nupdated_at=2026-10-23T00:00:00Z\n';
    service = { 'googlewifi-led': { instances: { instance1: { running: true } } } };
    let status = await monitor.loadStatus();
    assert.equal(status.state, 'healthy');
    assert.equal(status.running, true);
    assert.match(JSON.stringify(monitor.renderStatus(status)), /700 ms/);

    // A stale green status file must not report a stopped daemon as healthy.
    service['googlewifi-led'].instances.instance1.running = false;
    status = await monitor.loadStatus();
    assert.equal(status.state, 'stopped');
    assert.equal(status.sample, 'healthy');

    // Keep the displayed LED state and latest failed probe distinct.
    status = monitor.parseStatus('state=healthy\nsample=unreachable\nlatency_ms=0\nreason=connection_failed\n',
        { 'googlewifi-led': { instances: { instance1: { running: true } } } });
    assert.equal(status.state, 'healthy');
    assert.equal(status.sample, 'unreachable');
    assert.doesNotMatch(JSON.stringify(monitor.renderStatus(status)), /0 ms/);
    assert.match(JSON.stringify(monitor.renderStatus(status)), /Could not connect/);

    readFails = true;
    service = { 'googlewifi-led': { instances: { instance1: { running: true } } } };
    assert.equal((await monitor.loadStatus()).state, 'unavailable');
    const acl = JSON.parse(fs.readFileSync(path.join(root, 'luci/acl.json'), 'utf8'))['luci-app-googlewifi-led'];
    assert.deepEqual(acl.read.file['/var/run/googlewifi-led/status'], ['read']);
    assert.deepEqual(acl.read.file['/tmp/run/googlewifi-led/status'], ['read']);
    for (const file of ['luci/menu.json', 'luci/acl.json']) JSON.parse(fs.readFileSync(path.join(root, file), 'utf8'));
    for (const file of ['luci/view.js', 'luci/trigger.js']) new Function(fs.readFileSync(path.join(root, file), 'utf8'));
    console.log('PASS: LuCI status, stale-state handling, rendering, JavaScript, and JSON');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
