const maximumTitleLength = 96
const maximumDescriptionLength = 200
const artifactPreviewPath = /^\/v1\/artifacts\/[A-Za-z0-9-]{1,160}\/files\/preview\.png$/

function safeHTTPSOrigin(rawValue) {
  try {
    const value = new URL(rawValue)
    if (
      value.protocol !== 'https:' || !value.hostname || value.username || value.password ||
      value.pathname !== '/' || value.search || value.hash
    ) {
      return undefined
    }
    return value.origin
  } catch {
    return undefined
  }
}

function safeCanonicalPublicWorkURL(rawValue) {
  try {
    const value = new URL(rawValue)
    const parts = value.pathname.split('/').filter(Boolean)
    if (
      value.protocol !== 'https:' || !value.hostname || value.username || value.password ||
      value.search || value.hash || parts.length !== 2 || parts[0] !== 'a' || !parts[1]
    ) {
      return undefined
    }
    return value.toString()
  } catch {
    return undefined
  }
}

function compactText(value, maximumLength) {
  if (typeof value !== 'string') return ''
  const compacted = value.replace(/\s+/g, ' ').trim()
  const characters = Array.from(compacted)
  if (characters.length <= maximumLength) return compacted
  return `${characters.slice(0, maximumLength - 1).join('')}…`
}

function escapeHTML(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;')
}

function escapedMeta(name, content, attribute = 'name') {
  return `<meta ${attribute}="${escapeHTML(name)}" content="${escapeHTML(content)}" />`
}

function isEligiblePublicWork(work) {
  return Boolean(
    work &&
    work.status === 'published' &&
    work.verificationGrade === 'verified' &&
    work.contentReviewStatus === 'approved' &&
    work.ageRating === '4+' &&
    compactText(work.title, maximumTitleLength) &&
    compactText(work.creator, maximumTitleLength)
  )
}

// The API derives preview URLs only from its renderer-owned, current immutable
// artifact. The edge repeats a narrow path check before turning that relative
// value into an absolute social-card image URL.
export function resolvePublicArtifactPreviewURL(rawValue, apiOrigin) {
  const trustedAPIOrigin = safeHTTPSOrigin(apiOrigin)
  if (!trustedAPIOrigin || typeof rawValue !== 'string' || !rawValue.startsWith('/')) return undefined
  try {
    const value = new URL(rawValue, trustedAPIOrigin)
    if (
      value.origin !== trustedAPIOrigin || value.search || value.hash ||
      !artifactPreviewPath.test(value.pathname)
    ) {
      return undefined
    }
    return value.toString()
  } catch {
    return undefined
  }
}

// Renders metadata for a public work only. It deliberately ignores every
// unlisted API field, preventing a future private work field from becoming a
// crawler-visible tag merely because it was present in a JSON response.
export function renderPublicWorkOpenGraph(work, { apiOrigin, canonicalURL } = {}) {
  if (!isEligiblePublicWork(work)) return undefined
  const canonical = safeCanonicalPublicWorkURL(canonicalURL)
  if (!canonical) return undefined

  const title = compactText(work.title, maximumTitleLength)
  const creator = compactText(work.creator, maximumTitleLength)
  const originalCreator = compactText(work.originalCreator, maximumTitleLength)
  const description = compactText(work.prompt, maximumDescriptionLength) || `Play this interactive work by @${creator} on Pulse.`
  const sharingTitle = `${title} · Pulse`
  const previewURL = resolvePublicArtifactPreviewURL(work.artifactPreviewUrl, apiOrigin)
  const isRemix = work.creationMode === 'remix' && originalCreator
  const attribution = isRemix
    ? `Created by @${creator}, a Remix of @${originalCreator}.`
    : `Created by @${creator}.`
  const imageMetadata = previewURL
    ? [
        escapedMeta('og:image', previewURL, 'property'),
        escapedMeta('og:image:secure_url', previewURL, 'property'),
        escapedMeta('og:image:type', 'image/png', 'property'),
        escapedMeta('og:image:width', '390', 'property'),
        escapedMeta('og:image:height', '390', 'property'),
        escapedMeta('og:image:alt', `${title}, an interactive work by @${creator}`, 'property'),
        escapedMeta('twitter:card', 'summary_large_image'),
        escapedMeta('twitter:image', previewURL),
        escapedMeta('twitter:image:alt', `${title}, an interactive work by @${creator}`)
      ]
    : [escapedMeta('twitter:card', 'summary')]
  const provenanceMetadata = isRemix
    ? [
        escapedMeta('pulse:creation_mode', 'remix'),
        escapedMeta('pulse:original_creator', `@${originalCreator}`)
      ]
    : [escapedMeta('pulse:creation_mode', 'original')]

  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>${escapeHTML(sharingTitle)}</title>
    ${escapedMeta('description', description)}
    <link rel="canonical" href="${escapeHTML(canonical)}" />
    ${escapedMeta('og:type', 'website', 'property')}
    ${escapedMeta('og:site_name', 'Pulse', 'property')}
    ${escapedMeta('og:title', sharingTitle, 'property')}
    ${escapedMeta('og:description', description, 'property')}
    ${escapedMeta('og:url', canonical, 'property')}
    ${imageMetadata.join('\n    ')}
    ${escapedMeta('twitter:title', sharingTitle)}
    ${escapedMeta('twitter:description', description)}
    ${escapedMeta('author', `@${creator}`)}
    ${escapedMeta('dc.creator', `@${creator}`)}
    ${escapedMeta('dc.rights', `Creator attribution: @${creator}. Published via Pulse.`)}
    ${provenanceMetadata.join('\n    ')}
  </head>
  <body>
    <main>
      <h1>Pulse</h1>
      <p>${escapeHTML(attribution)}</p>
    </main>
  </body>
</html>`
}
