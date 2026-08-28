import test from 'node:test'
import assert from 'node:assert/strict'
import { resolvePublicAPIOrigin } from './config.mjs'

test('uses a loopback API only as the explicit development fallback', () => {
  assert.equal(resolvePublicAPIOrigin(undefined, true), 'http://localhost:8787')
  assert.equal(resolvePublicAPIOrigin(undefined, false), undefined)
  assert.equal(resolvePublicAPIOrigin('http://localhost:8787', false), undefined)
})

test('requires a clean non-placeholder HTTPS origin for public production', () => {
  assert.equal(resolvePublicAPIOrigin('https://api.pulse.example', false), undefined)
  assert.equal(resolvePublicAPIOrigin('https://api.pulse.invalid', false), undefined)
  assert.equal(resolvePublicAPIOrigin('https://operator:secret@api.pulse.test', false), undefined)
  assert.equal(resolvePublicAPIOrigin('https://api.pulse.test/v1', false), undefined)
  assert.equal(resolvePublicAPIOrigin('https://api.pulse.test?debug=1', false), undefined)
  assert.equal(resolvePublicAPIOrigin('https://api.pulse.test', false), 'https://api.pulse.test')
})
