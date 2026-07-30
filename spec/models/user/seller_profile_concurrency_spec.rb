# frozen_string_literal: true

require "spec_helper"

describe User, "#with_locked_seller_profile", :vcr do
  self.use_transactional_tests = false

  before do
    @seller = create(:user)
    GenerateSubscribePreviewJob.jobs.clear
  end

  after do
    SellerProfileSection.where(seller_id: @seller.id).delete_all
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

  it "waits for a current profile read before yielding" do
    profile = @seller.seller_profile
    profile.save!
    section = create(:seller_profile_products_section, seller: @seller, header: "Before")
    profile.update!(json_data: { tabs: [{ name: "", sections: [section.id] }] })
    stale_version = profile.layout_version
    profile_locked = Queue.new
    release_profile = Queue.new
    reader_started = Queue.new
    observed_version = Queue.new
    errors = Queue.new

    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        SellerProfile.find(profile.id).with_lock do
          SellerProfileSection.find(section.id).update!(header: "After")
          profile_locked << true
          release_profile.pop
        end
      rescue StandardError => e
        errors << e
      end
    end
    profile_locked.pop

    reader = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        reader_started << true
        User.find(@seller.id).with_locked_seller_profile do |locked_profile|
          observed_version << locked_profile.layout_version
        end
      rescue StandardError => e
        errors << e
      end
    end
    reader_started.pop

    begin
      sleep 0.1
      expect(reader).to be_alive
      expect(observed_version).to be_empty
    ensure
      release_profile << true
    end
    [writer, reader].each { expect(_1.join(10)).to eq(_1) }
    raise errors.pop unless errors.empty?

    current_version = observed_version.pop
    expect(current_version).to eq(profile.reload.layout_version)
    expect(current_version).not_to eq(stale_version)
  end
end
