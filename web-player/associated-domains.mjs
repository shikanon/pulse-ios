import { isIP } from 'node:net'

export const associatedDomainsFileName = '.well-known/apple-app-site-association'

/**
 * Validates the values that bind the public player, the iOS entitlement, and
 * Apple's associated-domain file. The file must never be emitted with a
 * placeholder domain or an invented application identifier: doing so makes a
 * deployment look release-ready while Universal Links cannot work.
 */
export function resolveAssociatedDomainsConfiguration({ teamID, bundleID, universalLinkHost, required = false }) {
  const supplied = [teamID, bundleID, universalLinkHost].some(value => value?.trim())
  if (!supplied && !required) return undefined

  const prefix = teamID?.trim()
  const bundle = bundleID?.trim()
  const host = normalizedUniversalLinkHost(universalLinkHost)
  if (!/^[A-Z0-9]{10}$/.test(prefix || '')) {
    throw new Error('PULSE_APPLE_TEAM_ID must be the 10-character uppercase Apple Team ID.')
  }
  if (!/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/.test(bundle || '')) {
    throw new Error('PULSE_IOS_BUNDLE_ID must be a reverse-DNS bundle identifier.')
  }
  if (!host) {
    throw new Error('PULSE_UNIVERSAL_LINK_HOST must be a public HTTPS host without a port or path.')
  }
  return { appID: `${prefix}.${bundle}`, host }
}

export function renderAppleAppSiteAssociation(configuration) {
  if (!configuration?.appID || !configuration?.host) {
    throw new Error('A validated associated-domain configuration is required.')
  }
  return `${JSON.stringify({
    applinks: {
      details: [{
        appIDs: [configuration.appID],
        components: [
          { '/': '/a/*' },
          { '/': '/remix/*' }
        ]
      }]
    }
  }, null, 2)}\n`
}

function normalizedUniversalLinkHost(rawValue) {
  const candidate = rawValue?.trim()
  if (!candidate || /[/?#@]/.test(candidate)) return undefined
  try {
    const value = new URL(`https://${candidate}`)
    const host = value.hostname.toLowerCase().replace(/^\[|\]$/g, '')
    const isLoopback = host === 'localhost' || host === '::1' || host.endsWith('.localhost')
    const isPlaceholder = host.endsWith('.example') || host.endsWith('.invalid')
    if (
      !host || value.port || value.pathname !== '/' || value.search || value.hash || value.username || value.password ||
      isIP(host) !== 0 || isLoopback || isPlaceholder
    ) {
      return undefined
    }
    return host
  } catch {
    return undefined
  }
}
