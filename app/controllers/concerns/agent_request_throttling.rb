# frozen_string_literal: true

# The per-seller budget for the store agent's mutating endpoints, shared by every surface that can
# spend it: the web chat (buffered + streaming) and the mobile app (buffered + streaming). The key is
# seller-scoped rather than per-controller so no surface gets its own extra allowance — 30 requests
# per hour in total, whichever combination of them the seller uses.
#
# Both sending a message and confirming a staged change count, because both are throttled actions,
# and the message below says so: a seller who is told only about "messages" and has actually spent
# half their budget confirming changes would reasonably think the number was wrong.
module AgentRequestThrottling
  extend ActiveSupport::Concern

  included do
    include Throttling
  end

  AGENT_REQUESTS_PER_PERIOD = 30
  AGENT_REQUESTS_PERIOD_WINDOW = 1.hour

  private
    def throttle_agent_requests_for(seller_id)
      throttle!(
        key: RedisKey.agent_request_throttle(seller_id),
        limit: AGENT_REQUESTS_PER_PERIOD,
        period: AGENT_REQUESTS_PERIOD_WINDOW,
        message: method(:agent_throttle_message)
      )
    end

    # What the seller reads in the chat when they hit the limit. It has to do three jobs, because the
    # generic "something went wrong" it replaces sent sellers hunting for a broken account: name the
    # actual limit, say how long is left, and rule out the account/store being at fault.
    def agent_throttle_message(retry_after)
      # retry_after is 0 when the hour's counter expired in the moment this request was being
      # counted, so the seller can simply send again — telling them to wait would be wrong.
      timing = if retry_after <= 0
        "You can continue now"
      else
        minutes = [(retry_after.to_f / 60).ceil, 1].max
        "You can continue in #{minutes} #{"minute".pluralize(minutes)}"
      end

      "You've used all #{AGENT_REQUESTS_PER_PERIOD} agent requests for this hour (sending a message " \
        "and confirming a change both count). #{timing} — nothing is wrong with your account or " \
        "your store."
    end
end
