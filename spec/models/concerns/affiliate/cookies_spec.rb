# frozen_string_literal: true

require "spec_helper"

describe Affiliate::Cookies do
  let(:affiliate) { create(:direct_affiliate) }
  let(:another_affiliate) { create(:direct_affiliate) }

  describe "instance methods" do
    describe "#cookie_key" do
      it "generates cookie key with proper prefix and encrypted ID" do
        expected_key = "#{Affiliate::AFFILIATE_COOKIE_NAME_PREFIX}#{affiliate.to_encrypted_cookie_id}"
        expect(affiliate.cookie_key).to eq(expected_key)
      end

      it "generates different keys for different affiliates" do
        expect(affiliate.cookie_key).not_to eq(another_affiliate.cookie_key)
      end
    end

    describe "#to_encrypted_cookie_id" do
      it "returns encrypted ID without padding" do
        encrypted_id = affiliate.to_encrypted_cookie_id
        expect(encrypted_id).not_to include("=")
        expect(encrypted_id).to be_present
      end

      it "can be decrypted back to original ID" do
        encrypted_id = affiliate.to_encrypted_cookie_id
        decrypted_id = ObfuscateIds.decrypt(encrypted_id)
        expect(decrypted_id).to eq(affiliate.id)
      end

      it "generates deterministic IDs for the same affiliate" do
        id1 = affiliate.to_encrypted_cookie_id
        id2 = affiliate.to_encrypted_cookie_id
        expect(id1).to eq(id2)
      end
    end
  end

  describe "class methods" do
    describe ".by_cookies" do
      let(:cookies) do
        {
          affiliate.cookie_key => Time.current.to_i.to_s,
          another_affiliate.cookie_key => (Time.current - 1.hour).to_i.to_s,
          "_other_cookie" => "value",
          "_gumroad_guid" => "some-guid"
        }
      end

      it "returns affiliates found in cookies" do
        result = Affiliate.by_cookies(cookies)
        expect(result).to contain_exactly(affiliate, another_affiliate)
      end

      it "ignores non-affiliate cookies" do
        cookies_with_noise = cookies.merge("_random_cookie" => "value")
        result = Affiliate.by_cookies(cookies_with_noise)
        expect(result).to contain_exactly(affiliate, another_affiliate)
      end

      it "returns empty array when no affiliate cookies present" do
        empty_cookies = { "_gumroad_guid" => "some-guid" }
        result = Affiliate.by_cookies(empty_cookies)
        expect(result).to be_empty
      end

      it "handles empty cookies hash" do
        result = Affiliate.by_cookies({})
        expect(result).to be_empty
      end
    end

    describe ".cookie_ids_from_cookies" do
      let(:cookies) do
        {
          affiliate.cookie_key => "1234567890",
          another_affiliate.cookie_key => "0987654321",
          "_other_cookie" => "value"
        }
      end

      it "extracts encrypted cookie IDs from affiliate cookies" do
        result = Affiliate.cookie_ids_from_cookies(cookies)
        expect(result).to contain_exactly(
          affiliate.to_encrypted_cookie_id,
          another_affiliate.to_encrypted_cookie_id
        )
      end

      it "sorts cookies by timestamp descending" do
        newer_time = Time.current.to_i
        older_time = (Time.current - 1.hour).to_i

        sorted_cookies = {
          affiliate.cookie_key => older_time.to_s,
          another_affiliate.cookie_key => newer_time.to_s
        }

        result = Affiliate.cookie_ids_from_cookies(sorted_cookies)
        # Should return newer cookie first
        expect(result.first).to eq(another_affiliate.to_encrypted_cookie_id)
        expect(result.second).to eq(affiliate.to_encrypted_cookie_id)
      end

      it "handles URL-encoded cookie names" do
        encoded_cookie_name = CGI.escape(affiliate.cookie_key)
        cookies = { encoded_cookie_name => "1234567890" }

        result = Affiliate.cookie_ids_from_cookies(cookies)
        expect(result).to contain_exactly(affiliate.to_encrypted_cookie_id)
      end

      it "ignores non-affiliate cookies" do
        cookies = {
          affiliate.cookie_key => "1234567890",
          "_random_cookie" => "value",
          "_gumroad_guid" => "guid-value"
        }

        result = Affiliate.cookie_ids_from_cookies(cookies)
        expect(result).to contain_exactly(affiliate.to_encrypted_cookie_id)
      end
    end

    describe ".by_cookie_ids" do
      it "finds affiliates by encrypted cookie IDs" do
        cookie_ids = [affiliate.to_encrypted_cookie_id, another_affiliate.to_encrypted_cookie_id]
        result = Affiliate.by_cookie_ids(cookie_ids)
        expect(result).to contain_exactly(affiliate, another_affiliate)
      end

      it "handles single cookie ID" do
        result = Affiliate.by_cookie_ids(affiliate.to_encrypted_cookie_id)
        expect(result).to contain_exactly(affiliate)
      end

      it "handles empty array" do
        result = Affiliate.by_cookie_ids([])
        expect(result).to be_empty
      end

      it "ignores invalid/non-existent IDs" do
        valid_id = affiliate.to_encrypted_cookie_id
        invalid_id = "invalid_encrypted_id"

        result = Affiliate.by_cookie_ids([valid_id, invalid_id])
        expect(result).to contain_exactly(affiliate)
      end
    end

    describe ".decrypt_cookie_id" do
      it "decrypts encrypted cookie ID back to raw affiliate ID" do
        encrypted_id = affiliate.to_encrypted_cookie_id
        decrypted_id = Affiliate.decrypt_cookie_id(encrypted_id)
        expect(decrypted_id).to eq(affiliate.id)
      end

      it "handles both padded and unpadded base64 formats" do
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

      it "returns nil for invalid encrypted IDs" do
        result = Affiliate.decrypt_cookie_id("invalid_id")
        expect(result).to be_nil
      end
    end
  end

  describe "integration: full cookie workflow" do
    it "can set and read cookies for multiple affiliates" do
      # Simulate setting cookies (like in affiliate redirect)
      cookies = {}

      # Set cookies with different timestamps
      cookies[affiliate.cookie_key] = Time.current.to_i.to_s
      cookies[another_affiliate.cookie_key] = (Time.current - 1.hour).to_i.to_s

      # Read affiliates from cookies (like in purchase flow)
      found_affiliates = Affiliate.by_cookies(cookies)

      expect(found_affiliates).to contain_exactly(affiliate, another_affiliate)
    end

    it "handles legacy cookies with padding during migration" do
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
      expect(affiliate_ids.uniq).to eq([affiliate.id])
    end
  end
end
