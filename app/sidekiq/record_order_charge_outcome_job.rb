# frozen_string_literal: true

# Writes the order's partial-success outcome after a line item's transaction has committed.
# `after_transition` cannot do this: it runs inside the purchase's own transaction, so two line
# items settling concurrently each read the other as still in progress and both skip the write.
class RecordOrderChargeOutcomeJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(order_id)
    # Read the sibling purchase states from the primary: a replica that has not yet caught up with
    # the line item that just committed reads it as unsettled, and the flag is never written.
    ApplicationRecord.connected_to(role: :writing) do
      Order.find_by(id: order_id)&.record_charge_outcome!
    end
  end
end
