import test from 'node:test'
import assert from 'node:assert/strict'
import {
  associatedDomainsFileName,
  renderAppleAppSiteAssociation,
  resolveAssociatedDomainsConfiguration
} from './associated-domains.mjs'

test('does not emit an association file outside an explicit release configuration', () => {
  assert.equal(resolveAssociatedDomainsConfiguration({}), undefined)
  assert.throws(
    () => resolveAssociatedDomainsConfiguration({ required: true }),
    /PULSE_APPLE_TEAM_ID/
  )
})

test('requires one public host and the exact iOS application identifier', () => {
  const configuration = resolveAssociatedDomainsConfiguration({
    teamID: 'ABCDE12345',
    bundleID: 'com.shikanon.pulse',
    universalLinkHost: 'PLAY.PULSE.TEST'
  })
  assert.deepEqual(configuration, {
    appID: 'ABCDE12345.com.shikanon.pulse',
    host: 'play.pulse.test'
  })
  for (const universalLinkHost of ['localhost', 'play.pulse.example', 'play.pulse.test/a/work', 'play.pulse.test:8443', '127.0.0.1', '[::1]']) {
    assert.throws(
      () => resolveAssociatedDomainsConfiguration({ teamID: 'ABCDE12345', bundleID: 'com.shikanon.pulse', universalLinkHost }),
      /PULSE_UNIVERSAL_LINK_HOST/
    )
  }
  assert.throws(
    () => resolveAssociatedDomainsConfiguration({ teamID: 'abcde12345', bundleID: 'com.shikanon.pulse', universalLinkHost: 'play.pulse.test' }),
    /PULSE_APPLE_TEAM_ID/
  )
})

test('renders only the public work and Remix paths in the extensionless AASA file', () => {
  const configuration = resolveAssociatedDomainsConfiguration({
    teamID: 'ABCDE12345',
    bundleID: 'com.shikanon.pulse',
    universalLinkHost: 'play.pulse.test'
  })
  assert.equal(associatedDomainsFileName, '.well-known/apple-app-site-association')
  assert.deepEqual(JSON.parse(renderAppleAppSiteAssociation(configuration)), {
    applinks: {
      details: [{
        appIDs: ['ABCDE12345.com.shikanon.pulse'],
        components: [{ '/': '/a/*' }, { '/': '/remix/*' }]
      }]
    }
  })
})
