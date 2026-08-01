# Walkthrough for antiwork/gumroad#6741 — a receipt resend must not erase the
# original send's delivery record.
#
# Drives the REAL send path: EmailDeliveryObserver::HandleCustomerEmailInfo.perform,
# the observer that fires on every receipt the mailer actually delivers. The message
# is built with the same provider headers ApplicationMailer stamps, rather than
# rendering the template (rendering needs a Vite manifest; the headers are what the
# observer reads).
#
# Same script on origin/main and on fix/preserve-receipt-send-history.

ActiveRecord::Base.logger = nil
Elasticsearch::Client.class_eval { def transport_logger = nil } rescue nil
require "factory_bot"
FactoryBot.definition_file_paths = [Rails.root.join("spec/support/factories")]
FactoryBot.find_definitions

puts "=" * 78
puts "HEAD: #{`git rev-parse --short HEAD`.strip}"
puts "=" * 78

def receipt_message(purchase_id)
  Mail::Message.new.tap do |m|
    m.header[MailerInfo.header_name(:email_provider)] = MailerInfo::EMAIL_PROVIDER_RESEND
    m.header[MailerInfo.header_name(:mailer_method)]  = MailerInfo.encrypt("receipt")
    m.header[MailerInfo.header_name(:purchase_id)]    = MailerInfo.encrypt(purchase_id.to_s)
  end
end

def dump(purchase, label)
  rows = CustomerEmailInfo.where(purchase_id: purchase.id, email_name: "receipt").order(:id)
  puts
  puts "--- #{label} ---"
  puts "  receipt send rows on purchase #{purchase.id}: #{rows.count}"
  rows.each_with_index do |r, i|
    puts format("    send #%d  id=%-6s state=%-9s sent_at=%-21s delivered_at=%-21s opened_at=%s",
                i + 1, r.id, r.state, r.sent_at&.iso8601 || "nil",
                r.delivered_at&.iso8601 || "nil", r.opened_at&.iso8601 || "nil")
  end
end

ApplicationRecord.transaction do
  seller  = FactoryBot.create(:user, name: "Walkthrough Seller")
  product = FactoryBot.create(:product, user: seller, name: "Walkthrough Product", price_cents: 1000)
  purchase = FactoryBot.build(:purchase, link: product, seller:, email: "buyer@example.com",
                                         price_cents: 1000, purchase_state: "successful")
  purchase.save!(validate: false)

  # Send 1 — the original receipt, three days ago; the buyer received and opened it.
  EmailDeliveryObserver::HandleCustomerEmailInfo.perform(receipt_message(purchase.id))
  original = CustomerEmailInfo.where(purchase_id: purchase.id, email_name: "receipt").order(:id).last
  original.update!(sent_at: 3.days.ago)
  original.mark_delivered!
  original.update!(delivered_at: 3.days.ago + 1.minute)
  original.mark_opened!
  original.update!(opened_at: 3.days.ago + 5.minutes)
  original_id = original.id
  dump(purchase, "STEP 1 — original receipt sent, delivered, opened (3 days ago)")

  # Send 2 — support resends the same receipt today. This is the operation at issue.
  EmailDeliveryObserver::HandleCustomerEmailInfo.perform(receipt_message(purchase.id))
  dump(purchase, "STEP 2 — after support RESENDS the receipt today")

  puts
  puts "--- STEP 3 — the question a chargeback response has to answer ---"
  puts "  'Did the ORIGINAL receipt reach the buyer, and when?'"
  history = purchase.respond_to?(:receipt_email_infos) ? purchase.receipt_email_infos.to_a
                                                       : [purchase.receipt_email_info].compact
  puts "  purchase.receipt_email_infos exists?  #{purchase.respond_to?(:receipt_email_infos)}"
  puts "  sends a caller can enumerate:         #{history.size}"
  row = CustomerEmailInfo.find_by(id: original_id)
  if row && row.delivered_at.present?
    puts "  ANSWER: YES — original send (row #{row.id}) delivered #{row.delivered_at.iso8601}, opened #{row.opened_at&.iso8601 || 'never'}"
  else
    puts "  ANSWER: UNKNOWN — the resend overwrote the original send's delivery evidence"
  end

  raise ActiveRecord::Rollback
end
puts
puts "(transaction rolled back — no rows persisted)"
