# frozen_string_literal: true

# Is a primary role pin active around this read? mysql2_proxy honours a stack entry only when its
# klasses include the connection's pool class, and every model's pool here belongs to
# ActiveRecord::Base (ApplicationRecord.connected_to delegates to it), so match that class — not the
# class the pin was declared on, which no longer appears in the entry.
module PrimaryPin
  def current_pin
    ApplicationRecord.connected_to_stack.reverse.find { |entry| entry[:klasses]&.include?(ActiveRecord::Base) }
  end

  def primary_pinned?
    ApplicationRecord.connected_to_stack.any? { |entry| entry[:role] == :writing && entry[:klasses].include?(ActiveRecord::Base) }
  end
end

RSpec.configure do |config|
  config.include PrimaryPin
end
