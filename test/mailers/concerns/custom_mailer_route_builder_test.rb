# frozen_string_literal: true

require "test_helper"

class CustomMailerRouteBuilderTest < ActionMailer::TestCase
  self.described_class = CustomMailerRouteBuilder



  context_ CustomMailerRouteBuilder do
    let(:mailer_class) do
      Class.new(ActionMailer::Base) do
        include CustomMailerRouteBuilder
      end
    end

    before do
      @mail = mailer_class.new
      @user = create(:user, username: "creatordude")
      @post = create(:installment, seller: @user)
      @purchase = create(:purchase, link: @post.link)
    end

  context_ "#build_mailer_post_route" do
      subject { @mail.build_mailer_post_route(post: @post) }

  context_ "when slug is missing" do
        before do
          @post.update!(slug: nil)
        end

        it { is_expected.to be_nil }
      end

  context_ "when slug is present" do
  context_ "when not shown on the profile" do
          it { is_expected.to be_nil }
        end

  context_ "when shown on the profile" do
          before do
            @post.update!(shown_on_profile: true)
          end

          shared_examples "common route behavior" do
            it { is_expected.to eq(url) }

  context_ "when purchase is present" do
              subject { @mail.build_mailer_post_route(post: @post, purchase: @purchase) }

  test "sends the purchase id as parameter" do
                is_expected.to eq("#{url}?#{{ purchase_id: @purchase.external_id }.to_query}")
              end
            end
          end

  context_ "when user does not use custom domains" do
            let(:url) { "#{UrlService.domain_with_protocol}/#{@user.username}/p/#{@post.slug}" }

            include_examples "common route behavior"

  context_ "when user's username is missing" do
              let(:url) { "#{UrlService.domain_with_protocol}/#{@user.external_id}/p/#{@post.slug}" }

              before do
                @user.update!(username: nil)
              end

  test "passes the external_id as the username parameter" do
                is_expected.to eq(url)
              end
            end
          end

  context_ "when user is using custom domains" do
            let!(:custom_domain) { create(:custom_domain, domain: "example.com", user: @user) }
            let(:url) { "http://#{custom_domain.domain}/p/#{@post.slug}" }

            include_examples "common route behavior"
          end
        end
      end
    end
  end
end
