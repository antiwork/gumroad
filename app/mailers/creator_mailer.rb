# frozen_string_literal: true

class CreatorMailer < ApplicationMailer
  helper MailerHelper
  helper ApplicationHelper
  helper CurrencyHelper
  layout "layouts/email"

  def partner_migration_finished(partner_migration_id, recipient:)
    @migration = PartnerMigration.find(partner_migration_id)
    @failed = @migration.catalog_status == PartnerMigration::STATUS_FAILED
    @subject = @failed ? "Some products did not import" : "Your products are ready to review"

    mail to: recipient, subject: @subject
  end

  # A positional string, so the mailer header that records the arguments keeps only its first characters.
  def partner_migration_account_setup(partner_migration_id, encrypted_token)
    @migration = PartnerMigration.find(partner_migration_id)
    token = PartnerMigration.decrypt_account_setup_token(encrypted_token)
    @setup_url = partner_migration_account_setup_url(account_setup_token: token, host: DOMAIN, protocol: PROTOCOL)
    @subject = "Your Gumroad account is ready"

    mail to: @migration.user.email, subject: @subject
  end

  def gumroad_day_fee_saved(seller_id:, to_email: nil)
    @announcement = true

    seller = User.find(seller_id)
    email = to_email.presence || seller.email

    @fee_saved_amount = seller.gumroad_day_saved_fee_amount
    return unless @fee_saved_amount.present?

    mail to: email, subject: "You saved #{@fee_saved_amount} in fees on Gumroad Day!"
  end

  def year_in_review(seller:, year:, analytics_data:, payout_csv_url: nil, recipient: nil)
    @seller = seller
    @year = year
    @analytics_data = analytics_data
    @payout_csv_url = payout_csv_url
    email = recipient.presence || seller.email

    mail to: email, subject: "Your #{year} in review"
  end

  def bundles_marketing(seller_id:, bundles: [])
    seller = User.find(seller_id)
    @currency_type = seller.currency_type
    @bundles = bundles
    mail to: seller.form_email, subject: "Join top creators who have sold over $300,000 of bundles"
  end

  def top_creator_announcement(user_id:)
    user = User.alive.not_suspended.find_by(id: user_id)
    return unless user

    email = user.form_email
    return unless EmailFormatValidator.valid?(email)

    @subject = "You're a Top Creator!"

    mail(
      to: email,
      from: "Gumroad <gumroad@#{CREATOR_CONTACTING_CUSTOMERS_MAIL_DOMAIN}>",
      subject: @subject,
      delivery_method_options: MailerInfo.random_delivery_method_options(domain: :creators)
    )
  end

  def product_scheduled_publish_succeeded(schedule_id:)
    @schedule = ProductPublishSchedule.find_by(id: schedule_id)
    return if @schedule.nil?

    email = @schedule.product.user.form_email
    return unless EmailFormatValidator.valid?(email)

    @product = @schedule.product
    @published_at_label = @schedule.local_time_label(@schedule.published_at || @schedule.publish_at)
    @subject = "#{@product.name} is live"

    mail to: email, subject: @subject
  end

  def product_scheduled_publish_failed(schedule_id:)
    @schedule = ProductPublishSchedule.find_by(id: schedule_id)
    return if @schedule.nil?

    email = @schedule.product.user.form_email
    return unless EmailFormatValidator.valid?(email)

    @product = @schedule.product
    @scheduled_label = @schedule.local_time_label
    @editor_url = "#{UrlService.domain_with_protocol}/products/#{@product.unique_permalink}/edit"
    @subject = "#{@product.name} was not published"

    mail to: email, subject: @subject
  end

  def scheduled_payout_chargeback_hold(scheduled_payout_id:)
    @scheduled_payout = ScheduledPayout.find_by(id: scheduled_payout_id)
    return if @scheduled_payout.nil?

    user = @scheduled_payout.user
    email = user.form_email
    return if !EmailFormatValidator.valid?(email)

    @subject = "Your payout has been delayed"

    mail(
      to: email,
      subject: @subject
    )
  end

  # Links to the product's Share tab, not Settings, so the post is in front of the seller
  # when they return from reconnecting.
  def marketing_x_reconnect(marketing_action_id:)
    @action = Marketing::Action.awaiting_reconnect.find_by(id: marketing_action_id)
    return if @action.nil?

    seller = @action.user
    email = seller.form_email
    return unless EmailFormatValidator.valid?(email)

    @product = @action.link
    @share_url = "#{UrlService.domain_with_protocol}/products/#{@product.unique_permalink}/edit/share"
    @subject = "Reconnect X to send your launch post"

    mail(to: email, subject: @subject)
  end
end
