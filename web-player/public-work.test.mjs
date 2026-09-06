import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'
import { isEligiblePublishedWork } from './publication-policy.mjs'

const player = await readFile(new URL('./index.html', import.meta.url), 'utf8')

test('public work exposes a clear, server-derived age rating only after public review gates', () => {
  assert.match(player, /id="age-rating">Age rating: 4\+<\/span>/)
  assert.match(player, /id="review-copy">Reviewed for public sharing<\/span>/)
  assert.match(player, /!isEligiblePublishedWork\(work\)/)
  assert.match(player, /reviewStatus\.hidden = work\.contentReviewStatus !== 'approved'/)
  assert.match(player, /ageRating\.textContent = `Age rating: \$\{work\.ageRating\}`/)
  assert.match(player, /reviewStatus\.setAttribute\('aria-label', `Age rating: \$\{work\.ageRating\}\. Reviewed for public sharing\.`\)/)
})

test('public work age label does not accept arbitrary page data as an API origin', () => {
  assert.match(player, /resolvePublicAPIOrigin\(import\.meta\.env\.VITE_PULSE_API_ORIGIN, import\.meta\.env\.DEV\)/)
  assert.doesNotMatch(player, /query\.get\('api(?:Origin)?'\)/)
})

test('current immediate publication is playable without falsely claiming review approval', () => {
 const pending={status:'published',verificationGrade:'verified',contentReviewStatus:'pending',ageRating:'unrated'}
 assert.equal(isEligiblePublishedWork(pending),true)
 for(const change of [{status:'hidden'},{status:'draft'},{verificationGrade:'fallback'},{contentReviewStatus:'rejected'},{contentReviewStatus:'approved',ageRating:'13+'}])assert.equal(isEligiblePublishedWork({...pending,...change}),false)
 assert.equal(isEligiblePublishedWork({...pending,contentReviewStatus:'approved',ageRating:'4+'}),true)
})
