FactoryBot.define do
  factory :social_proof_widget do
    association :user
    name { "Test Widget" }
    universal { false }
    title { "20 people bought this in the last 24 hours!" }
    description { "A great product you should buy." }
    cta_text { "Buy Now" }
    cta_type { "button" }
    image_type { "none" }
    icon_color { "#FFB800" }

    trait :with_icon do
      image_type { "icon" }
      icon_name { "heart-fill" }
    end
  end
end
