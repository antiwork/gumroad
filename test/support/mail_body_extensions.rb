# frozen_string_literal: true

module MailBodyExtensions
  def sanitized
    @_sanitized ||= ActionView::Base.full_sanitizer
      .sanitize(self.encoded)
      .gsub("\r\n", " ")
      .gsub(/\s{2,}/, " ")
  end
end

# Extend Mail::Body to include the above module
Mail::Body.include(MailBodyExtensions)
