import { describe, expect, it, vi } from 'vitest';
import request from 'supertest';
import { createMeshDemoServer } from '../../src/mesh-demo.ts';

describe('service mesh exercise backend', () => {
  it('reports the variant and returns a healthy probe', async () => {
    const server = createMeshDemoServer('stable', vi.fn());
    await request(server).get('/healthz').expect(200, { status: 'ok', variant: 'stable' });
    const response = await request(server).get('/variant').expect(200, { variant: 'stable' });
    expect(response.headers['x-lab-variant']).toBe('stable');
  });

  it('returns a deterministic 503 only from the canary fault path', async () => {
    const canary = createMeshDemoServer('canary', vi.fn());
    const failed = await request(canary).get('/fail').set('x-request-id', 'mesh-retry-1').expect(503);
    expect(failed.body).toEqual({ error: 'intentional_canary_failure', variant: 'canary' });

    const stable = createMeshDemoServer('stable', vi.fn());
    await request(stable).get('/fail').expect(200, { variant: 'stable' });
  });

  it('logs only a bounded request identifier for retry counting', async () => {
    const writeLog = vi.fn();
    const server = createMeshDemoServer('canary', writeLog);
    await request(server).get('/fail').set('x-request-id', 'retry id with unsafe chars').expect(503);
    expect(writeLog).toHaveBeenCalledWith(
      'MESH_REQUEST variant=canary path=/fail request_id=retryidwithunsafechars probe_id=',
    );
  });

  it('bounds unknown paths and the mesh probe id in logs', async () => {
    const writeLog = vi.fn();
    const server = createMeshDemoServer('stable', writeLog);
    await request(server)
      .get(`/${'x'.repeat(512)}?password=must-not-be-logged`)
      .set('x-lab-probe-id', `probe ${'y'.repeat(128)}`)
      .expect(404);
    expect(writeLog).toHaveBeenCalledWith(
      `MESH_REQUEST variant=stable path=/unknown request_id=none probe_id=probe${'y'.repeat(59)}`,
    );
  });
});
