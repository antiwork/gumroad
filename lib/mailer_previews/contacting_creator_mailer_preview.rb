# frozen_string_literal: true

class ContactingCreatorMailerPreview < ActionMailer::Preview
  def cannot_pay
    ContactingCreatorMailer.cannot_pay(Payment.last&.id)
  end

  def preorder_release_reminder
    ContactingCreatorMailer.preorder_release_reminder(PreorderLink.last&.link&.id)
  end

  def preorder_summary
    ContactingCreatorMailer.preorder_summary(PreorderLink.last&.id)
  end

  def preorder_cancelled
    ContactingCreatorMailer.preorder_cancelled(Preorder.last&.id)
  end

  def debit_card_limit_reached
    ContactingCreatorMailer.debit_card_limit_reached(Payment.last&.id)
  end

  def invalid_bank_account
    ContactingCreatorMailer.invalid_bank_account(User.last&.id)
  end

  def chargeback_lost_no_refund_policy
    ContactingCreatorMailer.chargeback_lost_no_refund_policy(Purchase.last&.id)
  end

  def chargeback_notice
    ContactingCreatorMailer.chargeback_notice(Purchase.last&.id)
  end

  def chargeback_notice_with_dispute
    dispute_evidence = DisputeEvidence.seller_contacted.last
    ContactingCreatorMailer.chargeback_notice(dispute_evidence&.purchase&.id)
  end

  def chargeback_won
    ContactingCreatorMailer.chargeback_won(Purchase.last&.id)
  end

  def subscription_product_deleted
    ContactingCreatorMailer.subscription_product_deleted(Link.last&.id)
  end

  def subscription_cancelled
    ContactingCreatorMailer.subscription_cancelled(Subscription.last&.id)
  end

  def subscription_ended
    ContactingCreatorMailer.subscription_ended(Subscription.last&.id)
  end

  def subscription_downgraded
    subscription = Subscription.last
    ContactingCreatorMailer.subscription_downgraded(subscription&.id, subscription&.subscription_plan_changes&.last&.id)
  end

  def credit_notification
    ContactingCreatorMailer.credit_notification(User.last&.id, 1000)
  end

  def gumroad_day_credit_notification
    ContactingCreatorMailer.gumroad_day_credit_notification(User.last&.id, 1000)
  end

  def notify
    ContactingCreatorMailer.notify(Purchase.last&.id)
  end

  def negative_revenue_sale_failure
    ContactingCreatorMailer.negative_revenue_sale_failure(Purchase.last&.id)
  end

  def purchase_refunded_for_fraud
    ContactingCreatorMailer.purchase_refunded_for_fraud(Purchase.last&.id)
  end

  def purchase_refunded
    ContactingCreatorMailer.purchase_refunded(Purchase.last&.id)
  end

  def payment_returned
    ContactingCreatorMailer.payment_returned(Payment.completed.last&.id)
  end

  def remind
    ContactingCreatorMailer.remind(User.last&.id)
  end

  def seller_update
    ContactingCreatorMailer.seller_update(User.first&.id)
  end

  def subscription_cancelled_by_customer
    ContactingCreatorMailer.subscription_cancelled_by_customer(Subscription.last&.id)
  end

  def subscription_cancelled_to_seller
    ContactingCreatorMailer.subscription_cancelled(Subscription.last&.id)
  end

  def subscription_restarted
    ContactingCreatorMailer.subscription_restarted(Subscription.last&.id)
  end

  def subscription_ended_to_seller
    ContactingCreatorMailer.subscription_ended(Subscription.last&.id)
  end

  def unremovable_discord_member
    ContactingCreatorMailer.unremovable_discord_member("000000000000000000", "Server Name", Purchase.last&.id)
  end

  def unstampable_pdf_notification
    ContactingCreatorMailer.unstampable_pdf_notification(Link.last&.id)
  end

  def video_preview_conversion_error
    ContactingCreatorMailer.video_preview_conversion_error(Link.last&.id)
  end

  def payouts_may_be_blocked
    ContactingCreatorMailer.payouts_may_be_blocked(User.last&.id)
  end

  def more_kyc_needed
    ContactingCreatorMailer.more_kyc_needed(User.last&.id, %i[individual_tax_id birthday])
  end

  def stripe_document_verification_failed
    ContactingCreatorMailer.stripe_document_verification_failed(User.last&.id, "Some account information mismatches with one another. For example, some banks might require that the business profile name must match the account holder name.")
  end

  def stripe_identity_verification_failed
    ContactingCreatorMailer.stripe_document_verification_failed(User.last&.id, "The country of the business address provided does not match the country of the account. Businesses must be located in the same country as the account.")
  end

  def singapore_identity_verification_reminder
    ContactingCreatorMailer.singapore_identity_verification_reminder(User.last&.id, 30.days.from_now)
  end

  def video_transcode_failed
    ContactingCreatorMailer.video_transcode_failed(ProductFile.last&.id)
  end

  def subscription_autocancelled
    ContactingCreatorMailer.subscription_autocancelled(Subscription.where.not(failed_at: nil).last&.id)
  end

  def annual_payout_summary
    user = User.last
    if user&.financial_annual_report_url_for(year: 2022).nil?
      user&.annual_reports&.attach(
        io: Rack::Test::UploadedFile.new("#{Rails.root}/spec/support/fixtures/financial-annual-summary-2022.csv"),
        filename: "Financial summary for 2022.csv",
        content_type: "text/csv",
        metadata: { year: 2022 }
      )
    end
    ContactingCreatorMailer.annual_payout_summary(user&.id, 2022, 10_000)
  end

  def user_sales_data
    ContactingCreatorMailer.user_sales_data(User.last&.id, sample_csv_file)
  end

  def affiliates_data
    ContactingCreatorMailer.affiliates_data(recipient: User.last, tempfile: sample_csv_file, filename: "file")
  end

  def subscribers_data
    ContactingCreatorMailer.subscribers_data(recipient: User.last, tempfile: sample_csv_file, filename: "file")
  end

  def tax_form_1099k
    ContactingCreatorMailer.tax_form_1099k(User.last&.id, Time.current.year.pred, "https://www.gumroad.com")
  end

  def tax_form_1099misc
    ContactingCreatorMailer.tax_form_1099misc(User.last&.id, Time.current.year.pred, "https://www.gumroad.com")
  end

  def review_submitted
    ContactingCreatorMailer.review_submitted(ProductReview.last&.id)
  end

  def flagged_for_explicit_nsfw_tos_violation
    ContactingCreatorMailer.flagged_for_explicit_nsfw_tos_violation(User.last&.id)
  end

  def upcoming_call_reminder
    ContactingCreatorMailer.upcoming_call_reminder(Call.last&.id)
  end

  def refund_policy_enabled_email
    ContactingCreatorMailer.refund_policy_enabled_email(SellerRefundPolicy.where(product_id: nil).last&.seller_id)
  end

  def product_level_refund_policies_reverted
    ContactingCreatorMailer.product_level_refund_policies_reverted(User.last&.id)
  end

  def upcoming_refund_policy_change
    ContactingCreatorMailer.upcoming_refund_policy_change(User.last&.id)
  end

  def paypal_suspension_notification
    ContactingCreatorMailer.paypal_suspension_notification(User.last&.id)
  end

  def ping_endpoint_failure
    ContactingCreatorMailer.ping_endpoint_failure(User.last&.id, "https://example.com/webhook", 500)
  end

  private
    def sample_csv_file
      tempfile = Tempfile.new
      CSV.open(tempfile, "wb") { |csv| 100.times { csv << ["Some", "CSV", "Data"] } }
      tempfile.rewind
      tempfile
    end
end
