// CI-only client for the full-profile service-mesh exercise. It runs under a dedicated Kubernetes
// ServiceAccount so the waypoint policy can distinguish an allowed caller from an intruder.
import { randomBytes } from 'node:crypto';
import { isMain } from './entrypoint.ts';

const target = process.env.MESH_PROBE_TARGET ?? 'http://mesh-demo:3000';
const mode = process.env.MESH_PROBE_MODE;

function fail(message: string): never {
  process.stderr.write(`mesh-probe: ${message}\n`);
  process.exitCode = 1;
  throw new Error(message);
}

async function get(path: string, probeId?: string): Promise<Response> {
  return fetch(new URL(path, target), {
    headers: probeId ? { 'x-lab-probe-id': probeId } : undefined,
    signal: AbortSignal.timeout(7_000),
  });
}

async function runAllowed(): Promise<void> {
  const total = 400;
  const counts = { stable: 0, canary: 0 };
  for (let i = 0; i < total; i += 1) {
    const response = await get('/variant');
    if (!response.ok) fail(`/variant returned HTTP ${response.status}`);
    const variant = response.headers.get('x-lab-variant');
    if (variant !== 'stable' && variant !== 'canary') fail(`unexpected backend identity ${String(variant)}`);
    counts[variant] += 1;
  }

  const canaryRatio = counts.canary / total;
  if (counts.stable === 0 || counts.canary === 0 || canaryRatio < 0.12 || canaryRatio > 0.28) {
    fail(`80/20 split was outside the 12–28% sampling band: ${JSON.stringify(counts)}`);
  }

  const retryId = `mesh_retry_${randomBytes(8).toString('hex')}`;
  const retryResponse = await get('/fail', retryId);
  if (retryResponse.status !== 503) fail(`/fail returned HTTP ${retryResponse.status}, expected 503`);

  // The retry policy allows two retries after the original request. Three consecutive canary 5xx
  // responses should open the circuit; the next request must fail closed at the waypoint without
  // reaching the already-ejected backend.
  await new Promise((resolve) => setTimeout(resolve, 2_500));
  const isolationId = `mesh_isolation_${randomBytes(8).toString('hex')}`;
  const isolationResponse = await get('/fail', isolationId);
  if (isolationResponse.status !== 503) fail(`/fail after canary ejection returned HTTP ${isolationResponse.status}`);

  process.stdout.write(
    `MESH_PROBE_RESULT total=${total} stable=${counts.stable} canary=${counts.canary} retry_request_id=${retryId} isolation_request_id=${isolationId} fail_status=${retryResponse.status}\n`,
  );
}

async function runIntruder(): Promise<void> {
  const response = await get('/variant');
  if (response.status !== 403) fail(`unauthorized identity received HTTP ${response.status}, expected 403`);
  process.stdout.write('MESH_PROBE_DENIED status=403\n');
}

export async function main(): Promise<void> {
  if (mode !== 'allowed' && mode !== 'intruder') fail('MESH_PROBE_MODE must be allowed or intruder');
  if (mode === 'allowed') await runAllowed();
  else await runIntruder();
}

if (isMain(import.meta.url)) {
  await main();
}
