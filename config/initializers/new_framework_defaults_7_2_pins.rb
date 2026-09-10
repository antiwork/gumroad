# frozen_string_literal: true

# Owner: gumclaw; audit regex-heavy validators before imposing a global timeout.
Regexp.timeout = nil
