# frozen_string_literal: true

require "test_helper"

class SubdomainTest < ActiveSupport::TestCase
  self.described_class = Subdomain



  context_ Subdomain do
    before do
      @seller1 = create(:user)
      @seller1.username = "test_user" # old style username
      @seller1.save(validate: false)

      @seller2 = create(:user, username: "testuser2") # new style username

      @seller3 = create(:user, username: nil)

      @root_domain_without_port = URI("#{PROTOCOL}://#{ROOT_DOMAIN}").host
    end

  context_ "#find_seller_by_request" do
      def request_obj(username)
        username = username.tr("_", "-") # convert underscores to hyphens in usernames
        OpenStruct.new({ host: "#{username}.#{@root_domain_without_port}", subdomains: [username] })
      end

  test "does not match sellers with blank usernames" do
        root_domain_request = OpenStruct.new({ host: @root_domain_without_port, subdomains: [] })
        expect(Subdomain.find_seller_by_request(root_domain_request)).to eq nil
      end

  test "finds the sellers using request subdomain" do
        expect(Subdomain.find_seller_by_request(request_obj(@seller1.username))).to eq @seller1
        expect(Subdomain.find_seller_by_request(request_obj(@seller2.username))).to eq @seller2
        expect(Subdomain.find_seller_by_request(request_obj(@seller3.external_id))).to eq @seller3
      end

  context_ "when seller is marked as deleted" do
        before do
          @seller1.mark_deleted!
        end

  test "does not find the seller" do
          expect(Subdomain.find_seller_by_request(request_obj(@seller1.username))).to be_nil
        end
      end
    end

  context_ "#find_seller_by_hostname" do
      def subdomain_url(username)
        [username.tr("_", "-"), @root_domain_without_port].join(".")
      end

  test "does not match sellers with blank usernames" do
        expect(Subdomain.find_seller_by_hostname(@root_domain_without_port)).to eq nil
      end

  test "finds the sellers using request subdomain" do
        expect(Subdomain.find_seller_by_hostname(subdomain_url(@seller1.username))).to eq @seller1
        expect(Subdomain.find_seller_by_hostname(subdomain_url(@seller2.username))).to eq @seller2
      end

  context_ "when seller is marked as deleted" do
        before do
          @seller1.mark_deleted!
        end

  test "does not find the seller" do
          expect(Subdomain.find_seller_by_hostname(subdomain_url(@seller1.username))).to be_nil
        end
      end
    end

  context_ "#subdomain_request?" do
  test "returns true when it's a valid subdomain request" do
        domain = "test.#{@root_domain_without_port}"

        expect(Subdomain.send(:subdomain_request?, domain).present?).to eq(true)
      end

  test "returns false when hostname contains underscore" do
        domain = "test_123.#{@root_domain_without_port}"

        expect(Subdomain.send(:subdomain_request?, domain).present?).to eq(false)
      end

  test "returns false when hostname doesn't look like a subdomain request" do
        domain = "sample.example.com"

        expect(Subdomain.send(:subdomain_request?, domain).present?).to eq(false)
      end
    end
  end
end
