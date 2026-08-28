import assert from 'node:assert/strict'
import test from 'node:test'

import { createOpenGraphEdgeHandler, isSocialPreviewCrawler } from './edge-worker.mjs'

const publishedWork = {
  id: 'work-public',
  title: 'Garden Runner',
  creator: 'ada',
  prompt: 'Run through an interactive garden.',
  creationMode: 'original',
  originalCreator: 'ada',
  status: 'published',
  verificationGrade: 'verified',
  contentReviewStatus: 'approved',
  ageRating: '4+',
  artifactPreviewUrl: '/v1/artifacts/artifact-preview/files/preview.png',
  generationJobId: 'not-public'
}

function createHandler(fetchImplementation) {
  return createOpenGraphEdgeHandler({
    apiOrigin: 'https://api.pulse.test',
    publicPlayerOrigin: 'https://play.pulse.test',
    fetchImplementation,
    staticAssetFetcher: async () => new Response('static-player')
  })
}

test('keeps normal browser requests on the static Web Player', async () => {
  const handler = createHandler(async () => assert.fail('browser must not fetch the public work for metadata'))
  const response = await handler(new Request('https://play.pulse.test/a/share-preview', { headers: { 'User-Agent': 'Mozilla/5.0' } }))
  assert.equal(await response.text(), 'static-player')
})
test('serves a no-store dynamic social card to a known crawler without private fields', async () => {
  let requestedURL
  const handler = createHandler(async url => {
    requestedURL = String(url)
    return new Response(JSON.stringify({ work: publishedWork }), { status: 200 })
  })
  const response = await handler(new Request('https://play.pulse.test/a/share-preview?source=chat', { headers: { 'User-Agent': 'Slackbot-LinkExpanding 1.0' } }))
  const html = await response.text()

  assert.equal(response.status, 200)
  assert.equal(requestedURL, 'https://api.pulse.test/v1/public/works/share-preview')
  assert.equal(response.headers.get('Cache-Control'), 'private, no-store')
  assert.equal(response.headers.get('Vary'), 'User-Agent')
  assert.match(html, /<meta property="og:url" content="https:\/\/play\.pulse\.test\/a\/share-preview" \/>/)
  assert.match(html, /<meta property="og:image" content="https:\/\/api\.pulse\.test\/v1\/artifacts\/artifact-preview\/files\/preview\.png" \/>/)
  assert.doesNotMatch(html, /not-public/)
})

test('returns a non-indexable unavailable page after a withdrawn public response', async () => {
  const handler = createHandler(async () => new Response('', { status: 404 }))
  const response = await handler(new Request('https://play.pulse.test/a/withdrawn', { headers: { 'User-Agent': 'Twitterbot/1.0' } }))
  const html = await response.text()

  assert.equal(response.status, 404)
  assert.match(html, /noindex,nofollow/)
  assert.doesNotMatch(html, /og:title|og:image/)
})

test('identifies the preview agents explicitly instead of treating every visitor as a crawler', () => {
  assert.equal(isSocialPreviewCrawler(new Request('https://play.pulse.test/a/work', { headers: { 'User-Agent': 'Discordbot/2.0' } })), true)
  assert.equal(isSocialPreviewCrawler(new Request('https://play.pulse.test/a/work', { headers: { 'User-Agent': 'Mozilla/5.0' } })), false)
})
