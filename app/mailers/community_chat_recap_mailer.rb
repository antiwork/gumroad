# frozen_string_literal: true

class CommunityChatRecapMailer < ApplicationMailer
  include ActionView::Helpers::TextHelper

  layout "layouts/email"

  default from: "noreply@#{CREATOR_CONTACTING_CUSTOMERS_MAIL_DOMAIN}"

  def community_chat_recap_notification(user_id, seller_id, community_chat_recap_ids)
    user = User.find(user_id)
    @seller = User.find(seller_id)
    @recaps = CommunityChatRecap.includes(community: :resource).where(id: community_chat_recap_ids)
    recap_run = @recaps.first.community_chat_recap_run
    @recap_frequency = recap_run.recap_frequency

    subject = "Your #{@recap_frequency} #{@seller.name.truncate(20)} community recap: #{humanized_duration(@recap_frequency, recap_run)}"

    mail(
      to: user.form_email,
      subject:,
      delivery_method_options: MailerInfo.random_delivery_method_options(domain: :creators)
    )
  end

  private
    def humanized_duration(recap_frequency, recap_run)
      if recap_frequency == "daily"
        recap_run.from_date.strftime("%B %-d, %Y")
      else
        # Example: "March 23-29, 2025"
        if recap_run.from_date.month == recap_run.to_date.month && recap_run.from_date.year == recap_run.to_date.year
          "#{recap_run.from_date.strftime("%B %-d")}-#{recap_run.to_date.strftime("%-d, %Y")}"
          # Example: "March 30-April 5, 2025"
        elsif recap_run.from_date.year == recap_run.to_date.year
          "#{recap_run.from_date.strftime("%B %-d")}-#{recap_run.to_date.strftime("%B %-d, %Y")}"
          # Example: "December 28, 2025-January 3, 2026"
        else
          "#{recap_run.from_date.strftime("%B %-d, %Y")}-#{recap_run.to_date.strftime("%B %-d, %Y")}"
        end
      end
    end
end
