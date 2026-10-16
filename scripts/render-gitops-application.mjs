#!/usr/bin/env node
// Render only the cloud-specific Kustomize settings kept on the in-cluster Argo CD Application.
// The public GitOps branch contains the source commit and harmless example params; real account
// identifiers stay in the Application object and never enter Git.
import fs from 'node:fs';

function fail(message) {
  console.error(message);
  process.exit(2);
}

function readEnv(file) {
  const result = Object.create(null);
  for (const [index, raw] of fs.readFileSync(file, 'utf8').split(/\r?\n/).entries()) {
    const line = raw.trim();
    if (line === '' || line.startsWith('#')) continue;
    const split = line.indexOf('=');
    if (split < 1) fail(`${file}:${index + 1}: expected KEY=VALUE`);
    const key = line.slice(0, split);
    const value = line.slice(split + 1);
    if (!/^[A-Z][A-Z0-9_]*$/.test(key) || Object.hasOwn(result, key)) {
      fail(`${file}:${index + 1}: invalid or duplicate key ${key}`);
    }
    if (/[\r\n\t]/.test(value)) fail(`${file}:${index + 1}: ${key} must be a single line`);
    result[key] = value;
  }
  return result;
}

function required(params, key) {
  if (typeof params[key] !== 'string' || params[key] === '') fail(`missing ${key}`);
  return params[key];
}

function image(value, key) {
  const colon = value.lastIndexOf(':');
  if (colon <= value.lastIndexOf('/') || !/^[0-9a-f]{40}$/.test(value.slice(colon + 1))) {
    fail(`${key} must end in a full source commit SHA tag`);
  }
  return { name: value.slice(0, colon), tag: value.slice(colon + 1) };
}

const [cloud, overlay, actualFile, exampleFile] = process.argv.slice(2);
if (!['aws'].includes(cloud) || !['aws', 'aws-https'].includes(overlay) || !actualFile || !exampleFile) {
  fail('usage: render-gitops-application.mjs aws <aws|aws-https> <actual params.env> <params.example.env>');
}

const actual = readEnv(actualFile);
const example = readEnv(exampleFile);
const api = image(required(actual, 'API_IMAGE'), 'API_IMAGE');
const web = image(required(actual, 'WEB_IMAGE'), 'WEB_IMAGE');
const apiExample = image(required(example, 'API_IMAGE'), 'example API_IMAGE');
const webExample = image(required(example, 'WEB_IMAGE'), 'example WEB_IMAGE');
const patches = [];
const addPatch = (kind, name, path, value) => {
  patches.push({
    target: { kind, name },
    patch: JSON.stringify([{ op: 'replace', path, value }]),
  });
};

addPatch('Ingress', 'dx01v2', '/metadata/annotations/alb.ingress.kubernetes.io~1wafv2-acl-arn', required(actual, 'WAF_ACL_ARN'));
for (const [name, cidrPath] of [
  ['web-ingress-from-alb', '/spec/ingress/0/from/0/ipBlock/cidr'],
  ['api-ingress-from-alb', '/spec/ingress/0/from/0/ipBlock/cidr'],
  ['api-egress-to-rds', '/spec/egress/0/to/0/ipBlock/cidr'],
]) {
  addPatch('NetworkPolicy', name, cidrPath, required(actual, 'VPC_CIDR'));
}
if (overlay === 'aws-https') {
  addPatch('Ingress', 'dx01v2', '/metadata/annotations/alb.ingress.kubernetes.io~1certificate-arn', required(actual, 'ALB_CERTIFICATE_ARN'));
}

const document = {
  spec: {
    source: {
      path: `deploy/k8s/overlays/${overlay}`,
      kustomize: {
        images: [
          `${apiExample.name}=${api.name}:${api.tag}`,
          `${webExample.name}=${web.name}:${web.tag}`,
        ],
        patches,
      },
    },
  },
};
process.stdout.write(`${JSON.stringify(document, null, 2)}\n`);
