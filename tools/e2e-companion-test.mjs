// Real upstream proxy + DeviceRegistry + E2ERegistry. Only the harness replies
// are fixtures. Run with OMB_REFERENCE_DIR pointing at the pinned upstream tree.
import { createServer } from 'node:http';
import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';

if (!process.env.OMB_REFERENCE_DIR) throw new Error('Set OMB_REFERENCE_DIR to the official OpenMausBot checkout');
process.env.OMB_COMPANION_DIR = mkdtempSync(join(tmpdir(), 'mausbot-e2e-devices-'));
const source = name => import(pathToFileURL(join(process.env.OMB_REFERENCE_DIR, 'companion/src', name)).href);
const { DeviceRegistry } = await source('devices.ts');
const { E2ERegistry } = await source('e2e/registry.ts');
const { createE2EOrigin } = await source('e2e/origin.ts');
const { createProxyHandler } = await source('proxy.ts');
const { handleDirectUpgrade } = await source('e2e/direct.ts');
const { generateKeyPair } = await source('e2e/noise.ts');
const { acceptWebSocket } = await source('e2e/ws-server.ts');
const { admissionHash } = await source('e2e/credentials.ts');

const devices = new DeviceRegistry();
const e2e = new E2ERegistry(devices);
e2e.setKey(generateKeyPair());
e2e.setRelay({ hostId: randomBytes(16), nodes: ['relay1.openmausbot.com'] });
const messages = [{ id: 'msg-1', role: 'bot', kind: 'text', text: '早上好', createdAt: Date.now() }];
const streams = new Set();
let sequence = 0;
const emit = frame => {
  for (const response of streams) response.write(`id: ${++sequence}\ndata: ${JSON.stringify(frame)}\n\n`);
};
let model = { instanceId: 'claude', model: 'claude-sonnet-4-5' };
const card = { title: '允许构建？', subtitle: '', options: ['允许', '拒绝'], requestId: 'req-1', requestType: 'permission', tool: 'Bash' };
messages.push({ id: 'msg-card', role: 'bot', kind: 'options', card, createdAt: Date.now() });
const bot = () => ({ id: 'bot-1', name: 'E2E Maus', title: '主线', threadId: 'thread-main', tasks: [{ threadId: 'thread-main', title: '主线' }], modelSelection: model, messages, hasMore: false });
const json = (res, value, status = 200) => res.writeHead(status, { 'Content-Type': 'application/json' }).end(JSON.stringify(value));
const harness = createServer(async (req, res) => {
  const path = req.url.split('?')[0];
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  let body = {};
  try { body = JSON.parse(Buffer.concat(chunks).toString()); } catch {}
  if (path === '/api/health') return json(res, { app: 'openmausbot', name: 'Official E2E Fixture' });
  if (path === '/api/bots') return json(res, { bots: [bot()], groups: [] });
  if (path === '/api/instances') return json(res, { instances: [{ instanceId: 'claude', enabled: true, models: { options: [{ id: 'claude-opus-4-1', label: 'Opus' }] } }] });
  if (path.endsWith('/messages') && req.method === 'GET') return json(res, { messages, hasMore: false });
  if (path === '/api/events') {
    res.writeHead(200, { 'Content-Type': 'text/event-stream' });
    res.write(`data: ${JSON.stringify({ kind: 'hello', resumed: false })}\n\n`);
    streams.add(res);
    req.on('close', () => streams.delete(res));
    return;
  }
  if (path.endsWith('/messages') && req.method === 'POST') {
    const message = { id: `m-${++sequence}`, role: 'user', kind: 'text', text: body.text, clientId: body.clientId, createdAt: Date.now() };
    messages.push(message); emit({ kind: 'message', threadId: body.threadId, message });
    setTimeout(() => {
      const reply = { id: `m-${++sequence}`, role: 'bot', kind: 'text', text: `收到 ${body.text}`, createdAt: Date.now() };
      messages.push(reply); emit({ kind: 'message', threadId: body.threadId, message: reply });
    }, 100);
    return json(res, { ok: true }, 202);
  }
  if (path.endsWith('/respond')) {
    card.answered = body.behavior;
    emit({ kind: 'message.patch', threadId: 'thread-main', message: { id: 'msg-card', card } });
    return json(res, { ok: true });
  }
  if (path.endsWith('/model')) { model = body; return json(res, { bot: bot() }); }
  if (path === '/api/search') return json(res, { hits: [{ threadId: 'thread-main', messageId: 'msg-1', text: '早上好' }] });
  if (path.endsWith('/tasks')) return json(res, { task: { threadId: 'thread-new', title: '新对话' } }, 201);
  return json(res, { ok: true });
});
await new Promise(resolve => harness.listen(0, '127.0.0.1', resolve));
const port = Number(process.env.OMB_TEST_PORT || 18992);
const routes = () => [{ url: `http://127.0.0.1:${port}`, kind: 'lan', priority: 0 }];
const proxy = createProxyHandler({
  harnessPort: harness.address().port,
  authenticate: token => devices.authenticate(token),
  redeem: (credential, name, requestId) => devices.redeem(credential, name, requestId),
  serverName: () => 'Official E2E Fixture', hosts: () => ['127.0.0.1'], endpoints: routes,
  e2eDescriptor: id => e2e.descriptor(id),
  e2ePaired: (context, id) => e2e.paired(context, id),
});
const origin = createE2EOrigin(proxy, proxy.upgrade);
const server = createServer((req, res) => {
  if (req.url === '/test/devices') return json(res, devices.list());
  if (req.url === '/test/invite') {
    const window = devices.openPairing();
    return json(res, { link: `openmausbot://pair?address=127.0.0.1&port=${port}&token=${window.token}&e2e=${Buffer.from(JSON.stringify(e2e.descriptor(null))).toString('base64url')}` });
  }
  proxy(req, res);
});
server.on('upgrade', (req, socket, head) => {
  if (req.url !== '/test/relay') return handleDirectUpgrade(req, socket, head, e2e, origin);
  acceptWebSocket(req, socket, head, { protocol: 'omb-relay.v1', maxPayload: 70_000 }, connection => {
    let encrypted = null;
    return {
      message: (data, binary) => {
        if (encrypted) return encrypted.receive(data, binary);
        let auth;
        try { auth = JSON.parse(Buffer.from(data).toString()); } catch { return connection.close(4400); }
        if (binary || auth.t !== 'phone' || auth.v !== 1 || auth.hid !== e2e.descriptor(null).h ||
            !e2e.admissionSet().includes(admissionHash(Buffer.from(auth.adm ?? '', 'base64url')))) return connection.close(4404);
        const ready = Buffer.from(JSON.stringify({ t: 'ready' }));
        socket.write(Buffer.concat([Buffer.from([0x81, ready.length]), ready]));
        encrypted = e2e.accept(connection, 1, 'relay', context => origin.connect(context));
      },
      close: code => encrypted?.transportClosed(code),
    };
  });
});
await new Promise(resolve => server.listen(port, '127.0.0.1', resolve));
const window = devices.openPairing();
const link = `openmausbot://pair?address=127.0.0.1&port=${port}&token=${window.token}&e2e=${Buffer.from(JSON.stringify(e2e.descriptor(null))).toString('base64url')}`;
console.log(JSON.stringify({ ready: true, url: `http://127.0.0.1:${port}`, link }));
if (process.env.OMB_TEST_INVITE) writeFileSync(process.env.OMB_TEST_INVITE, link, { mode: 0o600 });
const stop = () => { e2e.closeAll(); origin.close(); server.close(); harness.close(); process.exit(0); };
process.on('SIGTERM', stop); process.on('SIGINT', stop);
