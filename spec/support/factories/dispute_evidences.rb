# frozen_string_literal: true

FactoryBot.define do
  factory :dispute_evidence do
    dispute { create(:dispute_formalized) }
    purchased_at { dispute.purchase.created_at }
    customer_email { dispute.purchase.email }
    seller_contacted_at { Time.current }

    after(:create) do |dispute_evidence|
      blob = ActiveStorage::Blob.create_and_upload!(io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "smilie.png"), "image/png"), filename: "receipt_image.png")
      blob.analyze
      dispute_evidence.receipt_image.attach(blob)

      blob = ActiveStorage::Blob.create_and_upload!(io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "smilie.png"), "image/png"), filename: "refund_policy.png")
      blob.analyze
      dispute_evidence.refund_policy_image.attach(blob)
    end
  end

  factory :dispute_evidence_on_charge, parent: :dispute_evidence do
    dispute { create(:dispute_formalized_on_charge) }
    purchased_at { dispute.charge.created_at }
    customer_email { dispute.charge.purchases.last.email }
    seller_contacted_at { Time.current }

    after(:create) do |dispute_evidence|
      blob = ActiveStorage::Blob.create_and_upload!(io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "smilie.png"), "image/png"), filename: "receipt_image.png")
      blob.analyze
      dispute_evidence.receipt_image.attach(blob)

      blob = ActiveStorage::Blob.create_and_upload!(io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "smilie.png"), "image/png"), filename: "refund_policy.png")
      blob.analyze
      dispute_evidence.refund_policy_image.attach(blob)
    end
  end
end
