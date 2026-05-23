# frozen_string_literal: true

require "test_helper"

class ReceiptPresenterMailSubjectTest < ActiveSupport::TestCase
  self.described_class = ReceiptPresenter::MailSubject
  self.rspec_metadata = { vcr: true }



  context_ ReceiptPresenter::MailSubject, :vcr do
    let(:product_one) { create(:product, name: "Product One") }
    let(:purchase_one) { create(:purchase, link: product_one) }
    let(:charge) { create(:charge, purchases: [purchase_one]) }
    let(:mail_subject) { described_class.build(chargeable) }

  context_ ".build" do
  context_ "with one purchase" do
        shared_examples "one purchase mail subject" do
  test "returns expected subject" do
            expect(mail_subject).to eq("You bought Product One!")
          end

  context_ "when the purchase is free" do
            let(:purchase_one) { create(:free_purchase) }

  test "returns free purchase subject" do
              expect(mail_subject).to eq("You got The Works of Edgar Gumstein!")
            end
          end

  context_ "when the purchase is a rental" do
            before { purchase_one.update!(is_rental: true) }

  test "returns rental purchase subject" do
              expect(mail_subject).to eq("You rented Product One!")
            end
          end

  context_ "when the purchase is for a subscription" do
            let(:product_one) { create(:membership_product, name: "Product One") }
            let(:purchase_one) { create(:membership_purchase, link: product_one) }

  test "returns subscription purchase subject" do
              expect(mail_subject).to eq("You've subscribed to Product One!")
            end

  context_ "when the purchase subscription is recurring" do
              before { purchase_one.update!(is_original_subscription_purchase: false) }

  test "returns recurring subscription purchase subject" do
                expect(mail_subject).to eq("Recurring charge for Product One.")
              end
            end

  context_ "when the purchase subscription is an upgrade" do
              before do
                purchase_one.update!(
                  is_original_subscription_purchase: false,
                  is_upgrade_purchase: true
                )
              end

  test "returns upgrade subscription subject" do
                expect(mail_subject).to eq("You've upgraded your membership for Product One!")
              end
            end
          end

  context_ "when the purchase is a gift" do
            let(:gift) do
              create(
                :gift,
                link: product_one,
                gifter_email: "gifter@example.com",
                giftee_email: "giftee@example.com"
              )
            end

  context_ "when is gift receiver purchase" do
              let(:purchase_one) do
                create(
                  :purchase,
                  link: gift.link,
                  gift_received: gift,
                  is_gift_receiver_purchase: true,
                )
              end

  test "returns gift receiver purchase subject" do
                expect(mail_subject).to eq("gifter@example.com bought Product One for you!")
              end

  context_ "when the gifter has provided a name" do
                before { purchase_one.update!(full_name: "Gifter Name") }

  test "returns gift receiver purchase subject with gifter name" do
                  expect(mail_subject).to eq("Gifter Name (gifter@example.com) bought Product One for you!")
                end
              end
            end

  context_ "when is gift sender purchase" do
              before do
                purchase_one.update!(is_gift_sender_purchase: true, gift_given: gift)
              end

  test "returns gift sender purchase subject" do
                expect(mail_subject).to eq("You bought giftee@example.com Product One!")
              end
            end

  context_ "when the purchase is a commission completion purchase" do
              before { purchase_one.update!(is_commission_completion_purchase: true) }

  test "returns commission completion purchase subject" do
                expect(mail_subject).to eq("Product One is ready for download!")
              end
            end
          end
        end

  context_ "when chargeable is a Purchase" do
          let(:chargeable) { purchase_one }

          it_behaves_like "one purchase mail subject"
        end

  context_ "when chargeable is a Charge" do
          let(:chargeable) { charge }

          it_behaves_like "one purchase mail subject"
        end
      end

  context_ "with two purchases" do
        let(:product_two) { create(:product, name: "Product Two") }
        let(:purchase_two) { create(:purchase, link: product_two) }
        let(:chargeable) { charge }

        before do
          charge.purchases << purchase_two
        end

  test "returns subject for two purchases" do
          expect(mail_subject).to eq("You bought Product One and Product Two")
        end
      end

  context_ "with more than two purchases" do
        let(:product_two) { create(:product, name: "Product Two") }
        let(:purchase_two) { create(:purchase, link: product_two) }
        let(:product_three) { create(:product, name: "Product Three") }
        let(:purchase_three) { create(:purchase, link: product_three) }
        let(:chargeable) { charge }

        before do
          charge.purchases << purchase_two
          charge.purchases << purchase_three
        end

  test "returns subject for more than two purchases" do
          expect(mail_subject).to eq("You bought Product One and 2 more products")
        end
      end
    end
  end
end
