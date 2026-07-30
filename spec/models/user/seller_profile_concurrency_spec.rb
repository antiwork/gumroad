# frozen_string_literal: true

require "spec_helper"

describe User, "#with_locked_seller_profile", :vcr do
  self.use_transactional_tests = false

  before do
    @seller = create(:user)
    GenerateSubscribePreviewJob.jobs.clear
  end

  after do
    SellerProfile.where(seller_id: @seller.id).delete_all
    User.where(id: @seller.id).delete_all
    GenerateSubscribePreviewJob.jobs.clear
  end

  it "creates one profile row when two first saves run concurrently" do
    ready = Queue.new
    start = Queue.new
    errors = Queue.new

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          User.find(@seller.id).with_locked_seller_profile do |profile|
            profile.font = "Domine"
            profile.save!
          end
        rescue StandardError => e
          errors << e
        end
      end
    end

    2.times { ready.pop }
    2.times { start << true }
    threads.each { expect(_1.join(10)).to eq(_1) }
    raise errors.pop unless errors.empty?

    expect(SellerProfile.where(seller_id: @seller.id).sole.font).to eq("Domine")
  end
end
