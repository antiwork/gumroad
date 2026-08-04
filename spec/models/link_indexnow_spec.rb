# frozen_string_literal: true

require "spec_helper"

describe Link, "IndexNow submissions" do
  let(:product) { create(:product, purchase_disabled_at: Time.current, draft: true) }

  it "enqueues a submission on publish" do
    product.publish!

    expect(SubmitToIndexnowJob).to have_enqueued_sidekiq_job([product.id])
  end

  it "enqueues a submission on unpublish" do
    published_product = create(:product)
    published_product.unpublish!

    expect(SubmitToIndexnowJob).to have_enqueued_sidekiq_job([published_product.id])
  end

  it "enqueues a submission when a published product's name changes" do
    published_product = create(:product)
    published_product.update!(name: "New name")

    expect(SubmitToIndexnowJob).to have_enqueued_sidekiq_job([published_product.id])
  end

  it "does not enqueue a submission when an unpublished product's name changes" do
    product.update!(name: "New name")

    expect(SubmitToIndexnowJob).not_to have_enqueued_sidekiq_job([product.id])
  end

  it "does not enqueue a submission for unrelated changes to a published product" do
    published_product = create(:product)
    published_product.update!(max_purchase_count: 5)

    expect(SubmitToIndexnowJob).not_to have_enqueued_sidekiq_job([published_product.id])
  end
end
