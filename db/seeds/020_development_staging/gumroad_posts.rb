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
                    message: "This is a new feature<p>#ProductUpdates</p>",
                    name: "Reorder Tiers and Versions",
                    published_at: Time.current, installment_type: "audience")
Installment.create!(seller: gumroad_user, shown_on_profile: true, send_emails: true,
                    message: "Sam has been creating and selling digital products on Gumroad for over 3 years now. What started as a side project selling programming tutorials has grown into a thriving business generating well over $100,000 in revenue. His success story showcases how creators can build sustainable income streams by focusing on delivering high-quality educational content.

Through consistent effort and engaging with his audience, Sam has built a loyal following of over 20,000 students who appreciate his clear teaching style and practical approach. He attributes much of his success to Gumroad's creator-friendly platform that lets him focus on creating great content while handling all the technical details of running an online business.<p>#CreatorStory</p>",
                    name: "Creator Spotlight: Sam's Success on Gumroad ",
                    published_at: Time.current, installment_type: "audience")

posts_directory = Rails.root.join("db", "seeds", "040_posts")

if Dir.exist?(posts_directory)
  Dir.glob("*.html", base: posts_directory).sort.each do |filename|
    file_path = posts_directory.join(filename)
    base_name = File.basename(filename, ".html")

    name = base_name.gsub(/^\d+_/, "").tr("-", " ").titleize
    message = File.read(file_path).strip

    Installment.create!(
      seller: gumroad_user,
      shown_on_profile: true,
      send_emails: true,
      message: message,
      name: name,
      published_at: Time.current,
      installment_type: "audience",
    )
  end
end
