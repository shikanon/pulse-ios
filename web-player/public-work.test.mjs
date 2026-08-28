import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'

const player = await readFile(new URL('./index.html', import.meta.url), 'utf8')

test('public work exposes a clear, server-derived age rating only after public review gates', () => {
  assert.match(player, /id="age-rating">Age rating: 4\+<\/span>/)
  assert.match(player, /id="review-copy">Reviewed for public sharing<\/span>/)
  assert.match(player, /work\.contentReviewStatus !== 'approved' \|\| work\.ageRating !== '4\+'/)
  assert.match(player, /ageRating\.textContent = `Age rating: \$\{work\.ageRating\}`/)
  assert.match(player, /reviewStatus\.setAttribute\('aria-label', `Age rating: \$\{work\.ageRating\}\. Reviewed for public sharing\.`\)/)
})

test('public work age label does not accept arbitrary page data as an API origin', () => {
  assert.match(player, /resolvePublicAPIOrigin\(import\.meta\.env\.VITE_PULSE_API_ORIGIN, import\.meta\.env\.DEV\)/)
  assert.doesNotMatch(player, /query\.get\('api(?:Origin)?'\)/)
})
