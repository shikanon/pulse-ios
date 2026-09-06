// The public API is the authority for publication, current-artifact access,
// suspension and takedown. Pending post-publication review is playable but
// must never be presented as an approved age rating.
export function isEligiblePublishedWork(work) {
  return Boolean(work && work.status === 'published' && work.verificationGrade === 'verified' &&
    (work.contentReviewStatus === 'pending' || (work.contentReviewStatus === 'approved' && work.ageRating === '4+')))
}
