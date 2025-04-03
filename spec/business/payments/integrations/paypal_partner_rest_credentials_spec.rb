# frozen_string_literal: true

describe PaypalPartnerRestCredentials do
  describe "#auth_token" do
    context "when a cached token is present" do
      before do
        @some_auth_token = "random token"
        allow_any_instance_of(described_class).to receive(:load_token).and_return(@some_auth_token)
      end

      it "does not initiate an API call and returns the authorization token header value from the cache" do
        expect_any_instance_of(described_class).to_not receive(:request_for_api_token)

        auth_token = described_class.new.auth_token

        expect(auth_token).to eq(@some_auth_token)
      end
    end

    context "when a cached token is absent", :vcr do
      before do
        allow_any_instance_of(described_class).to receive(:load_token).and_return(nil)
      end

      it "initiates an API call and returns a valid authorization token header value" do
        expect_any_instance_of(described_class).to receive(:request_for_api_token).and_call_original

        auth_token = described_class.new.auth_token

        expect(auth_token).to be_an_instance_of(String)
        expect(auth_token).to match(/^[^\s]+ [^\s]+$/) # A concatenation of two strings with a space
      end

      it "raises an exception on API call failure" do
        allow(described_class).to receive(:post).and_raise(SocketError)

        expect do
          described_class.new.auth_token
        end.to raise_error(SocketError)
      end
    end
  end
end
