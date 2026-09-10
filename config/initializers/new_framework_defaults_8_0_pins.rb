# frozen_string_literal: true

# Timezone/freshness pins live in application.rb so railties consume them before models load.
# Owner: gumclaw; audit regex-heavy validators before imposing the Rails 8 global timeout.
Regexp.timeout = nil
