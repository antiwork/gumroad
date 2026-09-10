# frozen_string_literal: true

# Behavioral pins are in application.rb, before railties consume their configuration.
# Owner: gumclaw; preserve the deferred regex limit after all initializers as well.
Regexp.timeout = nil
