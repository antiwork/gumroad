# frozen_string_literal: true

# Is a primary role pin on the stack around this read? The stack entry carries the class
# ApplicationRecord.connected_to pinned: ActiveRecord::Base — the pool owner mysql2_proxy compares
# against — when worker replicas are configured, and ApplicationRecord itself when it delegates to
# AR's default no-op path. These assertions are about the app asking for a primary read, so they
# accept either; that the pin actually binds the proxy is pinned by spec/config/connection_pin_spec.rb.
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
