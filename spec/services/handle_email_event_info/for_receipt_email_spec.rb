# frozen_string_literal: true

describe HandleEmailEventInfo::ForReceiptEmail do
  let!(:preorder) { create(:preorder) }
  let(:purchase) { create(:purchase) }

  def handler_class_for(email_provider)
    case email_provider
    when :sendgrid then HandleSendgridEventJob
    when :resend then HandleResendEventJob
    end
  end

  describe ".perform" do
    RSpec.shared_examples "handles bounced event type" do |email_provider|
      context "when CustomerEmailInfo doesn't exist" do
        it "creates a new email info and mark it as bounced" do
          travel_to(Time.current) do
            handler_class_for(email_provider).new.perform(params)
          end

          expect(CustomerEmailInfo.count).to eq 1
          expect(CustomerEmailInfo.last.state).to eq "bounced"
          expect(CustomerEmailInfo.last.email_name).to eq mailer_method
        end
      end

      context "when CustomerEmailInfo exists" do
        let!(:email_info) { create(:customer_email_info, email_name: mailer_method, purchase:) }

        it "marks it as bounced and deletes the follower" do
          travel_to(Time.current) do
            handler_class_for(email_provider).new.perform(params)
          end

          expect(CustomerEmailInfo.count).to eq 1
          expect(email_info.reload.state).to eq "bounced"
          expect(follower.reload).to be_deleted
        end
      end
    end

    RSpec.shared_examples "handles delivered event type" do |email_provider|
      context "when CustomerEmailInfo doesn't exist" do
        it "creates a new email info and mark it as delivered" do
          travel_to(Time.current) do
            handler_class_for(email_provider).new.perform(params)
          end

          expect(CustomerEmailInfo.count).to eq 1
          expect(CustomerEmailInfo.last.state).to eq "delivered"
          if email_provider == :resend
            expect(CustomerEmailInfo.last.delivered_at.change(usec: 0)).to eq(Time.zone.parse(params["data"]["created_at"]).change(usec: 0))
          else
            expect(CustomerEmailInfo.last.delivered_at).to eq(Time.zone.at(params["_json"].first["timestamp"]))
          end
        end
      end

      context "when CustomerEmailInfo exists" do
        let!(:email_info) { create(:customer_email_info, email_name: mailer_method, purchase:) }

        it "marks it as delivered" do
          travel_to(Time.current) do
            handler_class_for(email_provider).new.perform(params)
          end

          expect(CustomerEmailInfo.count).to eq 1
          expect(email_info.reload.state).to eq "delivered"
          if email_provider == :resend
            expect(email_info.reload.delivered_at.change(usec: 0)).to eq(Time.zone.parse(params["data"]["created_at"]).change(usec: 0))
          else
            expect(email_info.reload.delivered_at).to eq(Time.zone.at(params["_json"].first["timestamp"]))
          end
        end
      end
    end

    RSpec.shared_examples "handles open event type" do |email_provider|
      context "when CustomerEmailInfo doesn't exist" do
        it "creates a new email info and mark it as opened" do
          travel_to(Time.current) do
            handler_class_for(email_provider).new.perform(params)
          end

          expect(CustomerEmailInfo.count).to eq 1
          expect(CustomerEmailInfo.last.state).to eq "opened"
          if email_provider == :resend
            expect(CustomerEmailInfo.last.opened_at.change(usec: 0)).to eq(Time.zone.parse(params["data"]["created_at"]).change(usec: 0))
          else
            expect(CustomerEmailInfo.last.opened_at).to eq(Time.zone.at(params["_json"].first["timestamp"]))
          end
        end
      end

      context "when CustomerEmailInfo exists" do
        let!(:email_info) { create(:customer_email_info, email_name: mailer_method, purchase:) }

        it "marks it as opened" do
          travel_to(Time.current) do
            handler_class_for(email_provider).new.perform(params)
          end

          expect(CustomerEmailInfo.count).to eq 1
          expect(email_info.reload.state).to eq "opened"
          if email_provider == :resend
            expect(email_info.reload.opened_at.change(usec: 0)).to eq(Time.zone.parse(params["data"]["created_at"]).change(usec: 0))
          else
            expect(email_info.reload.opened_at).to eq(Time.zone.at(params["_json"].first["timestamp"]))
          end
        end
      end
    end

    RSpec.shared_examples "handles spamreport event type" do |email_provider|
      context "when CustomerEmailInfo doesn't exist" do
        it "unsubscribes the buyer of the purchase" do
          another_product = create(:product, user: purchase.seller)
          another_purchase = create(:purchase, link: another_product, email: purchase.email)

          if email_provider == :resend
            expect do
              handler_class_for(email_provider).new.perform(params)
            end.not_to change {
              [purchase.reload.can_contact, another_purchase.reload.can_contact]
            }
          else
            expect do
              handler_class_for(email_provider).new.perform(params)
            end.to change {
              [purchase.reload.can_contact, another_purchase.reload.can_contact]
            }.from([true, true]).to([false, false])
          end
        end
      end

      context "when CustomerEmailInfo exists" do
        let!(:email_info) { create(:customer_email_info, email_name: mailer_method, purchase:) }

        it "unsubscribes the buyer of the purchase and cancels the follower" do
          follower&.destroy
          follower = create(:active_follower, email: purchase.email, followed_id: purchase.seller_id)
          another_product = create(:product, user: purchase.seller)
          another_purchase = create(:purchase, link: another_product, email: purchase.email)

          if email_provider == :resend
            expect do
              handler_class_for(email_provider).new.perform(params)
            end.not_to change {
              [purchase.reload.can_contact, another_purchase.reload.can_contact, follower.reload.alive?]
            }
          else
            expect do
              handler_class_for(email_provider).new.perform(params)
            end.to change {
              [purchase.reload.can_contact, another_purchase.reload.can_contact, follower.reload.alive?]
            }.from([true, true, true]).to([false, false, false])
          end
        end
      end
    end

    [EmailEventInfo::RECEIPT_MAILER_METHOD, EmailEventInfo::PREORDER_RECEIPT_MAILER_METHOD].each do |mailer_method|
      describe "#{mailer_method} method" do
        let(:mailer_method) { mailer_method }
        let(:mailer_args) do
          if mailer_method == EmailEventInfo::RECEIPT_MAILER_METHOD
            "[#{purchase.id}]"
          else
            "[#{preorder.id}]"
          end
        end

        before do
          preorder.purchases << purchase if mailer_method == EmailEventInfo::PREORDER_RECEIPT_MAILER_METHOD
        end

        context "with SendGrid" do
          let!(:follower) { create(:active_follower, email: purchase.email, followed_id: purchase.seller_id) }

          context "with type and identifier unique args" do
            let(:params) do
              {
                "_json" => [{
                  "event" => event_type,
                  "type" => "CustomerMailer.#{mailer_method}",
                  "identifier" => mailer_args
                }]
              }
            end

            context "with bounce event" do
              let(:event_type) { EmailEventInfo::EVENTS[:bounced][MailerInfo::EMAIL_PROVIDER_SENDGRID] }
              it_behaves_like "handles bounced event type", :sendgrid
            end

            context "with delivered event" do
              let(:event_type) { EmailEventInfo::EVENTS[:delivered][MailerInfo::EMAIL_PROVIDER_SENDGRID] }
              before { params["_json"].first["timestamp"] = 1.day.ago.to_i }
              it_behaves_like "handles delivered event type", :sendgrid
            end

            context "with open event" do
              let(:event_type) { EmailEventInfo::EVENTS[:opened][MailerInfo::EMAIL_PROVIDER_SENDGRID] }
              before { params["_json"].first["timestamp"] = 1.hour.ago.to_i }
              it_behaves_like "handles open event type", :sendgrid
            end

            context "with spamreport event" do
              let(:event_type) { EmailEventInfo::EVENTS[:complained][MailerInfo::EMAIL_PROVIDER_SENDGRID] }
              before { params["_json"].first["timestamp"] = 1.hour.ago.to_i }
              it_behaves_like "handles spamreport event type", :sendgrid
            end
          end

          context "with records as individual unique args" do
            let(:params) do
              {
                "_json" => [{
                  "event" => event_type,
                  "mailer_class" => "CustomerMailer",
                  "mailer_method" => mailer_method,
                  "mailer_args" => mailer_args,
                  "purchase_id" => purchase.id.to_s,
                }]
              }
            end

            context "with bounce event" do
              let(:event_type) { EmailEventInfo::EVENTS[:bounced][MailerInfo::EMAIL_PROVIDER_SENDGRID] }
              it_behaves_like "handles bounced event type", :sendgrid
            end

            context "with delivered event" do
              let(:event_type) { EmailEventInfo::EVENTS[:delivered][MailerInfo::EMAIL_PROVIDER_SENDGRID] }
              before { params["_json"].first["timestamp"] = 1.day.ago.to_i }
              it_behaves_like "handles delivered event type", :sendgrid
            end

            context "with open event" do
              let(:event_type) { EmailEventInfo::EVENTS[:opened][MailerInfo::EMAIL_PROVIDER_SENDGRID] }
              before { params["_json"].first["timestamp"] = 1.day.ago.to_i }
              it_behaves_like "handles open event type", :sendgrid
            end

            context "with spamreport event" do
              let(:event_type) { EmailEventInfo::EVENTS[:complained][MailerInfo::EMAIL_PROVIDER_SENDGRID] }
              before { params["_json"].first["timestamp"] = 1.hour.ago.to_i }
              it_behaves_like "handles spamreport event type", :sendgrid
            end
          end
        end

        context "with Resend" do
          let!(:follower) { create(:active_follower, email: purchase.email, followed_id: purchase.seller_id) }
          let(:params) do
            {
              "data" => {
                "created_at" => "2025-01-02 00:14:11.140106+00",
                "to" => ["customer@example.com"],
                "headers" => [
                  {
                    "name" => MailerInfo.header_name(:mailer_class),
                    "value" => MailerInfo.encrypt("CustomerMailer")
                  },
                  {
                    "name" => MailerInfo.header_name(:mailer_method),
                    "value" => MailerInfo.encrypt(mailer_method)
                  },
                  {
                    "name" => MailerInfo.header_name(:mailer_args),
                    "value" => MailerInfo.encrypt(mailer_args)
                  },
                  {
                    "name" => MailerInfo.header_name(:purchase_id),
                    "value" => MailerInfo.encrypt(purchase.id.to_s)
                  }
                ],
              },
              "type" => event_type
            }
          end

          context "with bounce event" do
            let(:event_type) { EmailEventInfo::EVENTS[:bounced][MailerInfo::EMAIL_PROVIDER_RESEND] }
            it_behaves_like "handles bounced event type", :resend
          end

          context "with delivered event" do
            let(:event_type) { EmailEventInfo::EVENTS[:delivered][MailerInfo::EMAIL_PROVIDER_RESEND] }
            it_behaves_like "handles delivered event type", :resend
          end

          context "with open event" do
            let(:event_type) { EmailEventInfo::EVENTS[:opened][MailerInfo::EMAIL_PROVIDER_RESEND] }
            it_behaves_like "handles open event type", :resend
          end

          context "with spamreport event" do
            let(:event_type) { EmailEventInfo::EVENTS[:complained][MailerInfo::EMAIL_PROVIDER_RESEND] }
            it_behaves_like "handles spamreport event type", :resend
          end
        end
      end
    end

    describe "receipt - for a Charge", :vcr do
      let(:purchase) { create(:purchase) }
      let(:charge) { create(:charge, purchases: [purchase]) }
      let(:order) { charge.order }
      let!(:follower) { create(:active_follower, email: purchase.email, followed_id: purchase.seller_id) }

      before do
        order.purchases << purchase
      end

      context "with SendGrid" do
        let(:params) do
          {
            "_json" => [{
              "event" => "bounce",
              "mailer_class" => "CustomerMailer",
              "mailer_method" => "receipt",
              "mailer_args" => "[nil,#{charge.id}]",
              "charge_id" => charge.id.to_s,
            }]
          }
        end

        context "when CustomerEmailInfo doesn't exist" do
          it "creates a new email info and marks it as bounced" do
            travel_to(Time.current) do
              HandleSendgridEventJob.new.perform(params)
            end

            expect(CustomerEmailInfo.count).to eq 1
            email_info = CustomerEmailInfo.last
            expect(email_info.state).to eq "bounced"
            expect(email_info.email_name).to eq "receipt"
            expect(email_info.charge_id).to eq charge.id
          end
        end

        context "when CustomerEmailInfo exists" do
          let!(:email_info) do
            create(
              :customer_email_info,
              purchase_id: nil,
              email_name: "receipt",
              email_info_charge_attributes: { charge_id: charge.id }
            )
          end

          it "marks it as bounced and deletes the follower" do
            travel_to(Time.current) do
              HandleSendgridEventJob.new.perform(params)
            end

            expect(CustomerEmailInfo.count).to eq 1
            expect(email_info.reload.state).to eq "bounced"
            expect(follower.reload).to be_deleted
          end
        end
      end

      context "with Resend" do
        let(:params) do
          {
            "data" => {
              "created_at" => "2025-01-02 00:14:11.140106+00",
              "to" => ["customer@example.com"],
              "headers" => [
                {
                  "name" => MailerInfo.header_name(:mailer_class),
                  "value" => MailerInfo.encrypt("CustomerMailer")
                },
                {
                  "name" => MailerInfo.header_name(:mailer_method),
                  "value" => MailerInfo.encrypt("receipt")
                },
                {
                  "name" => MailerInfo.header_name(:mailer_args),
                  "value" => MailerInfo.encrypt("[nil,#{charge.id}]")
                },
                {
                  "name" => MailerInfo.header_name(:charge_id),
                  "value" => MailerInfo.encrypt(charge.id.to_s)
                }
              ],
            },
            "type" => EmailEventInfo::EVENTS[:bounced][MailerInfo::EMAIL_PROVIDER_RESEND]
          }
        end

        context "when CustomerEmailInfo doesn't exist" do
          it "creates a new email info and marks it as bounced" do
            travel_to(Time.current) do
              HandleResendEventJob.new.perform(params)
            end

            expect(CustomerEmailInfo.count).to eq 1
            email_info = CustomerEmailInfo.last
            expect(email_info.state).to eq "bounced"
            expect(email_info.email_name).to eq "receipt"
            expect(email_info.charge_id).to eq charge.id
          end
        end

        context "when CustomerEmailInfo exists" do
          let!(:email_info) do
            create(
              :customer_email_info,
              purchase_id: nil,
              email_name: "receipt",
              email_info_charge_attributes: { charge_id: charge.id }
            )
          end

          it "marks it as bounced and deletes the follower" do
            travel_to(Time.current) do
              HandleResendEventJob.new.perform(params)
            end

            expect(CustomerEmailInfo.count).to eq 1
            expect(email_info.reload.state).to eq "bounced"
            expect(follower.reload).to be_deleted
          end
        end
      end
    end

    describe "refund" do
      before do
        expect(CreatorContactingCustomersEmailInfo.count).to eq 0
      end

      let(:params) do
        {
          "_json" => [{
            "event" => "bounce",
            "type" => "CustomerMailer.refund",
            "identifier" => "[#{purchase.id}]"
          }]
        }
      end

      it "does not create a new email info" do
        travel_to(Time.current) do
          HandleSendgridEventJob.new.perform(params)
        end

        expect(CustomerEmailInfo.count).to eq 0
      end
    end
  end
end
