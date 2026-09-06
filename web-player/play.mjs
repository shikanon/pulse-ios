const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const CONSENT = 'pulse.growth.consent.v1'
const DEVICE = 'pulse.growth.device.v1'
const LIBRARY = 'pulse.play.library.v1'
export function parsePlayMessage(data) {
  if (!data || data.type !== 'pulse:play-v1' || !['protocol', 'interaction', 'qualified', 'complete'].includes(data.name)) return null
  if (data.name === 'complete' && (!Number.isInteger(data.score) || data.score < 0 || data.score > 1e9)) return null
  return data.name === 'complete' ? { name: data.name, score: data.score } : { name: data.name }
}
export function challengeID(search) {
  const values = new URLSearchParams(search).getAll('challenge')
  if (!values.length) return undefined
  if (values.length !== 1 || !ID.test(values[0])) throw new Error('Invalid challenge link')
  return values[0].toLowerCase()
}
function read(key, fallback) { try { return JSON.parse(localStorage.getItem(key)) ?? fallback } catch { return fallback } }
function write(key, value) { try { localStorage.setItem(key, JSON.stringify(value)); return true } catch { return false } }
function identity() {
  const consent = read(CONSENT, false) === true
  if (!consent) return { platform: 'web', deviceId: '', consent: false }
  let deviceId = read(DEVICE, '')
  if (!ID.test(deviceId)) { deviceId = crypto.randomUUID(); if (!write(DEVICE, deviceId)) return { platform: 'web', deviceId: '', consent: false } }
  return { platform: 'web', deviceId, consent: true }
}
function library() {
  const value = read(LIBRARY, [])
  return Array.isArray(value) ? value.filter(row => row && /^[0-9a-f]{1,64}$/i.test(row.slug) && typeof row.title === 'string' && row.title.length <= 200).slice(0,100) : []
}
export function createPlayHost({ apiURL, artifact, status, reload }) {
  let session, work, currentChallenge, challenge, epoch = 0, chain = Promise.resolve()
  const panel = document.querySelector('#play-result')
  const scoreLabel = document.querySelector('#result-score')
  const shareButton = document.querySelector('#share-result')
  const saveButton = document.querySelector('#save-work')
  const consent = document.querySelector('#usage-consent')
  const challengeLabel = document.querySelector('#challenge-target')
  const api = async (path, body, method = 'POST') => {
    const response = await fetch(new URL(`/v1/${path}`, apiURL), { method, credentials: 'omit', headers: { 'Content-Type': 'application/json' }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
    if (!response.ok) { const error = new Error(response.status === 404 ? 'This challenge is no longer available.' : 'Please retry when connected.'); if (response.status === 404) error.code = 'challenge_unavailable'; throw error }
    return response.status === 204 ? undefined : response.json()
  }
  function updateLibrary(recent = false) {
    if (!work) return
    const rows = library(); const old = rows.find(row => row.slug === work.publicSlug)
    const row = { slug: work.publicSlug, title: work.title, saved: recent ? old?.saved === true : !old?.saved, playedAt: recent ? Date.now() : old?.playedAt ?? 0 }
    if (!write(LIBRARY, [row, ...rows.filter(value => value.slug !== row.slug)].slice(0,100))) status.textContent = 'Browser storage is unavailable. Your library could not be saved.'
    renderLibrary()
  }
  function renderLibrary() {
    const rows = library(); saveButton.textContent = rows.some(row => row.slug === work?.publicSlug && row.saved) ? 'Saved ✓' : 'Save work'
    const container = document.querySelector('#play-library'); container.replaceChildren()
    for (const [name, filter] of [['Saved', row => row.saved], ['Recently played', row => row.playedAt > 0]]) {
      const heading = document.createElement('h3'); heading.textContent = name; container.append(heading)
      const list = rows.filter(filter).slice(0,20)
      if (!list.length) { const empty = document.createElement('p'); empty.textContent = 'Nothing here yet.'; container.append(empty) }
      for (const row of list) {
        const link = document.createElement('a'); link.textContent = row.title; link.href = `/a/${row.slug}`; container.append(link)
      }
    }
  }
  let surfaceVisible = true
  const visibility = () => artifact.contentWindow?.postMessage({ type: 'pulse:visibility', active: !document.hidden && surfaceVisible }, '*')
  const observer = new IntersectionObserver(entries => { surfaceVisible = entries[0]?.intersectionRatio >= 0.5; visibility() }, { threshold: [0, 0.5, 1] })
  observer.observe(artifact)
  document.addEventListener('visibilitychange', visibility)
  artifact.addEventListener('load', visibility)
  window.addEventListener('message', event => {
    if (event.source !== artifact.contentWindow || event.origin !== 'null' || document.hidden || artifact.hidden) return
    const input = parsePlayMessage(event.data); if (!input || !session) return
    const token = epoch; const id = session.id
    chain = chain.then(async () => {
      if (token !== epoch) return
      const value = await api(`play-sessions/${id}/events`, input)
      if (token !== epoch) return
      session = value.session
      if (session.qualified) updateLibrary(true)
      if (session.completed) {
        scoreLabel.textContent = `Your result: ${session.score}`
        panel.hidden = false
      }
    }).catch(() => { if (token === epoch) status.textContent = 'Result recording failed. Replay to try again.' })
  })
  async function ensureChallenge() {
    if (!session?.completed) throw new Error('Complete a round first.')
    if (!challenge) {
      const token = epoch
      const value = await api(`play-sessions/${session.id}/challenge`, {})
      if (token !== epoch) throw new Error('A new round has started.')
      const url = new URL(value.challenge.url)
      if (url.origin !== location.origin || url.pathname !== `/a/${work.publicSlug}` || challengeID(url.search) !== value.challenge.id) throw new Error('The public player domain is not configured correctly.')
      challenge = value.challenge
    }
    return challenge
  }
  shareButton.addEventListener('click', async () => {
    shareButton.disabled = true
    try {
      const result = await ensureChallenge()
      const text = `I scored ${result.score} in ${work.title}. Play the same challenge!`
      if (navigator.share) await navigator.share({ title: work.title, text, url: result.url })
      else { await navigator.clipboard.writeText(result.url); status.textContent = 'Challenge link copied.' }
    } catch (error) { if (error.name !== 'AbortError') status.textContent = error.message }
    finally { shareButton.disabled = false }
  })
  document.querySelector('#download-result').addEventListener('click', async () => {
    try {
      const result = await ensureChallenge()
      const canvas = document.createElement('canvas'); canvas.width = 960; canvas.height = 700
      const ctx = canvas.getContext('2d'); ctx.fillStyle = '#101212'; ctx.fillRect(0,0,960,700)
      ctx.fillStyle = '#b4ff14'; ctx.font = 'bold 25px sans-serif'; ctx.fillText('PULSE / SAME CHALLENGE', 60, 70)
      ctx.fillStyle = '#fff'; ctx.font = 'bold 42px sans-serif'; ctx.fillText(work.title.slice(0,35),60,150,840)
      ctx.font = 'bold 150px sans-serif'; ctx.fillText(String(result.score),60,330,840)
      ctx.font = '30px sans-serif'; ctx.fillText('Can you beat my score?',60,400)
      ctx.fillStyle = '#b0b5ac'; ctx.font = '22px sans-serif'; ctx.fillText(`by @${work.creator}`,60,455,840)
      ctx.font = '18px sans-serif'; ctx.fillText('Player-reported score · same published version & seed',60,515)
      const urlLines = result.url.match(/.{1,72}/g) ?? []
      urlLines.slice(0,4).forEach((line, i) => ctx.fillText(line,60,555+i*25,840))
      canvas.toBlob(blob => { if (!blob) return; const url = URL.createObjectURL(blob); const a = document.createElement('a'); a.href = url; a.download = 'pulse-result.png'; a.click(); setTimeout(() => URL.revokeObjectURL(url),1000) }, 'image/png')
    } catch (error) { status.textContent = error.message }
  })
  document.querySelector('#replay').addEventListener('click', () => reload())
  saveButton.addEventListener('click', () => updateLibrary())
  consent.checked = identity().consent
  consent.addEventListener('change', async () => {
    consent.disabled = true
    try {
      if (!consent.checked && identity().consent) await api('growth/identity', identity(), 'DELETE')
      if (!write(CONSENT, consent.checked)) throw new Error('Browser storage is unavailable.')
      if (consent.checked) await api('growth/visits', identity())
      status.textContent = consent.checked ? 'Usage analytics enabled. Applies to your next play.' : 'Usage analytics disabled and activity erased.'
    } catch (error) { consent.checked = identity().consent; status.textContent = error.message }
    finally { consent.disabled = false }
  })
  renderLibrary()
  return {
    async prepare(value, entry) {
      const token = ++epoch; work = value; session = undefined; challenge = undefined; currentChallenge = undefined; panel.hidden = true; challengeLabel.hidden = true
      const incomingID = challengeID(location.search)
      if (incomingID) {
        currentChallenge = (await api(`public/challenges/${incomingID}`, undefined, 'GET')).challenge
        if (currentChallenge.workId !== work.id || currentChallenge.artifactId !== work.artifactId) throw new Error('This challenge belongs to a different version.')
        challengeLabel.textContent = `Same challenge · target ${currentChallenge.score}`; challengeLabel.hidden = false
      }
      try {
        const value = await api('play-sessions', { ...identity(), workId: work.id, ...(incomingID ? { challengeId: incomingID } : {}) })
        if (token !== epoch) throw new Error('Loading a newer work.')
        session = value.session
        entry.searchParams.set('pulseRuntime', '1'); entry.hash = `pulseSeed=${session.seed}`
      } catch (error) { if (incomingID) throw error; status.textContent = 'Play is available; result recording is temporarily unavailable.' }
      renderLibrary()
      return entry
    },
    invalidate() { epoch++; session = undefined; panel.hidden = true },
  }
}
