# frozen_string_literal: true

module Makara
  class ConnectionWrapper
    # Rails 7.0 compatibility, from: https://github.com/instacart/makara/pull/358
    # TODO: Remove this file after the makara gem is updated, including this PR.
    def execute(*args, **kwargs)
      SQL_REPLACE.each do |find, replace|
        if args[0] == find
          args[0] = replace
        end
      end

      _makara_connection.execute(*args, **kwargs)
    end
  end
end
