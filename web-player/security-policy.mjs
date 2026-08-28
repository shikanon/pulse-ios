const safeFallbackAPIOrigin = 'https://configure-api.invalid'

function trustedOrigin(rawOrigin) {
  try {
    const value = new URL(rawOrigin)
    if (
      (value.protocol !== 'https:' && value.protocol !== 'http:') ||
      value.username || value.password || value.pathname !== '/' || value.search || value.hash
    ) {
      return undefined
    }
    return value.origin
  } catch {
    return undefined
  }
}

/**
 * The public Player is static, so its CSP must be compiled from the same
 * trusted API Origin that configures its code. A missing or malformed value
 * deliberately resolves to an unreachable HTTPS origin: the page stays in
 * its configuration state instead of broadening fetch or iframe permissions.
 */
export function publicPlayerContentSecurityPolicy(apiOrigin, { allowInlineScript = false } = {}) {
  const trustedAPIOrigin = trustedOrigin(apiOrigin) || safeFallbackAPIOrigin
  const scriptSource = allowInlineScript ? "'self' 'unsafe-inline'" : "'self'"
  return [
    "default-src 'self'",
    "base-uri 'none'",
    "object-src 'none'",
    "form-action 'none'",
    "frame-ancestors 'none'",
    `script-src ${scriptSource}`,
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data:",
    "font-src 'self' data:",
    "media-src 'none'",
    `connect-src ${trustedAPIOrigin}`,
    `frame-src ${trustedAPIOrigin}`,
    "worker-src 'none'"
  ].join('; ')
}

export function injectPublicPlayerContentSecurityPolicy(html, apiOrigin, options) {
  return html.replace('__PULSE_PUBLIC_PLAYER_CSP__', publicPlayerContentSecurityPolicy(apiOrigin, options))
}
