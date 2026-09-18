# frozen_string_literal: true

# Writes a seller-authored custom HTML page onto anything that has one — a user (their profile
# storefront) or a product (its landing page). Both surfaces store the page the same way (a Page
# record reached through `custom_html` / `custom_html=`), and both need the same care when it is
# written: serialize concurrent writers with a row lock, sanitize the WHOLE resulting document, and
# treat a page that ends up blank as "unpublish the page".
#
# It lives here rather than in a controller because the profile endpoints
# (Api::V2::UsersController) and the product endpoints (Api::V2::LinksController) would otherwise
# each carry their own copy of that logic, and a drift between the two — say, one of them forgetting
# the lock, or sanitizing only the inserted snippet instead of the spliced document — would be a
# correctness or security bug rather than a cosmetic difference.
#
# One caller intentionally does NOT use this service: the general product update
# (Api::V2::LinksController#update) accepts custom_html alongside every other product field and has
# to apply them all inside one transaction with one row lock, so its full-replace logic stays
# inline there. If you change how a page write works, change it in both places.
#
# Both entry points return a Result. `error` is a message meant for the caller (an API client or the
# agent) explaining why nothing was written; when it is nil the write succeeded and
# `previous_custom_html` holds what the page looked like before, so the caller can show a diff or
# offer an undo.
class Pages::CustomHtmlWriter
  Result = Struct.new(:custom_html, :previous_custom_html, :sanitization_report, :error, keyword_init: true) do
    def success? = error.nil?
  end

  # Replace the ENTIRE page with `custom_html`. Blank (or HTML that sanitizes down to nothing)
  # unpublishes the page, which is a valid outcome rather than an error.
  def self.replace!(pageable, custom_html)
    previous_custom_html = nil
    sanitization_report = nil

    pageable.with_lock do
      # with_lock reloads the row inside the transaction, which swaps in a fresh association cache —
      # so the previous_custom_html read below reflects a concurrent writer's committed page rather
      # than a stale in-memory copy, and the build_page call inside `custom_html=` can't race the
      # pages unique index.
      previous_custom_html = pageable.custom_html

      if custom_html.blank?
        pageable.custom_html = nil
        sanitization_report = Ai::PageSanitizer.empty_report
      else
        result = Ai::PageSanitizer.sanitize_with_report(custom_html)
        pageable.custom_html = result.html.presence
        sanitization_report = result.report
      end

      pageable.save!
    end

    Result.new(custom_html: pageable.custom_html, previous_custom_html:, sanitization_report:)
  end

  # Replace exactly one occurrence of `find` with `replace` inside the existing page, leaving the
  # rest untouched. This is what lets an agent make a small change (a color, a button label) without
  # regenerating the whole page — before it existed, the only write surface was a full replacement,
  # so a seller asking for a tiny tweak could lose their entire hand-built page to a fresh, much
  # smaller regeneration.
  #
  # Passing either checksum makes the edit "guarded": the server-built undo of an earlier targeted
  # edit (Ai::StoreAgentHtmlUndo). Guarded edits go through check_guarded_edit below.
  def self.edit!(pageable, find:, replace:, expected_custom_html_sha256: nil, result_custom_html_sha256: nil)
    previous_custom_html = nil
    sanitization_report = nil
    edit_error = nil
    guarded = !expected_custom_html_sha256.nil? || !result_custom_html_sha256.nil?

    pageable.with_lock(requires_new: guarded) do
      previous_custom_html = pageable.custom_html

      if previous_custom_html.blank?
        edit_error = "There is no custom HTML page to edit. Publish one first with the full custom_html update."
        raise ActiveRecord::Rollback
      end

      if guarded
        check = check_guarded_edit(previous_custom_html, find:, replace:, expected_custom_html_sha256:, result_custom_html_sha256:)
        if check.error
          edit_error = check.error
          raise ActiveRecord::Rollback
        end
        pageable.custom_html = check.custom_html
        sanitization_report = check.sanitization_report
      else
        # `find` must locate exactly one place in the page so the edit is unambiguous. Matching is
        # whitespace-tolerant (Ai::CustomHtmlSnippetMatcher) because agents echo a snippet back with
        # normalized spaces, and an exact-only match would make such an edit permanently unappliable
        # (gumroad-private#1251).
        match = Ai::CustomHtmlSnippetMatcher.match(previous_custom_html, find)
        if match.occurrences.zero?
          edit_error = FIND_MISSING_ERROR
          raise ActiveRecord::Rollback
        elsif match.occurrences > 1
          edit_error = find_ambiguous_error(match.occurrences)
          raise ActiveRecord::Rollback
        end

        # Block form so the replacement is inserted literally — the two-argument form of String#sub
        # treats backslash sequences (\0, \1, \\) in the replacement specially, which would corrupt
        # HTML that legitimately contains backslashes.
        edited = previous_custom_html.sub(match.matcher) { replace }

        if edited.length > Page::MAX_CUSTOM_HTML_LENGTH
          edit_error = LENGTH_ERROR
          raise ActiveRecord::Rollback
        end

        # Re-sanitize the whole spliced result, not just the inserted snippet: the replacement can
        # change how surrounding markup parses, so only the full document is safe to check. Blank to
        # nil matches replace!'s normalization, so an edit that empties the page unpublishes it too.
        result = Ai::PageSanitizer.sanitize_with_report(edited)
        pageable.custom_html = result.html.presence
        sanitization_report = result.report
      end

      pageable.save!
      # check_guarded_edit already verified this digest before the save; Page's own before_validation
      # re-sanitizes on save, so this only fires if that ever stops being idempotent.
      if guarded && Digest::SHA256.hexdigest(pageable.custom_html.to_s) != result_custom_html_sha256
        edit_error = RESULT_MISMATCH_ERROR
        raise ActiveRecord::Rollback
      end
    end

    return Result.new(error: edit_error) if edit_error

    Result.new(custom_html: pageable.custom_html, previous_custom_html:, sanitization_report:)
  end

  GuardedEdit = Struct.new(:custom_html, :sanitization_report, :error, keyword_init: true)
  SHA256_HEX_FORMAT = /\A[0-9a-f]{64}\z/
  FIND_MISSING_ERROR = "find does not appear in the current custom HTML. Re-read the page and copy the snippet exactly, including whitespace."
  LENGTH_ERROR = "The edited custom_html would be too long (maximum is #{Page::MAX_CUSTOM_HTML_LENGTH} characters)."
  INVALID_CHECKSUMS_ERROR = "Both custom HTML checksums must be valid SHA-256 digests."
  PAGE_CHANGED_ERROR = "The page changed since this undo was prepared. Ask the agent to check it again."
  RESULT_MISMATCH_ERROR = "The original page cannot be restored exactly. No change was saved."

  def self.find_ambiguous_error(occurrences)
    "find matches #{occurrences} places in the current custom HTML. Include more surrounding context so it matches exactly once."
  end

  # Non-mutating validation of a checksum-bound edit, shared with the proposal preview so a guarded
  # undo that previews can't fail at confirm time. `find` must match literally here — the whitespace
  # fallback could splice a different byte sequence than result_custom_html_sha256 was computed from.
  def self.check_guarded_edit(current_custom_html, find:, replace:, expected_custom_html_sha256:, result_custom_html_sha256:)
    unless [expected_custom_html_sha256, result_custom_html_sha256].all? { |digest| digest.is_a?(String) && digest.match?(SHA256_HEX_FORMAT) }
      return GuardedEdit.new(error: INVALID_CHECKSUMS_ERROR)
    end
    return GuardedEdit.new(error: PAGE_CHANGED_ERROR) if Digest::SHA256.hexdigest(current_custom_html.to_s) != expected_custom_html_sha256

    # Lookahead so overlapping begins count too: `scan` consumes each match, reading "aa" in "aaa" as
    # one occurrence when `sub` would splice the leftmost of two.
    occurrences = find.is_a?(String) && find.present? ? current_custom_html.scan(/(?=#{Regexp.escape(find)})/).size : 0
    return GuardedEdit.new(error: FIND_MISSING_ERROR) if occurrences.zero?
    return GuardedEdit.new(error: find_ambiguous_error(occurrences)) if occurrences > 1

    edited = current_custom_html.sub(find) { replace.to_s }
    return GuardedEdit.new(error: LENGTH_ERROR) if edited.length > Page::MAX_CUSTOM_HTML_LENGTH

    result = Ai::PageSanitizer.sanitize_with_report(edited)
    custom_html = result.html.presence
    # Page sanitizes again on save; an exact undo cannot restore a non-fixed-point document.
    return GuardedEdit.new(error: RESULT_MISMATCH_ERROR) if Ai::PageSanitizer.sanitize(custom_html).presence != custom_html
    return GuardedEdit.new(error: RESULT_MISMATCH_ERROR) if Digest::SHA256.hexdigest(custom_html.to_s) != result_custom_html_sha256

    GuardedEdit.new(custom_html:, sanitization_report: result.report)
  end
end
