# frozen_string_literal: true
module Makara
  class ConnectionWrapper
    def execute(*args, **kwargs)
      _makara_connection.execute(*args, **kwargs)
    end
  end
end