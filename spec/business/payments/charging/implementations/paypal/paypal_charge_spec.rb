# frozen_string_literal: true

require "spec_helper"
describe PaypalCharge do
  context "when order api is used" do
    context "when paypal transaction is present" do
      let(:order_details) do
        {
          "id" => "426572068V1934255",
          "intent" => "CAPTURE",
          "purchase_units" => [
            {
              "reference_id" => "P5ppE6H8XIjy2JSCgUhbAw==",
              "amount" => {
                "currency_code" => "USD",
                "value" => "19.50",
                "breakdown" => {
                  "item_total" => {
                    "currency_code" => "USD",
                    "value" => "15.00"
                  },
                  "shipping" => {
                    "currency_code" => "USD",
                    "value" => "3.00"
                  },
                  "handling" => {
                    "currency_code" => "USD",
                    "value" => "0.00"
                  },
                  "tax_total" => {
                    "currency_code" => "USD",
                    "value" => "1.50"
                  },
                  "insurance" => {
                    "currency_code" => "USD",
                    "value" => "0.00"
                  },
                  "shipping_discount" => {
                    "currency_code" => "USD",
                    "value" => "0.00"
                  },
                  "discount" => {
                    "currency_code" => "USD",
                    "value" => "0.00"
                  }
                }
              },
              "payee" => {
                "email_address" => "sb-c7jpx2385730@business.example.com",
                "merchant_id" => "MN7CSWD6RCNJ8"
              },
              "payment_instruction" => {
                "platform_fees" => [
                  {
                    "amount" => {
                      "currency_code" => "USD",
                      "value" => "0.75"
                    },
                    "payee" => {
                      "email_address" => "paypal-api-facilitator@gumroad.com",
                      "merchant_id" => "HU29XVVCZXNFN"
                    }
                  }
                ]
              },
              "description" => "The Works of Edgar Gumstein",
              "soft_descriptor" => "PAYPAL *JOHNDOESTES YO",
              "items" => [
                {
                  "name" => "The Works of Edgar Gumstein",
                  "unit_amount" => {
                    "currency_code" => "USD",
                    "value" => "5.00"
                  },
                  "tax" => {
                    "currency_code" => "USD",
                    "value" => "0.00"
                  },
                  "quantity" => "3",
                  "sku" => "aa"
                }
              ],
              "shipping" => {
                "name" => {
                  "full_name" => "Gumbot Gumstein"
                },
                "address" => {
                  "address_line_1" => "1 Main St",
                  "admin_area_2" => "San Jose",
                  "admin_area_1" => "CA",
                  "postal_code" => "95131",
                  "country_code" => "US"
                }
              },
              "payments" => {
                "captures" => [
                  {
                    "id" => "58003532R80972514",
                    "status" => "REFUNDED",
                    "amount" => {
                      "currency_code" => "USD",
                      "value" => "19.50"
                    },
                    "final_capture" => true,
                    "disbursement_mode" => "INSTANT",
                    "seller_protection" => {
                      "status" => "ELIGIBLE",
                      "dispute_categories" => [
                        {},
                        {}
                      ]
                    },
                    "seller_receivable_breakdown" => {
                      "gross_amount" => {
                        "currency_code" => "USD",
                        "value" => "19.50"
                      },
                      "paypal_fee" => {
                        "currency_code" => "USD",
                        "value" => "0.87"
                      },
                      "platform_fees" => [
                        {
                          "amount" => {
                            "currency_code" => "USD",
                            "value" => "0.75"
                          },
                          "payee" => {
                            "merchant_id" => "HU29XVVCZXNFN"
                          }
                        }
                      ],
                      "net_amount" => {
                        "currency_code" => "USD",
                        "value" => "17.88"
                      }
                    },
                    "links" => [
                      {
                        "href" => "https://api.sandbox.paypal.com/v2/payments/captures/58003532R80972514",
                        "rel" => "self",
                        "method" => "GET"
                      },
                      {
                        "href" => "https://api.sandbox.paypal.com/v2/payments/captures/58003532R80972514/refund",
                        "rel" => "refund",
                        "method" => "POST"
                      },
                      {
                        "href" => "https://api.sandbox.paypal.com/v2/checkout/orders/426572068V1934255",
                        "rel" => "up",
                        "method" => "GET"
                      }
                    ],
                    "create_time" => "2020-06-26T17:42:28Z",
                    "update_time" => "2020-06-26T19:23:02Z"
                  }
                ],
                "refunds" => [
                  {
                    "id" => "8A762400SC645253S",
                    "amount" => {
                      "currency_code" => "USD",
                      "value" => "19.50"
                    },
                    "seller_payable_breakdown" => {
                      "gross_amount" => {
                        "currency_code" => "USD",
                        "value" => "19.50"
                      },
                      "paypal_fee" => {
                        "currency_code" => "USD",
                        "value" => "0.57"
                      },
                      "platform_fees" => [
                        {
                          "amount" => {
                            "currency_code" => "USD",
                            "value" => "0.75"
                          }
                        }
                      ],
                      "net_amount" => {
                        "currency_code" => "USD",
                        "value" => "18.18"
                      },
                      "total_refunded_amount" => {
                        "currency_code" => "USD",
                        "value" => "19.50"
                      }
                    },
                    "status" => "COMPLETED",
                    "links" => [
                      {
                        "href" => "https://api.sandbox.paypal.com/v2/payments/refunds/8A762400SC645253S",
                        "rel" => "self",
                        "method" => "GET"
                      },
                      {
                        "href" => "https://api.sandbox.paypal.com/v2/payments/captures/58003532R80972514",
                        "rel" => "up",
                        "method" => "GET"
                      }
                    ],
                    "create_time" => "2020-06-26T12:23:02-07:00",
                    "update_time" => "2020-06-26T12:23:02-07:00"
                  }
                ]
              }
            },
            {
              "reference_id" => "bfi_30HLgGWL8H2wo_Gzlg==",
              "amount" => {
                "currency_code" => "USD",
                "value" => "12.00",
                "breakdown" => {
                  "item_total" => {
                    "currency_code" => "USD",
                    "value" => "12.00"
                  },
                  "shipping" => {
                    "currency_code" => "USD",
                    "value" => "0.00"
                  },
                  "handling" => {
                    "currency_code" => "USD",
                    "value" => "0.00"
                  },
                  "tax_total" => {
                    "currency_code" => "USD",
                    "value" => "0.00"
                  },
                  "insurance" => {
                    "currency_code" => "USD",
                    "value" => "0.00"
                  },
                  "shipping_discount" => {
                    "currency_code" => "USD",
                    "value" => "0.00"
                  }
                }
              },
              "payee" => {
                "email_address" => "sb-byx2u2205460@business.example.com",
                "merchant_id" => "B66YJBBNCRW6L"
              },
              "payment_instruction" => {
                "platform_fees" => [
                  {
                    "amount" => {
                      "currency_code" => "USD",
                      "value" => "0.60"
                    },
                    "payee" => {
                      "merchant_id" => "2124944962663691396"
                    }
                  }
                ]
              },
              "description" => "The Works of Edgar Gumstein",
              "soft_descriptor" => "PAYPAL *JOHNDOESTES YO",
              "items" => [
                {
                  "name" => "The Works of Edgar Gumstein",
                  "unit_amount" => {
                    "currency_code" => "USD",
                    "value" => "6.00"
                  },
                  "tax" => {
                    "currency_code" => "USD",
                    "value" => "0.00"
                  },
                  "quantity" => "2",
                  "sku" => "bb"
                }
              ],
              "shipping" => {
                "name" => {
                  "full_name" => "Gumbot Gumstein"
                },
                "address" => {
                  "address_line_1" => "1 Main St",
                  "admin_area_2" => "San Jose",
                  "admin_area_1" => "CA",
                  "postal_code" => "95131",
                  "country_code" => "US"
                }
              },
              "payments" => {
                "captures" => [
                  {
                    "id" => "4FF7716038572874Y",
                    "status" => "PARTIALLY_REFUNDED",
                    "amount" => {
                      "currency_code" => "USD",
                      "value" => "12.00"
                    },
                    "final_capture" => true,
                    "disbursement_mode" => "INSTANT",
                    "seller_protection" => {
                      "status" => "ELIGIBLE",
                      "dispute_categories" => [
                        {},
                        {}
                      ]
                    },
                    "seller_receivable_breakdown" => {
                      "gross_amount" => {
                        "currency_code" => "USD",
                        "value" => "12.00"
                      },
                      "paypal_fee" => {
                        "currency_code" => "USD",
                        "value" => "0.65"
                      },
                      "platform_fees" => [
                        {
                          "amount" => {
                            "currency_code" => "USD",
                            "value" => "0.60"
                          },
                          "payee" => {
                            "merchant_id" => "HU29XVVCZXNFN"
                          }
                        }
                      ],
                      "net_amount" => {
                        "currency_code" => "USD",
                        "value" => "10.75"
                      }
                    },
                    "links" => [
                      {
                        "href" => "https://api.sandbox.paypal.com/v2/payments/captures/4FF7716038572874Y",
                        "rel" => "self",
                        "method" => "GET"
                      },
                      {
                        "href" => "https://api.sandbox.paypal.com/v2/payments/captures/4FF7716038572874Y/refund",
                        "rel" => "refund",
                        "method" => "POST"
                      },
                      {
                        "href" => "https://api.sandbox.paypal.com/v2/checkout/orders/426572068V1934255",
                        "rel" => "up",
                        "method" => "GET"
                      }
                    ],
                    "create_time" => "2020-06-26T17:42:32Z",
                    "update_time" => "2020-06-26T19:23:11Z"
                  }
                ],
                "refunds" => [
                  {
                    "id" => "92M0058559975814A",
                    "amount" => {
                      "currency_code" => "USD",
                      "value" => "2.00"
                    },
                    "seller_payable_breakdown" => {
                      "gross_amount" => {
                        "currency_code" => "USD",
                        "value" => "2.00"
                      },
                      "paypal_fee" => {
                        "currency_code" => "USD",
                        "value" => "0.06"
                      },
                      "platform_fees" => [
                        {
                          "amount" => {
                            "currency_code" => "USD",
                            "value" => "0.10"
                          }
                        }
                      ],
                      "net_amount" => {
                        "currency_code" => "USD",
                        "value" => "1.84"
                      },
                      "total_refunded_amount" => {
                        "currency_code" => "USD",
                        "value" => "2.00"
                      }
                    },
                    "status" => "COMPLETED",
                    "links" => [
                      {
                        "href" => "https://api.sandbox.paypal.com/v2/payments/refunds/92M0058559975814A",
                        "rel" => "self",
                        "method" => "GET"
                      },
                      {
                        "href" => "https://api.sandbox.paypal.com/v2/payments/captures/4FF7716038572874Y",
                        "rel" => "up",
                        "method" => "GET"
                      }
                    ],
                    "create_time" => "2020-06-26T12:23:11-07:00",
                    "update_time" => "2020-06-26T12:23:11-07:00"
                  }
                ]
              }
            }
          ],
          "payer" => {
            "name" => {
              "given_name" => "Gumbot",
              "surname" => "Gumstein"
            },
            "email_address" => "paypal-gr-integspecs@gumroad.com",
            "payer_id" => "92SVVJSWYT72E",
            "phone" => {
              "phone_number" => {
                "national_number" => "4085146918"
              }
            },
            "address" => {
              "country_code" => "US"
            }
          },
          "update_time" => "2020-06-26T19:23:02Z",
          "links" => [
            {
              "href" => "https://api.sandbox.paypal.com/v2/checkout/orders/426572068V1934255",
              "rel" => "self",
              "method" => "GET"
            }
          ],
          "status" => "COMPLETED"
        }
      end

      subject do
        PaypalCharge.new(paypal_transaction_id: "58003532R80972514",
                         order_api_used: true,
                         payment_details: order_details)
      end

      it "sets all the properties of the order" do
        is_expected.to have_attributes(charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                       id: "58003532R80972514",
                                       fee: 87.0,
                                       paypal_payment_status: "REFUNDED",
                                       refunded: true,
                                       flow_of_funds: nil,
                                       card_fingerprint: "paypal_paypal-gr-integspecs@gumroad.com",
                                       card_country: "US",
                                       card_type: "paypal",
                                       card_visual: "paypal-gr-integspecs@gumroad.com")
      end

      it "does not throw error if paypal_fee value is absent" do
        payment_details = order_details.tap { |order| order["purchase_units"][0]["payments"]["captures"][0]["seller_receivable_breakdown"].delete("paypal_fee") }

        charge = PaypalCharge.new(paypal_transaction_id: "58003532R80972514",
                                  order_api_used: true,
                                  payment_details:)

        expect(charge).to have_attributes(charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                          id: "58003532R80972514",
                                          fee: nil,
                                          paypal_payment_status: "REFUNDED",
                                          refunded: true,
                                          flow_of_funds: nil,
                                          card_fingerprint: "paypal_paypal-gr-integspecs@gumroad.com",
                                          card_country: "US",
                                          card_type: "paypal",
                                          card_visual: "paypal-gr-integspecs@gumroad.com")
      end
    end

    context "when paypal transaction is not present" do
      subject do
        PaypalCharge.new(paypal_transaction_id: nil, order_api_used: true)
      end

      it "doesn't set order API property" do
        is_expected.to have_attributes(charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                       id: nil,
                                       fee: nil,
                                       paypal_payment_status: nil,
                                       refunded: nil,
                                       flow_of_funds: nil,
                                       card_fingerprint: nil,
                                       card_country: nil,
                                       card_type: nil,
                                       card_visual: nil)
      end
    end
  end

  context "when express checkout api is used" do
    describe "with payment and payer info passed in" do
      let :paypal_payment_info do
        paypal_payment_info = PayPal::SDK::Merchant::DataTypes::PaymentInfoType.new
        paypal_payment_info.PaymentStatus = PaypalApiPaymentStatus::REFUNDED
        paypal_payment_info.GrossAmount.value = "10.00"
        paypal_payment_info.GrossAmount.currencyID = "USD"
        paypal_payment_info.FeeAmount.value = "1.00"
        paypal_payment_info.FeeAmount.currencyID = "USD"
        paypal_payment_info
      end

      let :paypal_payer_info do
        paypal_payer_info = PayPal::SDK::Merchant::DataTypes::PayerInfoType.new
        paypal_payer_info.Payer = "paypal-buyer@gumroad.com"
        paypal_payer_info.PayerID = "sample-fingerprint-source"
        paypal_payer_info.PayerCountry = Compliance::Countries::USA.alpha2
        paypal_payer_info
      end

      it "populates the required payment info and optional payer info" do
        paypal_charge = PaypalCharge.new(paypal_transaction_id: "5SP884803B810025T",
                                         order_api_used: false,
                                         payment_details: {
                                           paypal_payment_info:,
                                           paypal_payer_info:
                                         })

        expect(paypal_charge).to_not be(nil)
        expect(paypal_charge.id).to eq("5SP884803B810025T")
        expect(paypal_charge.refunded).to be(true)
        expect(paypal_charge.paypal_payment_status).to eq("Refunded")
        expect(paypal_charge.fee).to eq(100)

        expect(paypal_charge.card_fingerprint).to eq("paypal_sample-fingerprint-source")
        expect(paypal_charge.card_type).to eq(CardType::PAYPAL)
        expect(paypal_charge.card_country).to eq(Compliance::Countries::USA.alpha2)
      end

      it "populates the required payment and does not set payer fields if payload is not passed in" do
        paypal_charge = PaypalCharge.new(paypal_transaction_id: "5SP884803B810025T",
                                         order_api_used: false,
                                         payment_details: {
                                           paypal_payment_info:
                                         })

        expect(paypal_charge).to_not be(nil)
        expect(paypal_charge.id).to eq("5SP884803B810025T")
        expect(paypal_charge.refunded).to be(true)
        expect(paypal_charge.paypal_payment_status).to eq("Refunded")
        expect(paypal_charge.fee).to eq(100)

        expect(paypal_charge.card_fingerprint).to be(nil)
        expect(paypal_charge.card_type).to be(nil)
        expect(paypal_charge.card_country).to be(nil)
      end

      it "sets the refund states based on the PayPal PaymentInfo PaymentStatus" do
        paypal_payment_info.PaymentStatus = PaypalApiPaymentStatus::COMPLETED
        paypal_charge = PaypalCharge.new(paypal_transaction_id: "5SP884803B810025T",
                                         order_api_used: false,
                                         payment_details: {
                                           paypal_payment_info:
                                         })

        expect(paypal_charge.refunded).to be(false)
        expect(paypal_charge.paypal_payment_status).to eq("Completed")

        paypal_payment_info.PaymentStatus = "Refunded"
        paypal_charge = PaypalCharge.new(paypal_transaction_id: "5SP884803B810025T",
                                         order_api_used: false,
                                         payment_details: {
                                           paypal_payment_info:
                                         })

        expect(paypal_charge.refunded).to be(true)

        paypal_payment_info.PaymentStatus = PaypalApiPaymentStatus::REVERSED
        paypal_charge = PaypalCharge.new(paypal_transaction_id: "5SP884803B810025T",
                                         order_api_used: false,
                                         payment_details: {
                                           paypal_payment_info:
                                         })

        expect(paypal_charge.refunded).to be(false)
      end

      it "does not have a flow of funds" do
        paypal_charge = PaypalCharge.new(paypal_transaction_id: "5SP884803B810025T",
                                         order_api_used: false,
                                         payment_details: {
                                           paypal_payment_info:
                                         })
        expect(paypal_charge.flow_of_funds).to be_nil
      end
    end
  end
end
