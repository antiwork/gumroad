# frozen_string_literal: true

# Is a primary role pin on the stack around this read? The entry names ActiveRecord::Base (the pool
# owner) with worker replicas configured, ApplicationRecord otherwise, so both are accepted; that the
# pin binds the proxy is covered by spec/config/connection_pin_spec.rb.
module PrimaryPin
  def current_pin
    ApplicationRecord.connected_to_stack.reverse.find { |entry| pinned_class?(entry) }
  end

  def primary_pinned?
    ApplicationRecord.connected_to_stack.any? { |entry| entry[:role] == :writing && pinned_class?(entry) }
  end

  def pinned_class?(entry)
    klasses = entry[:klasses]
    klasses.include?(ActiveRecord::Base) || klasses.include?(ApplicationRecord)
  end
end

RSpec.configure do |config|
  config.include PrimaryPin
end
