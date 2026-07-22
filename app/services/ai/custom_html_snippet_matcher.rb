# frozen_string_literal: true

# Locates the `find` snippet of a store-agent page edit (edit_user_custom_html) inside the
# seller's current custom HTML.
#
# Why this isn't just String#scan: the agent reads the page, decides on a snippet, and sends it
# back — and language models routinely normalize whitespace along the way. The recurring failure
# is a non-breaking space (U+00A0) in the stored page coming back as a plain ASCII space in the
# snippet, at which point an exact match finds nothing, the edit can never apply, and the agent
# re-stages the same unmatchable snippet over and over while the seller's Confirm button stays
# disabled (gumroad-private#1251).
#
# So matching happens in two passes:
#   1. Exact — the snippet as sent, byte for byte. Always preferred, and the only pass consulted
#      when it matches at all (including ambiguous multi-matches, which are reported as such).
#   2. Whitespace-tolerant — every run of whitespace in the snippet (spaces, tabs, newlines, and
#      Unicode spaces like U+00A0; Ruby's [[:space:]] covers all of them) matches any non-empty
#      run of whitespace in the page. Everything between whitespace runs must still match
#      literally, so this never changes WHAT is replaced — only how forgivingly it is found.
#
# The uniqueness rule is unchanged: the snippet must locate exactly one place in the page. Both
# the real edit endpoint (Api::V2::UsersController#edit_custom_html) and the proposal-preview
# endpoint (Api::Internal::AgentCustomHtmlPreviewsController) MUST match through this class so
# a proposal that previews fine can't fail on apply, and vice versa.
module Ai
  class CustomHtmlSnippetMatcher
    # occurrences: how many places the snippet locates in the page (via whichever pass matched).
    # matcher: what to pass to String#sub to perform the replacement — the literal snippet when
    # the exact pass matched, otherwise the whitespace-tolerant Regexp. Only meaningful for
    # splicing when occurrences == 1.
    Result = Struct.new(:occurrences, :matcher, keyword_init: true)

    def self.match(page, find)
      exact_occurrences = page.scan(find).size
      return Result.new(occurrences: exact_occurrences, matcher: find) if exact_occurrences.positive?

      pattern = whitespace_tolerant_pattern(find)
      Result.new(occurrences: page.scan(pattern).size, matcher: pattern)
    end

    # Builds a Regexp equivalent to the snippet where each whitespace run is generalized. The
    # split keeps the whitespace separators (capturing group), so leading/trailing whitespace in
    # the snippet is preserved as a tolerant segment rather than dropped. Non-whitespace segments
    # are Regexp.escape'd — the snippet is still treated literally, never as a pattern.
    #
    # The `&nbsp;` entity counts as whitespace too: it's the HTML-source spelling of the same
    # U+00A0 character, so a page written with the entity and a snippet echoed back with a plain
    # space (or vice versa) are the same normalization mismatch.
    WHITESPACE_RUN = /(?:[[:space:]]|&nbsp;)+/
    def self.whitespace_tolerant_pattern(find)
      segments = find.split(/(#{WHITESPACE_RUN.source})/).map do |segment|
        segment.match?(/\A#{WHITESPACE_RUN.source}\z/) ? WHITESPACE_RUN.source : Regexp.escape(segment)
      end
      Regexp.new(segments.join)
    end
  end
end
