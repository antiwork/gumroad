# frozen_string_literal: true

require "spec_helper"

describe GenerateFeesByCreatorLocationReportJob do
  let(:month) { 8 }
  let(:year) { 2022 }

  it "raises an argument error if the year is out of bounds" do
    expect { described_class.new.perform(month, 2013) }.to raise_error(ArgumentError)
  end

  it "raises an argument error if the month is out of bounds" do
    expect { described_class.new.perform(13, year) }.to raise_error(ArgumentError)
  end

  describe "happy case", :vcr do
    let(:s3_bucket_double) do
      s3_bucket_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
      s3_bucket_double
    end

    before :context do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/creator-fees-reporting-spec-#{SecureRandom.hex(18)}.zip")
    end

    before do
      virginia_product = nil
      washington_product = nil
      california_product = nil
      australia_product = nil
      singapore_product = nil
      spain_product = nil

      travel_to(Time.find_zone("UTC").local(2022, 7, 1)) do
        virginia_creator = create(:user).tap do |creator|
          creator.fetch_or_build_user_compliance_info.dup_and_save! do |new_compliance_info|
            new_compliance_info.state = "VA"
            new_compliance_info.country = "United States"
          end
        end
        virginia_product = create(:product, user: virginia_creator, price_cents: 100_00, native_type: "digital")

        washington_creator = create(:user).tap do |creator|
          creator.fetch_or_build_user_compliance_info.dup_and_save! do |new_compliance_info|
            new_compliance_info.state = "WA"
            new_compliance_info.country = "United States"
          end
        end
        washington_product = create(:product, user: washington_creator, price_cents: 100_00, native_type: "digital")

        california_creator = create(:user).tap do |creator|
          creator.fetch_or_build_user_compliance_info.dup_and_save! do |new_compliance_info|
            new_compliance_info.state = "CA"
            new_compliance_info.country = "United States"
          end
        end
        california_product = create(:product, user: california_creator, price_cents: 100_00, native_type: "digital")

        australia_creator = create(:user).tap do |creator|
          creator.fetch_or_build_user_compliance_info.dup_and_save! do |new_compliance_info|
            new_compliance_info.country = "Australia"
          end
        end
        australia_product = create(:product, user: australia_creator, price_cents: 100_00, native_type: "digital")

        singapore_creator = create(:compliant_user).tap do |creator|
          creator.fetch_or_build_user_compliance_info.dup_and_save! do |new_compliance_info|
            new_compliance_info.country = "Singapore"
          end
        end
        singapore_product = create(:product, :recommendable, user: singapore_creator, price_cents: 100_00, native_type: "digital")

        spain_creator = create(:user).tap do |creator|
          creator.fetch_or_build_user_compliance_info.dup_and_save! do |new_compliance_info|
            new_compliance_info.country = "Spain"
          end
        end
        spain_product = create(:product, user: spain_creator, price_cents: 100_00, native_type: "digital")
      end

      travel_to(Time.find_zone("UTC").local(2022, 7, 30)) do
        create(:purchase_in_progress, link: virginia_product, country: "United States", zip_code: "22207")

        Purchase.in_progress.find_each do |purchase|
          purchase.chargeable = create(:chargeable)
          purchase.process!
          purchase.update_balance_and_mark_successful!
        end
      end

      travel_to(Time.find_zone("UTC").local(2022, 8, 1)) do
        create(:purchase_in_progress, link: washington_product, country: "United States", zip_code: "94016")
        create(:purchase_in_progress, link: california_product, country: "United States", zip_code: "94016")
        create(:purchase_in_progress, link: australia_product, country: "United States", zip_code: "94016")
        create(:purchase_in_progress, link: singapore_product, was_product_recommended: true, country: "United States", zip_code: "94016")

        Purchase.in_progress.find_each do |purchase|
          purchase.chargeable = create(:chargeable)
          purchase.process!
          purchase.update_balance_and_mark_successful!
        end
      end

      travel_to(Time.find_zone("UTC").local(2022, 8, 10)) do
        create(:purchase_in_progress, link: california_product, country: "United States", zip_code: "94016")
        create(:purchase_in_progress, link: australia_product, country: "United States", zip_code: "94016")
        create(:purchase_in_progress, link: singapore_product, was_product_recommended: true, country: "United States", zip_code: "94016")

        Purchase.in_progress.find_each do |purchase|
          purchase.chargeable = create(:chargeable)
          purchase.process!
          purchase.update_balance_and_mark_successful!
        end
      end

      travel_to(Time.find_zone("UTC").local(2022, 8, 20)) do
        create(:purchase_in_progress, link: australia_product, country: "United States", zip_code: "94016")
        create(:purchase_in_progress, link: singapore_product, was_product_recommended: true, country: "United States", zip_code: "94016")

        Purchase.in_progress.find_each do |purchase|
          purchase.chargeable = create(:chargeable)
          purchase.process!
          purchase.update_balance_and_mark_successful!
        end
      end

      travel_to(Time.find_zone("UTC").local(2022, 8, 31)) do
        create(:purchase_in_progress, link: singapore_product, was_product_recommended: true, country: "United States", zip_code: "94016")

        Purchase.in_progress.find_each do |purchase|
          purchase.chargeable = create(:chargeable)
          purchase.process!
          purchase.update_balance_and_mark_successful!
        end
      end

      travel_to(Time.find_zone("UTC").local(2022, 9, 1)) do
        create(:purchase_in_progress, link: spain_product, country: "United States", zip_code: "94016")

        Purchase.in_progress.find_each do |purchase|
          purchase.chargeable = create(:chargeable)
          purchase.process!
          purchase.update_balance_and_mark_successful!
        end
      end
    end

    it "creates a CSV file for creator fees by location" do
      expect(s3_bucket_double).to receive(:object).ordered.and_return(@s3_object)

      described_class.new.perform(month, year)

      expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "Fee Reporting", anything, "green")

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)

      expect(actual_payload).to eq([
                                     ["Month", "Creator Country", "Creator State", "Gumroad Fees"],
                                     ["August 2022", "United States", "Washington", "1370"],
                                     ["August 2022", "United States", "California", "2740"],
                                     ["August 2022", "United States", "", "4110"],
                                     ["August 2022", "Australia", "", "4110"],
                                     ["August 2022", "Singapore", "", "12000"]
                                   ])
    end
  end

  describe "#determine_country_name_and_state_name" do
    let(:job) { described_class.new }

    it "queries a seller's compliance info only once across purchases on the same date" do
      seller = travel_to(1.year.ago) do
        create(:user).tap do |creator|
          creator.fetch_or_build_user_compliance_info.dup_and_save! do |info|
            info.state = "CA"
            info.country = "United States"
          end
        end
      end
      product = create(:product, user: seller, price_cents: 0)
      created_at = Time.current.change(usec: 0)
      create_list(:purchase, 3, seller:, link: product, price_cents: 0, created_at:)
      # Reload from the DB so each purchase.seller is an independent record with
      # no pre-loaded association, mirroring the job's find_each iteration.
      purchases = Purchase.where(seller_id: seller.id).to_a

      compliance_query_count = 0
      counter = ->(_name, _start, _finish, _id, payload) do
        compliance_query_count += 1 if payload[:sql]&.include?("user_compliance_info") && payload[:name] != "CACHE"
      end

      results = []
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        results = purchases.map { |purchase| job.determine_country_name_and_state_name(purchase) }
      end

      expect(results).to all(eq(["United States", "California"]))
      expect(compliance_query_count).to eq(1)
    end

    it "looks up GeoIp once when falling back to it" do
      seller = create(:user, country: nil, state: nil)
      product = create(:product, user: seller, price_cents: 0)
      purchase = create(:purchase, seller:, link: product, price_cents: 0)
      location = double(country_name: "United States", region_name: "CA")

      expect(GeoIp).to receive(:lookup).once.and_return(location)

      job.determine_country_name_and_state_name(purchase)
    end
  end
end
