// Runs the production inline script, with DOM/network boundaries stubbed; no tenant required.
// Run: node --test backend/tests/admin_auth0.test.cjs
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const vm = require('node:vm');
const { webcrypto, createHash } = require('node:crypto');
const assert = require('node:assert/strict');
const test = require('node:test');

const html = readFileSync(resolve(__dirname, '../public/admin.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const config = { enabled: true, domain: 'tenant.example', admin_client_id: 'admin-client' };
const origin = 'https://inview.example';
const transactionKey = 'inview-admin-auth0';

async function until(predicate) {
    for (let i = 0; i < 1000; i++) {
        if (predicate()) return;
        await new Promise(resolve => setTimeout(resolve, 2));
    }
    assert.fail('Script did not reach the expected state');
}

function page({ search = '', storage = new Map(), role = 'admin', logoutFails = false } = {}) {
    const elements = new Map(), calls = [], redirects = [], history = [];
    let focused = null;
    function element(tag = '') {
        const listeners = new Map();
        return {
            hidden: /\bhidden(?:\s|>)/.test(tag), disabled: /\bdisabled(?:\s|>)/.test(tag),
            checked: false, style: {}, value: '', textContent: '', children: [],
            addEventListener(type, callback) { listeners.set(type, callback); },
            setAttribute() {}, querySelector() { return element(); },
            append(child) { this.children.push(child); }, replaceChildren() { this.children = []; },
            focus() { if (!this.disabled && !this.hidden) focused = this; },
            async fire(type) {
                assert.equal(this.hidden, false, 'Cannot interact with a hidden element');
                assert.equal(this.disabled, false, 'Cannot interact with a disabled element');
                assert(listeners.has(type), `No ${type} listener`);
                await listeners.get(type)({ preventDefault() {} });
            }
        };
    }
    for (const match of html.matchAll(/<[^>]*\bid="([^"]+)"[^>]*>/g)) {
        elements.set(match[1], element(match[0]));
    }
    const get = id => { assert(elements.has(id), `Missing DOM element: ${id}`); return elements.get(id); };
    const sessionStorage = {
        getItem: key => storage.get(key) ?? null,
        setItem: (key, value) => storage.set(key, value),
        removeItem: key => storage.delete(key)
    };
    const context = {
        URL, URLSearchParams, TextEncoder, Uint8Array, crypto: webcrypto,
        btoa: value => Buffer.from(value, 'binary').toString('base64'),
        document: { getElementById: get, createElement: () => element(), createTextNode: text => text },
        location: { protocol: 'https:', hostname: 'inview.example', origin, pathname: '/admin', search,
            assign: url => redirects.push(new URL(url)) },
        history: { replaceState: (...args) => history.push(args) }, sessionStorage,
        ResizeObserver: class { observe() {} },
        fetch: async (url, options = {}) => {
            calls.push({ url, options });
            if (url === '/api/accounts/logout' && logoutFails) throw new Error('Offline');
            let data;
            if (url === '/api/auth/config') data = config;
            else if (url === `https://${config.domain}/oauth/token`) data = { id_token: 'id-token' };
            else if (url === '/api/accounts/auth0') data = { token: `${role}-session`, account: { role } };
            else if (url === '/api/accounts/login') data = { token: 'password-admin-session', account: { role: 'admin' } };
            else if (url === '/api/accounts/logout') return { ok: true, status: 204 };
            else if (url === '/api/admin/submissions') data = [];
            else assert.fail(`Unexpected request: ${url}`);
            return { ok: true, status: 200, json: async () => data };
        }
    };
    vm.runInNewContext(script, context, { filename: 'admin.html' });
    return { get, calls, redirects, history, storage, focused: () => focused };
}

async function startLogin(storage = new Map()) {
    const login = page({ storage });
    await until(() => !login.get('auth0-signin').hidden);
    await login.get('auth0-signin').fire('click');
    const url = login.redirects.at(-1);
    assert.equal(url.origin, 'https://tenant.example');
    assert.equal(url.pathname, '/authorize');
    assert.equal(url.searchParams.get('client_id'), config.admin_client_id);
    assert.equal(url.searchParams.get('redirect_uri'), origin + '/admin');
    const saved = JSON.parse(storage.get(transactionKey));
    assert.equal(url.searchParams.get('state'), saved.state);
    assert.equal(url.searchParams.get('code_challenge_method'), 'S256');
    assert.equal(url.searchParams.get('code_challenge'), createHash('sha256').update(saved.verifier).digest('base64url'));
    return saved;
}

async function callback(role, { logoutFails = false } = {}) {
    const storage = new Map();
    const saved = await startLogin(storage);
    const result = page({ role, storage, logoutFails,
        search: '?' + new URLSearchParams({ code: 'authorization-code', state: saved.state }) });
    await until(() => result.get('message').textContent.includes(role === 'admin' ? 'Choose a submission' : 'does not have administrator access'));
    assert.equal(storage.has(transactionKey), false);
    assert.equal(result.history.at(-1)[2], '/admin');
    const grant = result.calls.find(call => call.url.endsWith('/oauth/token'));
    assert.equal(grant.options.body.get('code_verifier'), saved.verifier);
    assert.equal(grant.options.body.get('redirect_uri'), origin + '/admin');
    const exchange = result.calls.find(call => call.url === '/api/accounts/auth0');
    assert.deepEqual(JSON.parse(exchange.options.body), { id_token: 'id-token' });
    return result;
}

function assertTenantLogout(url) {
    assert.equal(url.origin, 'https://tenant.example');
    assert.equal(url.pathname, '/v2/logout');
    assert.equal(url.searchParams.get('client_id'), config.admin_client_id);
    assert.equal(url.searchParams.get('returnTo'), origin + '/admin');
}

test('admin Auth0 denial exposes focused recovery, logs out tenant, and permits a new login', async () => {
    const denied = await callback('user');
    assert.equal(denied.get('workspace').hidden, true);
    assert.equal(denied.get('signin').hidden, false);
    assert.equal(denied.get('signout').hidden, true);
    assert.equal(denied.get('password-login').hidden, false);
    assert.equal(denied.get('auth0-switch').hidden, false);
    assert.equal(denied.focused(), denied.get('auth0-switch'));
    assert.equal(denied.calls.find(call => call.url === '/api/accounts/logout').options.headers.Authorization, 'Bearer user-session');
    assert.equal(denied.calls.some(call => call.url === '/api/admin/submissions'), false);
    assert.equal(denied.redirects.length, 0, 'Recovery must be an explicit choice');
    await denied.get('auth0-switch').fire('click');
    assertTenantLogout(denied.redirects.at(-1));
    assert.equal(denied.storage.has(transactionKey), false);
    // Simulate the tenant returning after logout; no token or transaction survives the navigation.
    const saved = await startLogin(denied.storage);
    const accepted = page({ storage: denied.storage,
        search: '?' + new URLSearchParams({ code: 'new-code', state: saved.state }) });
    await until(() => accepted.get('message').textContent.includes('Choose a submission'));
    assert.equal(accepted.get('workspace').hidden, false);
    assert.equal(accepted.get('auth0-switch').hidden, true);
    assert.equal(accepted.calls.find(call => call.url === '/api/admin/submissions').options.headers.Authorization, 'Bearer admin-session');
});

test('normal admin logout revokes the opaque session and navigates to tenant logout', async () => {
    const admin = await callback('admin');
    await admin.get('signout').fire('click');
    assert.equal(admin.calls.find(call => call.url === '/api/accounts/logout').options.headers.Authorization, 'Bearer admin-session');
    assert.equal(admin.get('signin').hidden, false);
    assert.equal(admin.get('workspace').hidden, true);
    assertTenantLogout(admin.redirects.at(-1));
    // A subsequent request must not carry the logged-out session.
    await admin.get('login').fire('submit');
    await until(() => admin.calls.some(call => call.url === '/api/accounts/login'));
    assert.equal(admin.calls.find(call => call.url === '/api/accounts/login').options.headers.Authorization, undefined);
});

test('state mismatch consumes the transaction and never exchanges a code or creates a session', async () => {
    const storage = new Map();
    await startLogin(storage);
    const invalid = page({ storage, search: '?code=attacker-code&state=wrong-state' });
    await until(() => invalid.get('message').textContent.includes('could not be verified'));
    assert.equal(storage.has(transactionKey), false);
    assert.equal(invalid.history.at(-1)[2], '/admin');
    assert.deepEqual(invalid.calls.map(call => call.url), ['/api/auth/config']);
    assert.equal(invalid.get('workspace').hidden, true);
    assert.equal(invalid.get('auth0-switch').hidden, true);
});

test('password fallback after Auth0 rejection does not send or retain the rejected opaque token', async () => {
    const denied = await callback('user');
    denied.get('email').value = 'admin@example.test';
    denied.get('password').value = 'test-password';
    await denied.get('login').fire('submit');
    await until(() => denied.get('message').textContent.includes('Choose a submission'));
    const login = denied.calls.find(call => call.url === '/api/accounts/login');
    assert.equal(login.options.headers.Authorization, undefined);
    assert.deepEqual(JSON.parse(login.options.body), { email: 'admin@example.test', password: 'test-password' });
    assert.equal(denied.get('password').value, '');
    assert.equal(denied.get('auth0-switch').hidden, true);
    assert.equal(denied.calls.find(call => call.url === '/api/admin/submissions').options.headers.Authorization, 'Bearer password-admin-session');
    assert.equal([...denied.storage.values()].some(value => value.includes('user-session')), false);
});

test('revocation network failure still discards rejected token and offers tenant recovery', async () => {
    const denied = await callback('user', { logoutFails: true });
    assert.match(denied.get('message').textContent, /could not be revoked/);
    assert.equal(denied.get('workspace').hidden, true);
    await denied.get('auth0-switch').fire('click');
    assertTenantLogout(denied.redirects.at(-1));
    await denied.get('login').fire('submit');
    await until(() => denied.calls.some(call => call.url === '/api/accounts/login'));
    assert.equal(denied.calls.find(call => call.url === '/api/accounts/login').options.headers.Authorization, undefined);
});
