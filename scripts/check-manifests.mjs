// Structural checks of the rendered Kubernetes manifests against contract v6 (docs/CONTRATO.md)
// and the hardening rules of docs/GUARDRAILS.md. Used by the harness check `contract-app`.
//   node scripts/check-manifests.mjs --params <params.env> local=<file> aws=<file> aws-https=<file> ...
import { readFileSync } from 'node:fs';
import { parseAllDocuments } from 'yaml';

const NAMESPACE = 'dx01v2';
// Kinds the deployer Role of tx01v2 may write (docs/CONTRATO.md). Secrets are written by ESO only.
const DEPLOYER_KINDS = new Set([
  'ConfigMap',
  'Deployment',
  'ExternalSecret',
  'HorizontalPodAutoscaler',
  'Ingress',
  'NetworkPolicy',
  'PodDisruptionBudget',
  'Service',
  'ServiceAccount',
]);

const failures = [];
let assertions = 0;
const check = (ok, message) => {
  assertions++;
  if (!ok) {
    failures.push(message);
  }
};
// Deep equality that ignores object key order (kustomize prints keys alphabetically); array order
// still matters.
const canonical = (value) => {
  if (Array.isArray(value)) {
    return value.map(canonical);
  }
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonical(value[key])]),
    );
  }
  return value;
};
const eq = (actual, expected, message) =>
  check(
    JSON.stringify(canonical(actual)) === JSON.stringify(canonical(expected)),
    `${message}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
  );

function parseArgs(argv) {
  const files = {};
  let params;
  let localParams;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--params') {
      params = argv[++i];
    } else if (argv[i] === '--local-params') {
      localParams = argv[++i];
    } else {
      const [name, file] = argv[i].split('=');
      files[name] = file;
    }
  }
  if (params === undefined || Object.keys(files).length === 0) {
    console.error('usage: node scripts/check-manifests.mjs --params <params.env> <overlay>=<rendered.yaml>...');
    process.exit(2);
  }
  return {
    params: readParams(params),
    files,
    localParams: localParams === undefined ? undefined : readParams(localParams),
  };
}

function readParams(file) {
  const out = {};
  for (const line of readFileSync(file, 'utf8').split('\n')) {
    const match = /^([A-Z_]+)=(.*)$/.exec(line);
    if (match) {
      out[match[1]] = match[2];
    }
  }
  return out;
}

function load(file) {
  const docs = parseAllDocuments(readFileSync(file, 'utf8'));
  for (const doc of docs) {
    if (doc.errors.length > 0) {
      throw new Error(`${file}: ${doc.errors[0].message}`);
    }
  }
  return docs.map((doc) => doc.toJS()).filter((obj) => obj !== null);
}

const find = (objs, kind, name) => objs.find((o) => o.kind === kind && o.metadata?.name === name);

function podChecks(where, workload) {
  for (const key of ['cost.lab/owner', 'cost.lab/environment']) {
    check(
      typeof workload.spec?.template?.metadata?.labels?.[key] === 'string' &&
        workload.spec.template.metadata.labels[key].length > 0,
      where + ': mandatory showback label ' + key,
    );
  }
  const spec = workload.spec?.template?.spec ?? {};
  const pod = spec.securityContext ?? {};
  check(pod.runAsNonRoot === true, `${where}: pod securityContext.runAsNonRoot must be true`);
  check(
    Number.isInteger(pod.runAsUser) && pod.runAsUser > 0,
    `${where}: pod securityContext.runAsUser must be a non-root uid`,
  );
  eq(pod.seccompProfile?.type, 'RuntimeDefault', `${where}: seccompProfile`);
  check(spec.automountServiceAccountToken === false, `${where}: automountServiceAccountToken must be false`);
  for (const key of ['hostNetwork', 'hostPID', 'hostIPC']) {
    check(spec[key] !== true, `${where}: ${key} is forbidden`);
  }
  for (const volume of spec.volumes ?? []) {
    check(volume.hostPath === undefined, `${where}: hostPath volume ${volume.name} is forbidden`);
  }
  for (const c of [...(spec.initContainers ?? []), ...(spec.containers ?? [])]) {
    const sc = c.securityContext ?? {};
    const name = `${where}/${c.name}`;
    check(sc.allowPrivilegeEscalation === false, `${name}: allowPrivilegeEscalation must be false`);
    check(sc.readOnlyRootFilesystem === true, `${name}: readOnlyRootFilesystem must be true`);
    check(sc.privileged !== true, `${name}: privileged is forbidden`);
    check((sc.capabilities?.drop ?? []).includes('ALL'), `${name}: capabilities.drop must include ALL`);
    check((sc.capabilities?.add ?? []).length === 0, `${name}: no capabilities may be added`);
    check(
      c.resources?.requests?.cpu !== undefined && c.resources?.requests?.memory !== undefined,
      `${name}: cpu/memory requests`,
    );
    check(c.resources?.limits?.memory !== undefined, `${name}: memory limit`);
  }
  return spec;
}

function probePath(container, probe) {
  return container?.[probe]?.httpGet?.path;
}

function commonChecks(overlay, objs) {
  for (const o of objs) {
    if (o.kind !== 'Namespace') {
      eq(o.metadata?.namespace, NAMESPACE, `${overlay}: ${o.kind}/${o.metadata?.name} namespace`);
    }
    check(
      o.kind !== 'Secret',
      `${overlay}: Secret ${o.metadata?.name} must not be in git (created at runtime or by ESO)`,
    );
  }

  const api = find(objs, 'Deployment', 'api');
  const web = find(objs, 'Deployment', 'web');
  check(api !== undefined && web !== undefined, `${overlay}: Deployments api and web`);
  if (api === undefined || web === undefined) {
    return;
  }
  const apiSpec = podChecks(`${overlay}: Deployment/api`, api);
  const webSpec = podChecks(`${overlay}: Deployment/web`, web);
  const apiContainer = apiSpec.containers?.find((c) => c.name === 'api');
  const migrate = apiSpec.initContainers?.find((c) => c.name === 'migrate');
  const webContainer = webSpec.containers?.find((c) => c.name === 'web');

  eq(apiSpec.serviceAccountName, 'api', `${overlay}: api serviceAccountName`);
  eq(webSpec.serviceAccountName, 'web', `${overlay}: web serviceAccountName`);
  eq(migrate?.args, ['dist/migrate.js'], `${overlay}: initContainer migrate args`);
  eq(migrate?.image, apiContainer?.image, `${overlay}: migrate uses the api image`);
  eq(apiContainer?.args, ['dist/server.js'], `${overlay}: api args`);
  eq(
    (apiContainer?.ports ?? []).map((p) => [p.name, p.containerPort]),
    [
      ['http', 3000],
      ['metrics', 9464],
    ],
    `${overlay}: api container ports`,
  );
  eq(probePath(apiContainer, 'startupProbe'), '/healthz', `${overlay}: api startupProbe`);
  eq(probePath(apiContainer, 'livenessProbe'), '/healthz', `${overlay}: api livenessProbe`);
  eq(probePath(apiContainer, 'readinessProbe'), '/readyz', `${overlay}: api readinessProbe`);
  eq(probePath(webContainer, 'readinessProbe'), '/healthz', `${overlay}: web readinessProbe`);
  eq(apiContainer?.lifecycle?.preStop?.sleep?.seconds, 5, `${overlay}: api preStop sleep`);
  for (const c of [migrate, apiContainer]) {
    const refs = (c?.envFrom ?? []).map((e) => e.configMapRef?.name ?? `secret:${e.secretRef?.name}`);
    eq(refs, ['app-config', 'secret:db-credentials'], `${overlay}: ${c?.name} envFrom`);
  }
  const adminToken = apiContainer?.env?.find((e) => e.name === 'ADMIN_TOKEN')?.valueFrom?.secretKeyRef;
  eq(
    adminToken && { name: adminToken.name, key: adminToken.key },
    { name: 'app-secrets', key: 'ADMIN_TOKEN' },
    `${overlay}: ADMIN_TOKEN source`,
  );
  eq(webContainer?.ports?.[0]?.containerPort, 8080, `${overlay}: web container port`);

  const apiService = find(objs, 'Service', 'api');
  const webService = find(objs, 'Service', 'web');
  eq(
    (apiService?.spec?.ports ?? []).map((p) => [p.name, p.port]),
    [
      ['http', 3000],
      ['metrics', 9464],
    ],
    `${overlay}: Service api ports`,
  );
  eq(
    (webService?.spec?.ports ?? []).map((p) => [p.name, p.port]),
    [['http', 8080]],
    `${overlay}: Service web ports`,
  );
  for (const name of ['api', 'web']) {
    eq(
      find(objs, 'ServiceAccount', name)?.automountServiceAccountToken,
      false,
      `${overlay}: ServiceAccount ${name} token`,
    );
    eq(find(objs, 'PodDisruptionBudget', name)?.spec?.minAvailable, 1, `${overlay}: PDB ${name} minAvailable`);
  }

  const deny = find(objs, 'NetworkPolicy', 'default-deny-all');
  eq(deny?.spec?.podSelector, {}, `${overlay}: default-deny-all selects every pod`);
  eq(deny?.spec?.policyTypes, ['Ingress', 'Egress'], `${overlay}: default-deny-all policyTypes`);
  check(
    deny?.spec?.ingress === undefined && deny?.spec?.egress === undefined,
    `${overlay}: default-deny-all has no rules`,
  );
  const dns = find(objs, 'NetworkPolicy', 'allow-dns-egress');
  eq(
    dns?.spec?.egress?.[0]?.to?.[0]?.podSelector?.matchLabels,
    { 'k8s-app': 'kube-dns' },
    `${overlay}: DNS egress target`,
  );
  const waypointFull = overlay.endsWith('-full') || overlay === 'local-platform';
  const appEgress = find(objs, 'NetworkPolicy', 'web-egress-to-api')?.spec?.egress?.[0];
  if (waypointFull) {
    eq(
      appEgress?.to?.[0]?.podSelector?.matchLabels,
      { 'gateway.networking.k8s.io/gateway-name': 'dx01v2-waypoint' },
      `${overlay}: web reaches the API through the namespace waypoint`,
    );
    eq(appEgress?.ports, [{ protocol: 'TCP', port: 15008 }], `${overlay}: web egress uses HBONE only`);
    eq(
      find(objs, 'NetworkPolicy', 'api-ingress-from-web')?.spec?.ingress?.[0]?.from?.[0]?.podSelector?.matchLabels,
      { 'gateway.networking.k8s.io/gateway-name': 'dx01v2-waypoint' },
      `${overlay}: API accepts the waypoint, not direct web traffic`,
    );
  } else {
    eq(
      appEgress?.ports,
      [
        { protocol: 'TCP', port: 3000 },
        { protocol: 'TCP', port: 15008 },
      ],
      `${overlay}: web -> api and ambient HBONE`,
    );
    eq(
      find(objs, 'NetworkPolicy', 'api-ingress-from-web')?.spec?.ingress?.[0]?.from?.[0]?.podSelector?.matchLabels,
      { 'app.kubernetes.io/name': 'web' },
      `${overlay}: api accepts web`,
    );
  }
  const metrics = find(objs, 'NetworkPolicy', 'api-metrics-from-monitoring')?.spec?.ingress?.[0];
  if (waypointFull) {
    eq(
      metrics?.from?.[0]?.podSelector?.matchLabels,
      { 'gateway.networking.k8s.io/gateway-name': 'dx01v2-waypoint' },
      `${overlay}: metrics requests use the waypoint`,
    );
    eq(metrics?.ports, [{ protocol: 'TCP', port: 15008 }], `${overlay}: metrics use HBONE`);
  } else {
    eq(
      metrics?.from?.[0]?.namespaceSelector?.matchLabels,
      { 'kubernetes.io/metadata.name': 'monitoring' },
      `${overlay}: metrics source`,
    );
    eq(metrics?.ports, [{ protocol: 'TCP', port: 9464 }], `${overlay}: metrics port`);
  }
  return { apiSpec, apiContainer, migrate, webContainer };
}

function localChecks(objs) {
  const ns = find(objs, 'Namespace', NAMESPACE);
  eq(ns?.metadata?.labels?.['pod-security.kubernetes.io/enforce'], 'restricted', 'local: PSA enforce');
  eq(ns?.metadata?.labels?.['pod-security.kubernetes.io/enforce-version'], 'latest', 'local: PSA enforce-version');
  const config = find(objs, 'ConfigMap', 'app-config')?.data ?? {};
  eq([config.APP_ENV, config.DB_SSL_MODE, config.TRUST_PROXY_HOPS], ['kind', 'disable', '1'], 'local: app-config');
  eq(config.OTEL_EXPORTER_OTLP_ENDPOINT, undefined, 'local: no trace exporter on kind (no Collector there)');
  const pg = find(objs, 'StatefulSet', 'postgres');
  const spec = pg === undefined ? {} : podChecks('local: StatefulSet/postgres', pg);
  eq(spec.securityContext?.runAsUser, 70, 'local: postgres uid');
  check(
    /^postgres:17-alpine@sha256:[0-9a-f]{64}$/.test(spec.containers?.[0]?.image ?? ''),
    'local: postgres image pinned by digest',
  );
  check(
    (spec.volumes ?? []).every((v) => v.emptyDir !== undefined),
    'local: postgres uses emptyDir volumes only',
  );
  for (const d of ['api', 'web']) {
    const pod = find(objs, 'Deployment', d)?.spec?.template?.spec;
    for (const c of [...(pod?.initContainers ?? []), ...(pod?.containers ?? [])]) {
      eq([c.image, c.imagePullPolicy], [`dx01v2-${d}:e2e`, 'Never'], `local: ${d}/${c.name} image`);
    }
  }
  eq(
    find(objs, 'NetworkPolicy', 'api-egress-to-postgres')?.spec?.egress?.[0]?.ports,
    [{ protocol: 'TCP', port: 5432 }],
    'local: api -> postgres:5432',
  );
  eq(
    find(objs, 'NetworkPolicy', 'postgres-ingress-from-api')?.spec?.ingress?.[0]?.from?.[0]?.podSelector?.matchLabels,
    { 'app.kubernetes.io/name': 'api' },
    'local: postgres accepts api only',
  );
}

function awsChecks(overlay, objs, params, https) {
  const allowedKinds = overlay.endsWith('-full')
    ? new Set([...DEPLOYER_KINDS, 'HTTPRoute', 'DestinationRule', 'AuthorizationPolicy'])
    : DEPLOYER_KINDS;
  for (const o of objs) {
    check(allowedKinds.has(o.kind), `${overlay}: ${o.kind} is outside what the dx01v2-deployer Role may write`);
  }
  const config = find(objs, 'ConfigMap', 'app-config')?.data ?? {};
  eq(
    [config.APP_ENV, config.DB_SSL_MODE, config.DB_SSL_CA_FILE, config.TRUST_PROXY_HOPS],
    ['lab', 'verify-full', '/etc/rds-ca/ca.pem', '1'],
    `${overlay}: app-config`,
  );
  const api = find(objs, 'Deployment', 'api');
  const pod = api?.spec?.template?.spec ?? {};
  check(api?.spec?.replicas === undefined, `${overlay}: api replicas must be left to the HPA`);
  eq(pod.volumes, [{ name: 'rds-ca', configMap: { name: 'rds-ca' } }], `${overlay}: rds-ca volume`);
  for (const c of [...(pod.initContainers ?? []), ...(pod.containers ?? [])]) {
    eq(
      c.volumeMounts,
      [{ name: 'rds-ca', mountPath: '/etc/rds-ca', readOnly: true }],
      `${overlay}: ${c.name} mounts rds-ca`,
    );
    eq(c.image, params.API_IMAGE, `${overlay}: ${c.name} image from params`);
  }
  eq(
    find(objs, 'Deployment', 'web')?.spec?.template?.spec?.containers?.[0]?.image,
    params.WEB_IMAGE,
    `${overlay}: web image from params`,
  );

  const ingress = find(objs, 'Ingress', 'dx01v2');
  const a = ingress?.metadata?.annotations ?? {};
  eq(ingress?.spec?.ingressClassName, 'alb', `${overlay}: ingress class`);
  eq(a['alb.ingress.kubernetes.io/scheme'], 'internet-facing', `${overlay}: ALB scheme`);
  eq(a['alb.ingress.kubernetes.io/target-type'], 'ip', `${overlay}: ALB target type`);
  eq(a['alb.ingress.kubernetes.io/wafv2-acl-arn'], params.WAF_ACL_ARN, `${overlay}: WAF ACL from params`);
  if (https) {
    eq(a['alb.ingress.kubernetes.io/listen-ports'], '[{"HTTP": 80}, {"HTTPS": 443}]', `${overlay}: listeners`);
    eq(
      a['alb.ingress.kubernetes.io/certificate-arn'],
      params.ALB_CERTIFICATE_ARN,
      `${overlay}: certificate from params`,
    );
    eq(ingress?.spec?.rules?.[0]?.host, params.APP_DOMAIN_NAME, `${overlay}: hostname from tx01v2 contract`);
    eq(a['alb.ingress.kubernetes.io/ssl-redirect'], '443', `${overlay}: HTTP -> HTTPS redirect`);
  } else {
    eq(a['alb.ingress.kubernetes.io/listen-ports'], '[{"HTTP": 80}]', `${overlay}: listeners`);
    check(a['alb.ingress.kubernetes.io/certificate-arn'] === undefined, `${overlay}: no certificate without HTTPS`);
    check(ingress?.spec?.rules?.[0]?.host === undefined, `${overlay}: no public hostname without HTTPS`);
  }
  eq(
    (ingress?.spec?.rules?.[0]?.http?.paths ?? []).map((p) => [
      p.path,
      p.pathType,
      p.backend?.service?.name,
      p.backend?.service?.port?.number,
    ]),
    [['/', 'Prefix', 'web', 8080]],
    `${overlay}: the ALB targets only web; nginx proxies /api through the mesh`,
  );
  eq(
    find(objs, 'Service', 'web')?.metadata?.annotations?.['alb.ingress.kubernetes.io/healthcheck-path'],
    '/healthz',
    `${overlay}: web health check`,
  );

  const db = find(objs, 'ExternalSecret', 'db-credentials')?.spec;
  eq(
    db?.secretStoreRef,
    { kind: 'ClusterSecretStore', name: 'aws-secrets-manager' },
    `${overlay}: db-credentials store`,
  );
  eq(db?.target?.name, 'db-credentials', `${overlay}: db-credentials target`);
  eq(
    (db?.data ?? []).map((d) => [d.secretKey, d.remoteRef?.key, d.remoteRef?.property]),
    [
      ['DB_HOST', 'tx01v2-lab/db/app', 'host'],
      ['DB_PORT', 'tx01v2-lab/db/app', 'port'],
      ['DB_NAME', 'tx01v2-lab/db/app', 'dbname'],
      ['DB_USER', 'tx01v2-lab/db/app', 'username'],
      ['DB_PASSWORD', 'tx01v2-lab/db/app', 'password'],
    ],
    `${overlay}: db-credentials mapping`,
  );
  const app = find(objs, 'ExternalSecret', 'app-secrets')?.spec;
  eq(app?.secretStoreRef, { kind: 'ClusterSecretStore', name: 'aws-secrets-manager' }, `${overlay}: app-secrets store`);
  eq(
    (app?.data ?? []).map((d) => [d.secretKey, d.remoteRef?.key, d.remoteRef?.property]),
    [['ADMIN_TOKEN', 'tx01v2-lab/app/admin-token', undefined]],
    `${overlay}: app-secrets mapping`,
  );

  const hpa = find(objs, 'HorizontalPodAutoscaler', 'api')?.spec;
  eq(
    [
      hpa?.scaleTargetRef?.name,
      hpa?.minReplicas,
      hpa?.maxReplicas,
      hpa?.metrics?.[0]?.resource?.target?.averageUtilization,
    ],
    ['api', 2, 4, 70],
    `${overlay}: HPA`,
  );
  for (const [name, direction, port, cidr] of [
    ['web-ingress-from-alb', 'ingress', 8080, params.ALB_SOURCE_CIDR],
    ['api-egress-to-rds', 'egress', 5432, params.VPC_CIDR],
  ]) {
    const rule = find(objs, 'NetworkPolicy', name)?.spec?.[direction]?.[0];
    const peer = direction === 'ingress' ? rule?.from?.[0] : rule?.to?.[0];
    eq([peer?.ipBlock?.cidr, rule?.ports?.[0]?.port], [cidr, port], `${overlay}: NetworkPolicy ${name}`);
  }
  check(!find(objs, 'NetworkPolicy', 'api-ingress-from-alb'), `${overlay}: ALB does not target the API directly`);
  eq(
    find(objs, 'NetworkPolicy', 'web-health-probe-from-node')?.spec?.ingress?.[0],
    {
      from: [{ ipBlock: { cidr: '169.254.7.127/32' } }],
      ports: [{ protocol: 'TCP', port: 8080 }],
    },
    `${overlay}: only the ambient node probe gets a non-ALB web ingress exception`,
  );
  eq(
    find(objs, 'NetworkPolicy', 'api-health-probe-from-node')?.spec?.ingress?.[0],
    {
      from: [{ ipBlock: { cidr: '169.254.7.127/32' } }],
      ports: [{ protocol: 'TCP', port: 3000 }],
    },
    `${overlay}: the ambient node probe gets an API health-check exception`,
  );
  check(
    !find(objs, 'NetworkPolicy', 'api-ingress-from-monitoring'),
    `${overlay}: monitoring must use the waypoint rather than a direct API pod path`,
  );
  // Contract v2: traces to the OpenTelemetry Collector of the platform layer, and nowhere else.
  eq(
    config.OTEL_EXPORTER_OTLP_ENDPOINT,
    'http://opentelemetry-collector.observability.svc:4318',
    `${overlay}: OTLP endpoint of the contract`,
  );
  eq(
    find(objs, 'NetworkPolicy', 'api-egress-to-collector')?.spec?.egress,
    [
      {
        to: [
          {
            namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'observability' } },
            podSelector: { matchLabels: { 'app.kubernetes.io/name': 'opentelemetry-collector' } },
          },
        ],
        ports: [
          { protocol: 'TCP', port: 4318 },
          { protocol: 'TCP', port: 15008 },
        ],
      },
    ],
    `${overlay}: api -> OpenTelemetry Collector (OTLP and ambient HBONE) only`,
  );
  if (overlay.endsWith('-full')) {
    eq(
      find(objs, 'ServiceAccount', 'mesh-demo')?.automountServiceAccountToken,
      false,
      `${overlay}: mesh demo workloads do not receive service account tokens`,
    );
    for (const name of ['mesh-stable', 'mesh-canary']) {
      const workload = find(objs, 'Deployment', name);
      eq(
        workload?.spec?.template?.spec?.containers?.[0]?.image,
        params.API_IMAGE,
        `${overlay}: ${name} uses the approved API image digest`,
      );
      eq(
        workload?.spec?.template?.spec?.serviceAccountName,
        'mesh-demo',
        `${overlay}: ${name} uses the non-privileged mesh-demo identity`,
      );
    }
    const route = find(objs, 'HTTPRoute', 'mesh-demo')?.spec;
    eq(
      route?.parentRefs?.map((parent) => [parent.group ?? '', parent.kind, parent.name, parent.port]),
      [['', 'Service', 'mesh-demo', 3000]],
      `${overlay}: mesh HTTPRoute attaches to the service served by the waypoint`,
    );
    const weighted = (route?.rules ?? []).find((rule) => rule.name === 'weighted-canary');
    eq(
      weighted?.backendRefs?.map((backend) => [backend.name, backend.port, backend.weight]),
      [
        ['mesh-stable', 3000, 80],
        ['mesh-canary', 3000, 20],
      ],
      `${overlay}: canary traffic split`,
    );
    eq(
      (route?.rules ?? []).find((rule) => rule.name === 'bounded-retries')?.retry,
      { attempts: 2, codes: [500, 502, 503, 504] },
      `${overlay}: bounded retry policy`,
    );
    check(
      find(objs, 'DestinationRule', 'mesh-canary')?.spec?.trafficPolicy?.outlierDetection?.consecutive5xxErrors === 3,
      `${overlay}: canary DestinationRule must eject a repeated-failure endpoint`,
    );
    eq(
      find(objs, 'AuthorizationPolicy', 'mesh-demo')?.spec?.targetRefs,
      [{ group: '', kind: 'Service', name: 'mesh-demo' }],
      `${overlay}: mesh L7 authorization attaches to the routed service`,
    );
    check(
      find(objs, 'AuthorizationPolicy', 'mesh-demo')?.spec?.rules?.some((rule) =>
        rule.from?.[0]?.source?.principals?.includes('cluster.local/ns/dx01v2/sa/mesh-probe'),
      ),
      `${overlay}: only the mesh-probe identity may use the mesh exercise`,
    );
    eq(
      find(objs, 'AuthorizationPolicy', 'mesh-demo-require-waypoint')?.spec?.rules?.[0]?.from?.[0]?.source?.principals,
      ['cluster.local/ns/dx01v2/sa/dx01v2-waypoint'],
      `${overlay}: backend workloads accept the waypoint identity only`,
    );
    check(
      find(objs, 'NetworkPolicy', 'mesh-intruder-egress')?.spec?.egress?.[0]?.ports?.[0]?.port === 15008,
      `${overlay}: the intruder reaches the waypoint so the L7 denial is tested`,
    );
    const waypointSelector = { 'gateway.networking.k8s.io/gateway-name': 'dx01v2-waypoint' };
    for (const name of ['mesh-probe-egress', 'mesh-intruder-egress']) {
      eq(
        find(objs, 'NetworkPolicy', name)?.spec?.egress?.[0]?.to?.[0]?.podSelector?.matchLabels,
        waypointSelector,
        `${overlay}: ${name} cannot bypass the waypoint`,
      );
    }
    eq(
      find(objs, 'NetworkPolicy', 'mesh-demo-ingress')?.spec?.ingress?.[0]?.from?.[0]?.podSelector?.matchLabels,
      waypointSelector,
      `${overlay}: demo backends accept HBONE from the waypoint only`,
    );
  }
}

// Kinds the AppProject dx01v2 of the tx01v2 local lab lets Argo CD sync (local contract).
const APPPROJECT_KINDS = new Set([
  ...DEPLOYER_KINDS,
  'Gateway',
  'HTTPRoute',
  'DestinationRule',
  'PeerAuthentication',
  'AuthorizationPolicy',
  'ServiceMonitor',
  'PrometheusRule',
]);
APPPROJECT_KINDS.delete('Ingress');

function localPlatformChecks(objs, params) {
  const overlay = 'local-platform';
  for (const o of objs) {
    check(APPPROJECT_KINDS.has(o.kind), `${overlay}: ${o.kind} is outside what the AppProject dx01v2 may sync`);
  }
  const config = find(objs, 'ConfigMap', 'app-config')?.data ?? {};
  eq(
    [config.APP_ENV, config.DB_SSL_MODE, config.DB_SSL_CA_FILE, config.TRUST_PROXY_HOPS],
    ['lab', 'verify-full', '/etc/lab-ca/ca.crt', '1'],
    `${overlay}: app-config`,
  );
  const api = find(objs, 'Deployment', 'api');
  const pod = api?.spec?.template?.spec ?? {};
  check(api?.spec?.replicas === undefined, `${overlay}: api replicas must be left to the HPA`);
  eq(pod.volumes, [{ name: 'lab-ca', configMap: { name: 'lab-ca' } }], `${overlay}: lab-ca volume`);
  for (const c of [...(pod.initContainers ?? []), ...(pod.containers ?? [])]) {
    eq(
      c.volumeMounts,
      [{ name: 'lab-ca', mountPath: '/etc/lab-ca', readOnly: true }],
      `${overlay}: ${c.name} mounts lab-ca`,
    );
    eq(c.image, params.API_IMAGE, `${overlay}: ${c.name} image from params`);
  }
  eq(
    find(objs, 'Deployment', 'web')?.spec?.template?.spec?.containers?.[0]?.image,
    params.WEB_IMAGE,
    `${overlay}: web image from params`,
  );

  const gw = find(objs, 'Gateway', 'dx01v2');
  eq(gw?.spec?.gatewayClassName, 'istio', `${overlay}: Gateway class`);
  eq(gw?.metadata?.annotations?.['cert-manager.io/cluster-issuer'], 'lab-ca', `${overlay}: Gateway issuer`);
  eq(
    (gw?.spec?.listeners ?? []).map((l) => [l.name, l.protocol, l.port, l.hostname, l.tls?.certificateRefs?.[0]?.name]),
    [
      ['http', 'HTTP', 80, 'dx01v2.tx01v2.local', undefined],
      ['https', 'HTTPS', 443, 'dx01v2.tx01v2.local', 'dx01v2-tls'],
    ],
    `${overlay}: Gateway listeners`,
  );
  const redirect = find(objs, 'HTTPRoute', 'dx01v2-redirect')?.spec;
  eq(redirect?.parentRefs?.[0]?.sectionName, 'http', `${overlay}: redirect on the http listener`);
  eq(
    redirect?.rules?.[0]?.filters?.[0]?.requestRedirect,
    { scheme: 'https', statusCode: 301 },
    `${overlay}: HTTP -> HTTPS redirect`,
  );
  const route = find(objs, 'HTTPRoute', 'dx01v2')?.spec;
  eq(route?.parentRefs?.[0]?.sectionName, 'https', `${overlay}: app routes on the https listener only`);
  eq(
    (route?.rules ?? []).map((r) => [r.matches?.[0]?.path?.value, r.backendRefs?.[0]?.name, r.backendRefs?.[0]?.port]),
    [
      ['/api', 'api', 3000],
      ['/', 'web', 8080],
    ],
    `${overlay}: HTTPRoute rules`,
  );

  const db = find(objs, 'ExternalSecret', 'db-credentials')?.spec;
  eq(db?.secretStoreRef, { kind: 'ClusterSecretStore', name: 'local-secrets' }, `${overlay}: db-credentials store`);
  eq(
    (db?.data ?? []).map((d) => [d.secretKey, d.remoteRef?.key, d.remoteRef?.property]),
    [
      ['DB_HOST', 'tx01v2-lab-db-app', 'host'],
      ['DB_PORT', 'tx01v2-lab-db-app', 'port'],
      ['DB_NAME', 'tx01v2-lab-db-app', 'dbname'],
      ['DB_USER', 'tx01v2-lab-db-app', 'username'],
      ['DB_PASSWORD', 'tx01v2-lab-db-app', 'password'],
    ],
    `${overlay}: db-credentials mapping`,
  );
  const app = find(objs, 'ExternalSecret', 'app-secrets')?.spec;
  eq(
    (app?.data ?? []).map((d) => [d.secretKey, d.remoteRef?.key, d.remoteRef?.property]),
    [['ADMIN_TOKEN', 'tx01v2-lab-app-admin-token', 'token']],
    `${overlay}: app-secrets mapping`,
  );

  eq(find(objs, 'PeerAuthentication', 'default')?.spec?.mtls?.mode, 'STRICT', `${overlay}: mTLS STRICT`);
  const principals = (name) =>
    (find(objs, 'AuthorizationPolicy', name)?.spec?.rules ?? []).map((r) => [
      r.from?.[0]?.source?.principals,
      r.to?.[0]?.operation?.ports,
    ]);
  eq(
    principals('api-require-waypoint'),
    [
      [['cluster.local/ns/dx01v2/sa/dx01v2-waypoint'], ['3000', '9464']],
      [['cluster.local/ns/monitoring/sa/kube-prometheus-stack-prometheus'], ['9464']],
    ],
    `${overlay}: API ztunnel rejects application pod-IP bypasses and restricts direct Prometheus to metrics`,
  );
  eq(
    find(objs, 'AuthorizationPolicy', 'api')?.spec?.targetRefs,
    [{ group: '', kind: 'Service', name: 'api' }],
    `${overlay}: API L7 policy is attached to the waypoint-handled Service`,
  );
  eq(
    principals('api'),
    [
      [['cluster.local/ns/dx01v2/sa/web', 'cluster.local/ns/dx01v2/sa/dx01v2-istio'], ['3000']],
      [['cluster.local/ns/monitoring/sa/kube-prometheus-stack-prometheus'], ['9464']],
      [['cluster.local/ns/monitoring/sa/opentelemetry-collector'], ['3000']],
    ],
    `${overlay}: API L7 identities and operations`,
  );
  eq(
    find(objs, 'AuthorizationPolicy', 'api')?.spec?.rules?.[2]?.to?.[0]?.operation?.paths,
    ['/readyz'],
    `${overlay}: Collector can use only API readiness from its health check`,
  );
  eq(
    principals('web-require-waypoint'),
    [[['cluster.local/ns/dx01v2/sa/dx01v2-waypoint'], ['8080']]],
    `${overlay}: web ztunnel accepts traffic from the waypoint only`,
  );
  eq(
    find(objs, 'AuthorizationPolicy', 'web')?.spec?.targetRefs,
    [{ group: '', kind: 'Service', name: 'web' }],
    `${overlay}: web L7 policy is attached to its Service`,
  );
  eq(
    principals('web'),
    [
      [['cluster.local/ns/dx01v2/sa/dx01v2-istio'], ['8080']],
      [['cluster.local/ns/monitoring/sa/opentelemetry-collector'], ['8080']],
    ],
    `${overlay}: AuthorizationPolicy web`,
  );
  eq(
    find(objs, 'AuthorizationPolicy', 'web')?.spec?.rules?.[1]?.to?.[0]?.operation,
    { ports: ['8080'], methods: ['GET'], paths: ['/healthz'] },
    `${overlay}: Collector has only the synthetic web health operation`,
  );
  eq(
    find(objs, 'NetworkPolicy', 'api-metrics-mesh')?.spec?.ingress?.[0],
    {
      from: [
        {
          namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'monitoring' } },
          podSelector: { matchLabels: { 'app.kubernetes.io/name': 'prometheus' } },
        },
      ],
      ports: [{ protocol: 'TCP', port: 15008 }],
    },
    `${overlay}: only Prometheus gets the direct authenticated metrics transport`,
  );

  eq(
    find(objs, 'NetworkPolicy', 'gateway-ingress-from-load-balancer')?.spec?.ingress?.[0]?.from?.[0]?.ipBlock?.cidr,
    params.NETWORK_CIDR,
    `${overlay}: Gateway ingress only from the lab network`,
  );
  eq(
    find(objs, 'NetworkPolicy', 'api-egress-to-db')?.spec?.egress?.[0],
    { to: [{ ipBlock: { cidr: params.DB_ENDPOINT_CIDR } }], ports: [{ protocol: 'TCP', port: 5432 }] },
    `${overlay}: api -> database only`,
  );
  const gatewayAppEgress = (find(objs, 'NetworkPolicy', 'gateway-egress')?.spec?.egress ?? []).filter((rule) =>
    (rule.to ?? []).some(
      (peer) => peer.podSelector?.matchLabels?.['gateway.networking.k8s.io/gateway-name'] === 'dx01v2-waypoint',
    ),
  );
  eq(
    gatewayAppEgress,
    [
      {
        to: [{ podSelector: { matchLabels: { 'gateway.networking.k8s.io/gateway-name': 'dx01v2-waypoint' } } }],
        ports: [{ protocol: 'TCP', port: 15008 }],
      },
    ],
    `${overlay}: ingress Gateway reaches only the waypoint for app traffic`,
  );
  // Local contract v2: the OTLP endpoint and the paths of the spans (API and Gateway, both over the mesh).
  eq(
    config.OTEL_EXPORTER_OTLP_ENDPOINT,
    'http://opentelemetry-collector.monitoring.svc:4318',
    `${overlay}: OTLP endpoint of the local contract`,
  );
  const collector = {
    namespaceSelector: { matchLabels: { 'kubernetes.io/metadata.name': 'monitoring' } },
    podSelector: { matchLabels: { 'app.kubernetes.io/name': 'opentelemetry-collector' } },
  };
  eq(
    find(objs, 'NetworkPolicy', 'api-egress-to-collector')?.spec?.egress,
    [
      {
        to: [collector],
        ports: [
          { protocol: 'TCP', port: 4318 },
          { protocol: 'TCP', port: 15008 },
        ],
      },
    ],
    `${overlay}: api -> OpenTelemetry Collector (OTLP/HTTP over HBONE) only`,
  );
  // Every Gateway egress rule that names the Collector: exactly one, OTLP/gRPC (4317) over HBONE (15008).
  eq(
    (find(objs, 'NetworkPolicy', 'gateway-egress')?.spec?.egress ?? []).filter((r) =>
      (r.to ?? []).some((peer) => JSON.stringify(canonical(peer)) === JSON.stringify(canonical(collector))),
    ),
    [
      {
        to: [collector],
        ports: [
          { protocol: 'TCP', port: 4317 },
          { protocol: 'TCP', port: 15008 },
        ],
      },
    ],
    `${overlay}: the Gateway must reach the OpenTelemetry Collector on 4317 over HBONE (its spans) and only there`,
  );
  for (const name of ['api-ingress-mesh', 'web-ingress-mesh']) {
    const rules = find(objs, 'NetworkPolicy', name)?.spec?.ingress ?? [];
    check(
      rules.some((r) => (r.ports ?? []).some((p) => p.port === 15008)),
      `${overlay}: ${name} must allow HBONE (15008)`,
    );
    check(
      rules.some((r) => r.from?.[0]?.ipBlock?.cidr === '169.254.7.127/32'),
      `${overlay}: ${name} must allow the ambient kubelet probes (169.254.7.127/32)`,
    );
  }
  for (const name of ['api-ingress-mesh', 'web-ingress-mesh']) {
    const rules = find(objs, 'NetworkPolicy', name)?.spec?.ingress ?? [];
    const waypointRule = rules.find((r) => (r.ports ?? []).some((p) => p.port === 15008));
    eq(
      waypointRule?.from?.[0]?.podSelector?.matchLabels,
      { 'gateway.networking.k8s.io/gateway-name': 'dx01v2-waypoint' },
      `${overlay}: ${name} accepts HBONE from the waypoint only`,
    );
  }
  eq(
    find(objs, 'ServiceMonitor', 'api')?.spec?.endpoints?.[0]?.port,
    'metrics',
    `${overlay}: ServiceMonitor scrapes the metrics port`,
  );
  eq(
    (find(objs, 'PrometheusRule', 'dx01v2')?.spec?.groups?.[0]?.rules ?? []).map((r) => r.alert),
    ['Dx01v2ApiDown', 'Dx01v2HighErrorRate', 'Dx01v2HighLatencyP95', 'Dx01v2PodRestarting', 'Dx01v2PodNotReady'],
    `${overlay}: alert rules`,
  );
  eq(
    find(objs, 'ConfigMap', 'dx01v2-dashboard')?.metadata?.labels?.grafana_dashboard,
    '1',
    `${overlay}: dashboard ConfigMap for the Grafana sidecar`,
  );
  const hpa = find(objs, 'HorizontalPodAutoscaler', 'api')?.spec;
  eq([hpa?.minReplicas, hpa?.maxReplicas], [2, 4], `${overlay}: HPA`);
}

const { params, files, localParams } = parseArgs(process.argv.slice(2));
for (const [overlay, file] of Object.entries(files)) {
  const objs = load(file);
  commonChecks(overlay, objs);
  if (overlay === 'local') {
    localChecks(objs);
  } else if (['aws', 'aws-https', 'aws-full', 'aws-https-full'].includes(overlay)) {
    awsChecks(overlay, objs, params, overlay.startsWith('aws-https'));
  } else if (overlay === 'local-platform') {
    check(localParams !== undefined, 'local-platform needs --local-params');
    if (localParams !== undefined) {
      localPlatformChecks(objs, localParams);
    }
  } else {
    failures.push(`unknown overlay ${overlay}`);
  }
}

if (failures.length > 0) {
  console.log(failures.map((f) => `FAIL ${f}`).join('\n'));
  console.log(`${failures.length} of ${assertions} assertions failed`);
  process.exit(1);
}
console.log(
  `SUMMARY: contract and hardening checks: ${assertions} assertions passed (${Object.keys(files).join(', ')})`,
);
