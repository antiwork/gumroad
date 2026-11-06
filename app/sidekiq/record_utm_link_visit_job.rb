# frozen_string_literal: true

# Records a visit to a UTM-tagged product page that go_web served, as UtmLinkTracking records one
# in the request: under that request's PaperTrail metadata, at the time of the visit.
class RecordUtmLinkVisitJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 3

  def perform(visit)
    seller = User.find_by(id: visit["seller_id"])
    return if seller.nil?

    user = User.find_by(id: visit["user_id"]) if visit["user_id"]
    PaperTrail.request(whodunnit: visit["user_id"], controller_info: visit["paper_trail"].symbolize_keys) do
      UtmLinkVisitRecorder.new(
        seller:,
        target_resource_type: visit["target_resource_type"],
        target_resource_id: visit["target_resource_id"],
        utm_params: visit["utm_params"].symbolize_keys,
        user:,
        referrer: visit["referrer"],
        ip_address: visit["ip_address"],
        user_agent: visit["user_agent"],
        browser_guid: visit["browser_guid"],
        visited_at: Time.zone.at(Rational(visit["visited_at_us"], 1_000_000)),
      ).record
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    # As the request does: a retry can't converge on these. Lock timeouts, which the request
    # swallows to spare the page, retry here, where the visit's transaction rolled back.
    ErrorNotifier.notify(e, utm_params: visit["utm_params"])
  end
end
