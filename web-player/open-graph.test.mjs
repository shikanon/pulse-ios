import assert from 'node:assert/strict'
import test from 'node:test'

import { renderPublicWorkOpenGraph, resolvePublicArtifactPreviewURL } from './open-graph.mjs'

const publicWork = {
  id: 'work-public',
  title: 'Orbit <b>Garden</b>',
  creator: 'ada & bob',
  prompt: 'Guide a tiny comet through a glowing garden.',
  creationMode: 'remix',
  originalCreator: 'original creator',
  status: 'published',
  verificationGrade: 'verified',
  contentReviewStatus: 'approved',
  ageRating: '4+',
  artifactPreviewUrl: '/v1/artifacts/artifact-preview/files/preview.png',
  generationJobId: 'private-job-must-not-appear',
  contentPolicyVersion: 'private-policy-must-not-appear'
}

test('renders escaped, server-derived Open Graph metadata for an eligible work only', () => {
  const html = renderPublicWorkOpenGraph(publicWork, {
    apiOrigin: 'https://api.pulse.test',
    canonicalURL: 'https://play.pulse.test/a/share-preview'
  })

  assert.match(html, /<meta property="og:title" content="Orbit &lt;b&gt;Garden&lt;\/b&gt; · Pulse" \/>/)
  assert.match(html, /<meta property="og:image" content="https:\/\/api\.pulse\.test\/v1\/artifacts\/artifact-preview\/files\/preview\.png" \/>/)
  assert.match(html, /<meta name="dc\.creator" content="@ada &amp; bob" \/>/)
  assert.match(html, /<meta name="pulse:original_creator" content="@original creator" \/>/)
  assert.match(html, /<link rel="canonical" href="https:\/\/play\.pulse\.test\/a\/share-preview" \/>/)
  assert.doesNotMatch(html, /private-job-must-not-appear|private-policy-must-not-appear/)
  assert.doesNotMatch(html, /<b>Garden<\/b>/)
})
test('does not create a social card for a work that is not public-release eligible', () => {
  assert.equal(renderPublicWorkOpenGraph({ ...publicWork, ageRating: '13+' }, {
    apiOrigin: 'https://api.pulse.test',
    canonicalURL: 'https://play.pulse.test/a/share-preview'
  }), undefined)
})

test('allows only the fixed renderer preview path on the configured API origin', () => {
  assert.equal(
    resolvePublicArtifactPreviewURL('/v1/artifacts/artifact-preview/files/preview.png', 'https://api.pulse.test'),
    'https://api.pulse.test/v1/artifacts/artifact-preview/files/preview.png'
  )
  for (const value of [
    'https://attacker.test/preview.png',
    '/v1/artifacts/artifact-preview/files/index.html',
    '/v1/artifacts/artifact-preview/files/preview.png?token=leak',
    '/v1/artifacts/artifact-preview/files/nested/preview.png'
  ]) {
    assert.equal(resolvePublicArtifactPreviewURL(value, 'https://api.pulse.test'), undefined)
  }
})
