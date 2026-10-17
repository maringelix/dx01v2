// Small deterministic backend used only by the full-profile service-mesh exercise. The regular API
// and its public routes do not expose these fault-injection responses.
import { createServer, type Server } from 'node:http';
import { isMain } from './entrypoint.ts';

export type MeshVariant = 'stable' | 'canary';

export function createMeshDemoServer(
  variant: MeshVariant,
  writeLog: (line: string) => void = (line) => process.stdout.write(`${line}\n`),
): Server {
  return createServer((req, res) => {
    const requestPath = new URL(req.url ?? '/', 'http://mesh-demo.invalid').pathname;
    const path = ['/healthz', '/variant', '/fail'].includes(requestPath) ? requestPath : '/unknown';
    const header = req.headers['x-request-id'];
    const requestId = (Array.isArray(header) ? (header[0] ?? 'none') : (header ?? 'none'))
      .replace(/[^A-Za-z0-9._-]/g, '')
      .slice(0, 64);
    const probeHeader = req.headers['x-lab-probe-id'];
    const probeId = (Array.isArray(probeHeader) ? (probeHeader[0] ?? '') : (probeHeader ?? ''))
      .replace(/[^A-Za-z0-9._-]/g, '')
      .slice(0, 64);
    writeLog(`MESH_REQUEST variant=${variant} path=${path} request_id=${requestId} probe_id=${probeId}`);
    res.setHeader('content-type', 'application/json; charset=utf-8');
    res.setHeader('cache-control', 'no-store');
    res.setHeader('x-lab-variant', variant);

    if (req.method !== 'GET') {
      res.writeHead(405).end(JSON.stringify({ error: 'method_not_allowed' }));
      return;
    }
    if (path === '/healthz') {
      res.writeHead(200).end(JSON.stringify({ status: 'ok', variant }));
      return;
    }
    if (path === '/variant') {
      res.writeHead(200).end(JSON.stringify({ variant }));
      return;
    }
    if (path === '/fail' && variant === 'canary') {
      res.writeHead(503).end(JSON.stringify({ error: 'intentional_canary_failure', variant }));
      return;
    }
    if (path === '/fail' && variant === 'stable') {
      res.writeHead(200).end(JSON.stringify({ variant }));
      return;
    }
    res.writeHead(404).end(JSON.stringify({ error: 'not_found' }));
  });
}

export function main(env: NodeJS.ProcessEnv = process.env): void {
  const variant = env.MESH_VARIANT;
  if (variant !== 'stable' && variant !== 'canary') {
    process.stderr.write('mesh-demo: MESH_VARIANT must be stable or canary\n');
    process.exitCode = 1;
    return;
  }
  const portValue = env.PORT ?? '3000';
  if (!/^[0-9]+$/.test(portValue) || Number(portValue) < 1 || Number(portValue) > 65535) {
    process.stderr.write('mesh-demo: PORT must be a TCP port\n');
    process.exitCode = 1;
    return;
  }
  const server = createMeshDemoServer(variant);
  server.listen(Number(portValue), '0.0.0.0', () => {
    process.stdout.write(`mesh-demo: ${variant} listening on ${portValue}\n`);
  });
}

if (isMain(import.meta.url)) {
  main();
}
