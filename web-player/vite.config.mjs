import { defineConfig, loadEnv } from 'vite'

import {
  associatedDomainsFileName,
  renderAppleAppSiteAssociation,
  resolveAssociatedDomainsConfiguration
} from './associated-domains.mjs'
import { resolvePublicAPIOrigin } from './config.mjs'
import { injectPublicPlayerContentSecurityPolicy } from './security-policy.mjs'

export default defineConfig(({ mode }) => {
  const isDevelopment = mode === 'development'
  const environment = loadEnv(mode, process.cwd(), '')
  const apiOrigin = resolvePublicAPIOrigin(environment.VITE_PULSE_API_ORIGIN, isDevelopment)
  const associatedDomains = resolveAssociatedDomainsConfiguration({
    teamID: environment.PULSE_APPLE_TEAM_ID,
    bundleID: environment.PULSE_IOS_BUNDLE_ID,
    universalLinkHost: environment.PULSE_UNIVERSAL_LINK_HOST,
    required: environment.PULSE_RELEASE_BUILD === '1'
  })

  return {
    plugins: [
      {
        name: 'pulse-public-player-csp',
        transformIndexHtml(html) {
          return injectPublicPlayerContentSecurityPolicy(html, apiOrigin, { allowInlineScript: isDevelopment })
        }
      },
      {
        name: 'pulse-associated-domains-file',
        generateBundle() {
          if (!associatedDomains) return
          this.emitFile({
            type: 'asset',
            fileName: associatedDomainsFileName,
            source: renderAppleAppSiteAssociation(associatedDomains)
          })
        }
      }
    ]
  }
})
