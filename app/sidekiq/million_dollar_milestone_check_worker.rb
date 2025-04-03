# frozen_string_literal: true

class MillionDollarMilestoneCheckWorker
  include Sidekiq::Job
  include Rails.application.routes.url_helpers

  MILLION_DOLLARS_IN_CENTS = 1_000_000_00

  sidekiq_options retry: 5, queue: :low

  def perform
    purchase_creation_time_range = Range.new(3.weeks.ago.days_ago(2), 2.weeks.ago)
    seller_ids_sub_query = Purchase.created_between(purchase_creation_time_range).
                                    all_success_states.not_chargedback_or_chargedback_reversed.
                                    select(:seller_id).
                                    distinct

    User.not_million_dollar_announcement_sent.where(id: seller_ids_sub_query).find_each do |user|
      next if user.gross_sales_cents_total_as_seller < MILLION_DOLLARS_IN_CENTS

      compliance_info = user.alive_user_compliance_info

      message = "<#{user.profile_url}|#{user.name_or_username}> has crossed $1M in earnings :tada:\n" \
                "• Name: #{user.name}\n" \
                "• Username: #{user.username}\n" \
                "• Email: #{user.email}\n"

      if compliance_info.present?
        message += "• First name: #{compliance_info.first_name}\n" \
                   "• Last name: #{compliance_info.last_name}\n" \
                   "• Street address: #{compliance_info.street_address}\n" \
                   "• City: #{compliance_info.city}\n" \
                   "• State: #{compliance_info.state}\n" \
                   "• ZIP code: #{compliance_info.zip_code}\n" \
                   "• Country: #{compliance_info.country}"
      end

      if user.update(million_dollar_announcement_sent: true)
        SlackMessageWorker.perform_async("awards", "Gumroad Awards", message, "hotpink")
      else
        Bugsnag.notify("Failed to send Slack notification for million dollar milestone", user_id: user.id)
      end
    end
  end
end
