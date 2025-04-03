# frozen_string_literal: true

email = "hi@gumroad.com"
gumroad_user = User.find_by(email:)
if gumroad_user.nil?
  gumroad_user = User.new
  gumroad_user.email = email
  gumroad_user.username = "gumroad"
  gumroad_user.confirmed_at = Time.current
  gumroad_user.password = SecureRandom.hex(24)
  gumroad_user.save!

  # Skip validations to set a pwned but easy password
  gumroad_user.password = "password"
  gumroad_user.save!(validate: false)
end
gumroad_user.reload

Installment.create!(seller: gumroad_user, shown_on_profile: true, send_emails: true,
                    message: "This is a new feature",
                    name: "Reorder Tiers and Versions",
                    published_at: Time.current, installment_type: "audience")
Installment.create!(seller: gumroad_user, shown_on_profile: true, send_emails: true,
                    message: "Sam has earned well over $100,000 on Gumroad",
                    name: "Creator Spotlight: Sam's Success on Gumroad ",
                    published_at: Time.current, installment_type: "audience")
