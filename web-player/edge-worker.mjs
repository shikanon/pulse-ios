import { renderPublicWorkOpenGraph } from './open-graph.mjs'

const socialPreviewUserAgent = /facebookexternalhit|facebot|twitterbot|linkedinbot|slackbot|discordbot|telegrambot|whatsapp|pinterest|embedly|quora link preview|skypeuripreview|googlebot|bingbot|applebot/i

function trustedHTTPSOrigin(rawValue) {
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
function sharedResponse(status, title, detail) {
  return new Response(`<!doctype html><html lang="en"><head><meta charset="utf-8" /><meta name="robots" content="noindex,nofollow" /><title>${title}</title></head><body><main><h1>${title}</h1><p>${detail}</p></main></body></html>`, {
    status,
    headers: secureMetadataHeaders()
  })
}

function secureMetadataHeaders() {
  return {
    'Cache-Control': 'private, no-store',
    'Content-Security-Policy': "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    'Content-Type': 'text/html; charset=utf-8',
    'Referrer-Policy': 'no-referrer',
    'Vary': 'User-Agent',
    'X-Content-Type-Options': 'nosniff'
  }
}

function publicSlug(requestURL) {
  const parts = requestURL.pathname.split('/').filter(Boolean)
  if (parts.length !== 2 || parts[0] !== 'a' || parts[1].length > 160) return undefined
  try {
    const slug = decodeURIComponent(parts[1])
    return slug && !/[\u0000-\u001F\u007F/]/.test(slug) ? slug : undefined
  } catch {
    return undefined
  }
}

export function isSocialPreviewCrawler(request) {
  return socialPreviewUserAgent.test(request.headers.get('User-Agent') || '')
}

// The edge route only renders known social/SEO crawler requests. Every human
// request keeps the Vite player, including its sandboxed Artifact runtime,
// instead of receiving a metadata-only document.
export function createOpenGraphEdgeHandler({ apiOrigin, publicPlayerOrigin, fetchImplementation = fetch, staticAssetFetcher }) {
  if (typeof staticAssetFetcher !== 'function') {
    throw new TypeError('staticAssetFetcher is required to serve the Web Player assets.')
  }
  return async request => {
    if (request.method !== 'GET' || !isSocialPreviewCrawler(request)) {
      return staticAssetFetcher(request)
    }

    const slug = publicSlug(new URL(request.url))
    if (!slug) return staticAssetFetcher(request)

    const trustedAPIOrigin = trustedHTTPSOrigin(apiOrigin)
    const trustedPlayerOrigin = trustedHTTPSOrigin(publicPlayerOrigin)
    if (!trustedAPIOrigin || !trustedPlayerOrigin) {
      return sharedResponse(503, 'Pulse preview is temporarily unavailable', 'Please open this link again in a moment.')
    }

    let response
    try {
      response = await fetchImplementation(new URL(`/v1/public/works/${encodeURIComponent(slug)}`, trustedAPIOrigin), {
        headers: { Accept: 'application/json' },
        method: 'GET',
        redirect: 'error'
      })
    } catch {
      return sharedResponse(503, 'Pulse preview is temporarily unavailable', 'Please open this link again in a moment.')
    }
    if (!response.ok) {
      if ([401, 403, 404, 410].includes(response.status)) {
        return sharedResponse(404, 'This Pulse work is no longer available', 'It may have been removed or is no longer shared publicly.')
      }
      return sharedResponse(503, 'Pulse preview is temporarily unavailable', 'Please open this link again in a moment.')
    }

    let payload
    try {
      payload = await response.json()
    } catch {
      return sharedResponse(503, 'Pulse preview is temporarily unavailable', 'Please open this link again in a moment.')
    }
    const canonicalURL = new URL(`/a/${encodeURIComponent(slug)}`, trustedPlayerOrigin).toString()
    const document = renderPublicWorkOpenGraph(payload?.work, { apiOrigin: trustedAPIOrigin, canonicalURL })
    if (!document) {
      return sharedResponse(404, 'This Pulse work is no longer available', 'It may have been removed or is no longer shared publicly.')
    }
    return new Response(document, { status: 200, headers: secureMetadataHeaders() })
  }
}

// Cloudflare Pages/Workers adapter. Bind the built `dist` directory as ASSETS,
// then configure the two exact HTTPS origins as environment variables. The
// worker handles only crawler HTML; all normal requests fall through to the
// immutable static player assets.
export default {
  fetch(request, environment) {
    const assets = environment.ASSETS?.fetch?.bind(environment.ASSETS)
    if (!assets) {
      return sharedResponse(503, 'Pulse Player is not configured', 'Please return in a little while.')
    }
    return createOpenGraphEdgeHandler({
      apiOrigin: environment.PULSE_API_ORIGIN,
      publicPlayerOrigin: environment.PULSE_PUBLIC_PLAYER_ORIGIN,
      staticAssetFetcher: assets
    })(request)
  }
}
