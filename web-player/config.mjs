const localDevelopmentAPIOrigin = 'http://localhost:8787'

/**
 * Resolves the public API origin used by the browser player. Production must
 * never inherit a development fallback: a malformed value leaves the player
 * in its existing safe configuration error state instead of sending public
 * requests to an arbitrary or credential-bearing origin.
 */
export function resolvePublicAPIOrigin(rawValue, isDevelopment) {
  const configuredValue = rawValue?.trim() || (isDevelopment ? localDevelopmentAPIOrigin : undefined)
  if (!configuredValue) return undefined

  try {
    const value = new URL(configuredValue)
    const host = value.hostname.toLowerCase()
    const isLoopback = host === 'localhost' || host === '127.0.0.1' || host === '::1'
    const isPlaceholderHost = host.endsWith('.example') || host.endsWith('.invalid')
    if (
      (value.protocol !== 'https:' && value.protocol !== 'http:') ||
      value.username || value.password || value.pathname !== '/' || value.search || value.hash ||
      (!isDevelopment && (value.protocol !== 'https:' || isLoopback || isPlaceholderHost)) ||
      (value.protocol === 'http:' && !isLoopback)
    ) {
      return undefined
    }
    return value.origin
  } catch {
    return undefined
  }
}
