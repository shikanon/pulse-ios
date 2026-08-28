import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'

import {
  injectPublicPlayerContentSecurityPolicy,
  publicPlayerContentSecurityPolicy
} from './security-policy.mjs'

test('public Player CSP grants network and iframe access only to its configured API origin', () => {
  const policy = publicPlayerContentSecurityPolicy('https://api.pulse.test')

  assert.match(policy, /connect-src https:\/\/api\.pulse\.test/)
  assert.match(policy, /frame-src https:\/\/api\.pulse\.test/)
  assert.match(policy, /default-src 'self'/)
  assert.match(policy, /base-uri 'none'/)
  assert.match(policy, /object-src 'none'/)
  assert.match(policy, /form-action 'none'/)
  assert.match(policy, /frame-ancestors 'none'/)
  assert.match(policy, /worker-src 'none'/)
  assert.match(policy, /script-src 'self';/)
  assert.doesNotMatch(policy, /script-src 'self' 'unsafe-inline'/)
  assert.doesNotMatch(policy, /connect-src https:;|frame-src https:;|\*/)
})

test('published Artifacts have only script execution and no ambient browser or device privileges', async () => {
  const html = await readFile(new URL('./index.html', import.meta.url), 'utf8')
  const artifact = html.match(/<iframe id="artifact"[^>]*>/)?.[0]

  assert.ok(artifact, 'the public Artifact host must be an iframe')
  assert.match(artifact, /sandbox="allow-scripts"/)
  assert.match(artifact, /referrerpolicy="no-referrer"/)
  assert.match(artifact, /allow="camera 'none'; microphone 'none'; geolocation 'none'; display-capture 'none'; fullscreen 'none'; payment 'none'; usb 'none'; clipboard-read 'none'; clipboard-write 'none'"/)
  for (const forbiddenPrivilege of [
    'allow-same-origin',
    'allow-forms',
    'allow-popups',
    'allow-downloads',
    'allow-modals',
    'allow-top-navigation',
    'allow-top-navigation-by-user-activation',
    'allow-presentation',
    'allow-pointer-lock'
  ]) {
    assert.doesNotMatch(artifact, new RegExp(forbiddenPrivilege))
  }
})

test('development may allow Vite inline modules without changing production CSP defaults', () => {
  const policy = publicPlayerContentSecurityPolicy('http://localhost:8787', { allowInlineScript: true })

  assert.match(policy, /script-src 'self' 'unsafe-inline'/)
  assert.match(policy, /connect-src http:\/\/localhost:8787/)
})

test('missing or malformed origins fail closed to the unreachable configuration origin', () => {
  for (const origin of [undefined, 'https://api.pulse.test/path', 'https://user@api.pulse.test', 'not a URL']) {
    const policy = publicPlayerContentSecurityPolicy(origin)
    assert.match(policy, /connect-src https:\/\/configure-api\.invalid/)
    assert.match(policy, /frame-src https:\/\/configure-api\.invalid/)
  }
})

test('the Player HTML reserves its CSP for Vite build-time injection', async () => {
  const html = await readFile(new URL('./index.html', import.meta.url), 'utf8')
  const transformed = injectPublicPlayerContentSecurityPolicy(html, 'https://api.pulse.test')

  assert.match(html, /http-equiv="Content-Security-Policy" content="__PULSE_PUBLIC_PLAYER_CSP__"/)
  assert.doesNotMatch(transformed, /__PULSE_PUBLIC_PLAYER_CSP__/)
  assert.match(transformed, /connect-src https:\/\/api\.pulse\.test/)
})
