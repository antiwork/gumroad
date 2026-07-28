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
  def self.edit!(pageable, find:, replace:)
    previous_custom_html = nil
    sanitization_report = nil
    edit_error = nil

    pageable.with_lock do
      previous_custom_html = pageable.custom_html

      if previous_custom_html.blank?
        edit_error = "There is no custom HTML page to edit. Publish one first with the full custom_html update."
        raise ActiveRecord::Rollback
      end

      # `find` must locate exactly one place in the page so the edit is unambiguous. Matching is
      # whitespace-tolerant (Ai::CustomHtmlSnippetMatcher): agents reading the page routinely
      # normalize characters like non-breaking spaces to plain spaces when they echo a snippet back,
      # and an exact-only match would make such an edit permanently unappliable
      # (gumroad-private#1251). Zero matches means the caller is working from stale HTML; multiple
      # matches means the snippet needs more surrounding context. Both errors say so explicitly, so
      # the agent can correct itself in the same turn.
      match = Ai::CustomHtmlSnippetMatcher.match(previous_custom_html, find)
      if match.occurrences.zero?
        edit_error = "find does not appear in the current custom HTML. Re-read the page and copy the snippet exactly, including whitespace."
        raise ActiveRecord::Rollback
      elsif match.occurrences > 1
        edit_error = "find matches #{match.occurrences} places in the current custom HTML. Include more surrounding context so it matches exactly once."
        raise ActiveRecord::Rollback
      end

      # Block form so the replacement is inserted literally — the two-argument form of String#sub
      # treats backslash sequences (\0, \1, \\) in the replacement specially, which would corrupt
      # HTML that legitimately contains backslashes.
      edited = previous_custom_html.sub(match.matcher) { replace }

      if edited.length > Page::MAX_CUSTOM_HTML_LENGTH
        edit_error = "The edited custom_html would be too long (maximum is #{Page::MAX_CUSTOM_HTML_LENGTH} characters)."
        raise ActiveRecord::Rollback
      end

      # Re-sanitize the whole spliced result, not just the inserted snippet: the replacement can
      # change how surrounding markup parses (for example by opening a tag the snippet closes), so
      # only the full document is safe to check. Matches replace!'s blank-to-nil normalization so an
      # edit that empties the page unpublishes it the same way.
      result = Ai::PageSanitizer.sanitize_with_report(edited)
      pageable.custom_html = result.html.presence
      sanitization_report = result.report
      pageable.save!
    end

    return Result.new(error: edit_error) if edit_error

    Result.new(custom_html: pageable.custom_html, previous_custom_html:, sanitization_report:)
  end
end
