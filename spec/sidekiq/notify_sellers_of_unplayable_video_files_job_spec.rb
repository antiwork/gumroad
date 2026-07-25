# frozen_string_literal: true

require "spec_helper"

describe NotifySellersOfUnplayableVideoFilesJob do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, name: "Crochet course") }

  def create_unplayable_video(link: product, **attributes)
    product_file = create(:streamable_video, link:, **attributes)
    product_file.update!(width: nil, height: nil)
    product_file.analyze_completed = true
    product_file.save!
    product_file
  end

  it "emails the seller about an unplayable video file" do
    product_file = create_unplayable_video

    expect do
      described_class.new.perform
    end.to have_enqueued_mail(ContactingCreatorMailer, :unplayable_video_files)
      .with(product.id, [product_file.id])
  end

  it "stamps the file so a later run does not email about it again" do
    product_file = create_unplayable_video

    described_class.new.perform
    expect(product_file.reload.unplayable_video_notified_at).to be_present

    expect do
      described_class.new.perform
    end.not_to have_enqueued_mail(ContactingCreatorMailer, :unplayable_video_files)
  end

  it "sends one email per product listing all of its unplayable files" do
    first_file = create_unplayable_video
    second_file = create_unplayable_video
    other_product = create(:product, user: seller)
    other_product_file = create_unplayable_video(link: other_product)

    expect do
      described_class.new.perform
    end.to have_enqueued_mail(ContactingCreatorMailer, :unplayable_video_files)
      .with(product.id, [first_file.id, second_file.id])
      .and have_enqueued_mail(ContactingCreatorMailer, :unplayable_video_files)
      .with(other_product.id, [other_product_file.id])
  end

  it "ignores a file that has a width and a height" do
    product_file = create(:streamable_video, link: product, width: 1920, height: 1080)
    product_file.analyze_completed = true
    product_file.save!

    expect do
      described_class.new.perform
    end.not_to have_enqueued_mail(ContactingCreatorMailer, :unplayable_video_files)
  end

  it "ignores a file whose analysis has not finished, because it may still succeed" do
    product_file = create(:streamable_video, link: product)
    product_file.update!(width: nil, height: nil)

    expect(product_file.reload.analyze_completed?).to be(false)
    expect do
      described_class.new.perform
    end.not_to have_enqueued_mail(ContactingCreatorMailer, :unplayable_video_files)
  end

  it "ignores a deleted file" do
    create_unplayable_video.mark_deleted!

    expect do
      described_class.new.perform
    end.not_to have_enqueued_mail(ContactingCreatorMailer, :unplayable_video_files)
  end

  it "ignores a file on a deleted product" do
    deleted_product = create(:product, user: seller)
    create_unplayable_video(link: deleted_product)
    deleted_product.update!(deleted_at: Time.current)

    expect do
      described_class.new.perform
    end.not_to have_enqueued_mail(ContactingCreatorMailer, :unplayable_video_files)
  end

  it "ignores a non-video file with no dimensions" do
    product_file = create(:product_file, link: product)
    product_file.analyze_completed = true
    product_file.save!

    expect do
      described_class.new.perform
    end.not_to have_enqueued_mail(ContactingCreatorMailer, :unplayable_video_files)
  end

  it "emails about a file that is missing only its height" do
    product_file = create(:streamable_video, link: product, width: 1920)
    product_file.update!(height: nil)
    product_file.analyze_completed = true
    product_file.save!

    expect do
      described_class.new.perform
    end.to have_enqueued_mail(ContactingCreatorMailer, :unplayable_video_files)
      .with(product.id, [product_file.id])
  end

  it "stops once it hits the per-run email cap and picks the rest up on the next run" do
    stub_const("#{described_class}::MAX_EMAILS_PER_RUN", 1)
    create_unplayable_video
    create_unplayable_video(link: create(:product, user: seller))

    expect do
      described_class.new.perform
    end.to have_enqueued_mail(ContactingCreatorMailer, :unplayable_video_files).once

    expect do
      described_class.new.perform
    end.to have_enqueued_mail(ContactingCreatorMailer, :unplayable_video_files).once
  end
end
