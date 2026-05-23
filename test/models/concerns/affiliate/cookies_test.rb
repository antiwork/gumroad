# frozen_string_literal: true

require "test_helper"

class AffiliateCookiesTest < ActiveSupport::TestCase
  self.described_class = Affiliate::Cookies



  context_ Affiliate::Cookies do
    let(:affiliate) { create(:direct_affiliate) }
    let(:another_affiliate) { create(:direct_affiliate) }

  context_ "instance methods" do
  context_ "#cookie_key" do
  test "generates cookie key with proper prefix and encrypted ID" do
          expected_key = "#{Affiliate::AFFILIATE_COOKIE_NAME_PREFIX}#{affiliate.cookie_id}"
          expect(affiliate.cookie_key).to eq(expected_key)
        end

  test "generates different keys for different affiliates" do
          expect(affiliate.cookie_key).not_to eq(another_affiliate.cookie_key)
        end
      end

  context_ "#cookie_id" do
  test "returns encrypted ID without padding" do
          encrypted_id = affiliate.cookie_id
          expect(encrypted_id).not_to include("=")
          expect(encrypted_id).to be_present
        end

  test "can be decrypted back to original ID" do
          encrypted_id = affiliate.cookie_id
          decrypted_id = ObfuscateIds.decrypt(encrypted_id)
          expect(decrypted_id).to eq(affiliate.id)
        end

  test "generates deterministic IDs for the same affiliate" do
          id1 = affiliate.cookie_id
          id2 = affiliate.cookie_id
          expect(id1).to eq(id2)
        end
      end
    end

  context_ "class methods" do
  context_ ".by_cookies" do
        let(:cookies) do
          {
            affiliate.cookie_key => Time.current.to_i.to_s,
            another_affiliate.cookie_key => (Time.current - 1.hour).to_i.to_s,
            "_other_cookie" => "value",
            "_gumroad_guid" => "some-guid"
          }
        end

  test "returns affiliates found in cookies" do
          result = Affiliate.by_cookies(cookies)
          expect(result).to contain_exactly(affiliate, another_affiliate)
        end

  test "ignores non-affiliate cookies" do
          cookies_with_noise = cookies.merge("_random_cookie" => "value")
          result = Affiliate.by_cookies(cookies_with_noise)
          expect(result).to contain_exactly(affiliate, another_affiliate)
        end

  test "returns empty array when no affiliate cookies present" do
          empty_cookies = { "_gumroad_guid" => "some-guid" }
          result = Affiliate.by_cookies(empty_cookies)
          expect(result).to be_empty
        end

  test "handles empty cookies hash" do
          result = Affiliate.by_cookies({})
          expect(result).to be_empty
        end

  test "sorts affiliates by cookie recency (newest first)" do
          # affiliate has newer timestamp, another_affiliate has older timestamp
          result = Affiliate.by_cookies(cookies)

          # Should return affiliate first (newer cookie)
          expect(result.first).to eq(affiliate)
          expect(result.second).to eq(another_affiliate)
        end
      end

  context_ ".ids_from_cookies" do
        let(:cookies) do
          {
            affiliate.cookie_key => "1234567890",
            another_affiliate.cookie_key => "0987654321",
            "_other_cookie" => "value"
          }
        end

  test "extracts decrypted affiliate IDs from affiliate cookies" do
          result = Affiliate.ids_from_cookies(cookies)
          expect(result).to contain_exactly(affiliate.id, another_affiliate.id)
        end

  test "sorts cookies by timestamp descending" do
          newer_time = Time.current.to_i
          older_time = (Time.current - 1.hour).to_i

          sorted_cookies = {
            affiliate.cookie_key => older_time.to_s,
            another_affiliate.cookie_key => newer_time.to_s
          }

          result = Affiliate.ids_from_cookies(sorted_cookies)
          # Should return newer cookie first
          expect(result.first).to eq(another_affiliate.id)
          expect(result.second).to eq(affiliate.id)
        end

  test "handles URL-encoded cookie names" do
          encoded_cookie_name = CGI.escape(affiliate.cookie_key)
          cookies = { encoded_cookie_name => "1234567890" }

          result = Affiliate.ids_from_cookies(cookies)
          expect(result).to contain_exactly(affiliate.id)
        end

  test "ignores non-affiliate cookies" do
          cookies = {
            affiliate.cookie_key => "1234567890",
            "_random_cookie" => "value",
            "_gumroad_guid" => "guid-value"
          }

          result = Affiliate.ids_from_cookies(cookies)
          expect(result).to contain_exactly(affiliate.id)
        end
      end

  context_ ".extract_cookie_id_from_cookie_name" do
  test "extracts cookie ID from valid affiliate cookie names" do
          cookie_name = affiliate.cookie_key
          result = Affiliate.extract_cookie_id_from_cookie_name(cookie_name)
          expect(result).to eq(affiliate.cookie_id)
        end

  test "handles URL-encoded cookie names" do
          encoded_cookie_name = CGI.escape(affiliate.cookie_key)
          result = Affiliate.extract_cookie_id_from_cookie_name(encoded_cookie_name)
          expect(result).to eq(affiliate.cookie_id)
        end
      end

  context_ ".decrypt_cookie_id" do
  test "decrypts encrypted cookie ID back to raw affiliate ID" do
          encrypted_id = affiliate.cookie_id
          decrypted_id = Affiliate.decrypt_cookie_id(encrypted_id)
          expect(decrypted_id).to eq(affiliate.id)
        end

  test "handles both padded and unpadded base64 formats" do
          # Generate both formats for the same affiliate
          padded_id = ObfuscateIds.encrypt(affiliate.id, padding: true)
          unpadded_id = ObfuscateIds.encrypt(affiliate.id, padding: false)

          # Both should decrypt to the same raw ID
          padded_result = Affiliate.decrypt_cookie_id(padded_id)
          unpadded_result = Affiliate.decrypt_cookie_id(unpadded_id)

          expect(padded_result).to eq(affiliate.id)
          expect(unpadded_result).to eq(affiliate.id)
          expect(padded_result).to eq(unpadded_result)
        end

  test "returns nil for invalid encrypted IDs" do
          result = Affiliate.decrypt_cookie_id("invalid_id")
          expect(result).to be_nil
        end
      end
    end

  context_ "integration: full cookie workflow" do
  test "can set and read cookies for multiple affiliates" do
        # Simulate setting cookies (like in affiliate redirect)
        cookies = {}

        # Set cookies with different timestamps
        cookies[affiliate.cookie_key] = Time.current.to_i.to_s
        cookies[another_affiliate.cookie_key] = (Time.current - 1.hour).to_i.to_s

        # Read affiliates from cookies (like in purchase flow)
        found_affiliates = Affiliate.by_cookies(cookies)

        expect(found_affiliates).to contain_exactly(affiliate, another_affiliate)
      end

  test "handles legacy cookies with padding during migration" do
        # Simulate having both old (padded) and new (unpadded) cookies for same affiliate
        old_cookie_key = "#{Affiliate::AFFILIATE_COOKIE_NAME_PREFIX}#{ObfuscateIds.encrypt(affiliate.id, padding: true)}"
        new_cookie_key = affiliate.cookie_key

        cookies = {
          old_cookie_key => (Time.current - 1.hour).to_i.to_s,
          new_cookie_key => Time.current.to_i.to_s
        }

        # Should find the affiliate twice (which gets deduplicated by business logic)
        found_affiliates = Affiliate.by_cookies(cookies)
        affiliate_ids = found_affiliates.map(&:id)

        # Both cookies resolve to the same affiliate
        expect(affiliate_ids).to eq([affiliate.id])
      end

  test "handles sorting with mismatched cookie formats without errors" do
        # Create a padded cookie ID that won't match the affiliate's current cookie_id format
        old_cookie_key = "#{Affiliate::AFFILIATE_COOKIE_NAME_PREFIX}#{ObfuscateIds.encrypt(affiliate.id, padding: true)}"

        cookies = {
          old_cookie_key => 1.hour.ago.to_i.to_s,
          another_affiliate.cookie_key => 2.hours.ago.to_i.to_s
        }

        # This should not raise an exception even though affiliate.cookie_id won't match the old_cookie_key format
        expect { Affiliate.by_cookies(cookies) }.not_to raise_error

        found_affiliates = Affiliate.by_cookies(cookies)
        expect(found_affiliates.map(&:id)).to contain_exactly(affiliate.id, another_affiliate.id)
      end
    end
  end
end
