# frozen_string_literal: true

require "spec_helper"

describe "Collaborators", type: :system, js: true do
  describe "seller view" do
    let(:seller) { create(:user) }
    before { login_as seller }

    context "viewing collaborators" do
      context "when there are none" do
        it "displays a placeholder message" do
          visit collaborators_path

          expect(page).to have_title("Cộng tác viên")
          expect(page).to have_selector("h1", text: "Cộng tác viên")
          expect(page).to have_selector("h2", text: "Chưa có cộng tác viên nào")
          expect(page).to have_selector("h4", text: "Chia sẻ doanh thu của bạn với những người đã giúp tạo ra sản phẩm của bạn.")
        end
      end

      context "when there are some" do
        let(:product_one) { create(:product, user: seller, name: "First product") }
        let(:product_two) { create(:product, user: seller, name: "Second product") }
        let(:product_three) { create(:product, user: seller, name: "Third product") }
        let(:product_four) { create(:product, user: seller, name: "Fourth product") }
        let(:product_five) { create(:product, user: seller, name: "Fifth product") }
        let!(:collaborator_one) do
          co = create(:collaborator, seller:)
          co.product_affiliates.create!(product: product_one, affiliate_basis_points: 50_00)
          co.product_affiliates.create!(product: product_two, affiliate_basis_points: 35_00)
          co
        end
        let!(:collaborator_two) do
          affiliate_user = create(:user, payment_address: nil)
          create(:collaborator, seller:, affiliate_user:)
        end
        let!(:collaborator_three) { create(:collaborator, seller:, products: [product_three,]) }
        let!(:collaborator_four) do
          create(:collaborator, :with_pending_invitation, seller:, products: [product_four, product_five])
        end

        it "displays a list of collaborators" do
          visit collaborators_path

          [
            {
              "Name" => collaborator_one.affiliate_user.username,
              "Products" => "2 products",
              "Cut" => "35% - 50%",
              "Status" => "Đã chấp nhận"
            },
            {
              "Name" => collaborator_two.affiliate_user.username,
              "Products" => "None",
              "Cut" => "30%",
              "Status" => "Đã chấp nhận"
            },
            {
              "Name" => collaborator_three.affiliate_user.username,
              "Products" => product_three.name,
              "Cut" => "30%",
              "Status" => "Đã chấp nhận"
            },
            {
              "Name" => collaborator_four.affiliate_user.username,
              "Products" => "2 products",
              "Cut" => "30%",
              "Status" => "Đang chờ xử lý"
            },
          ].each do |row|
            expect(page).to have_table_row(row)
          end
        end



        it "displays details about a collaborator" do
          create(:merchant_account, user: collaborator_one.affiliate_user)
          create(:ach_account, user: collaborator_one.affiliate_user, stripe_bank_account_id: "ba_bankaccountid")

          visit collaborators_path

          find(:table_row, { "Name" => collaborator_one.affiliate_user.username, "Products" => "2 products", "Cut" => "35% - 50%" }).click
          within_modal collaborator_one.affiliate_user.name do
            expect(page).to have_text(collaborator_one.affiliate_user.email)
            expect(page).to have_text(product_one.name)
            expect(page).to have_text(product_two.name)
            expect(page).to have_text("35%")
            expect(page).to have_text("50%")
            expect(page).to have_text("35%")
            expect(page).to have_text("50%")
            expect(page).to have_link("Chỉnh sửa")
            expect(page).to have_button("Xóa")
            expect(page).not_to have_text("Cộng tác viên sẽ không nhận được phần chia của họ cho đến khi họ thiết lập tài khoản thanh toán trong cài đặt Gumroad của mình.")
          end

          find(:table_row, { "Name" => collaborator_two.affiliate_user.username, "Products" => "None", "Cut" => "30%" }).click
          within_modal collaborator_two.affiliate_user.name do
            expect(page).to have_text(collaborator_two.affiliate_user.email)
            expect(page).to have_link("Chỉnh sửa")
            expect(page).to have_button("Xóa")
            expect(page).to have_text("Cộng tác viên sẽ không nhận được phần chia của họ cho đến khi họ thiết lập tài khoản thanh toán trong cài đặt Gumroad của mình.")
          end
        end
      end
    end

    context "adding a collaborator" do
      let!(:product1) { create(:product, user: seller, name: "First product") }
      let!(:product2) { create(:product, user: seller, name: "Second product") }
      let!(:product3) do
        create(:product, user: seller, name: "Third product").tap do |product|
          create(:product_affiliate, product:, affiliate: create(:user).global_affiliate)
        end
      end
      let!(:product4) do
        create(:product, user: seller, name: "Fourth product").tap do |product|
          create(:product_affiliate, product:, affiliate: create(:collaborator, seller:))
        end
      end
      let!(:product5) { create(:product, user: seller, name: "Fifth product", purchase_disabled_at: Time.current) }
      let!(:collaborating_user) { create(:user) }

      it "adds a collaborator for all visible products" do
        expect do
          visit collaborators_path
          click_on "Thêm cộng tác viên"

          expect(page).to have_title("Cộng tác viên")
          expect(page).to have_selector("h1", text: "Cộng tác viên mới")
          expect(page).to_not have_tab_button("Cộng tác viên")
          expect(page).to_not have_tab_button("Cộng tác")

          fill_in "email", with: "#{collaborating_user.email}  " # test trimming email
          uncheck "Hiển thị là người đồng sáng tạo", checked: true
          click_on "Thêm cộng tác viên"

          expect(page).to have_alert(text: "Changes saved!")
          expect(page).to have_current_path(collaborators_path)
        end.to change { seller.collaborators.count }.from(1).to(2)
           .and change { ProductAffiliate.count }.from(2).to(5)

        collaborator = seller.collaborators.last
        expect(collaborator.apply_to_all_products).to eq true
        expect(collaborator.affiliate_percentage).to eq 50
        expect(collaborator.dont_show_as_co_creator).to eq true
        expect(collaborator.products).to match_array [product1, product2, product3]

        [product1, product2, product3].each do |product|
          expect(product.reload.is_collab).to eq(true)
          pa = collaborator.product_affiliates.find_by(product:)
          expect(pa.affiliate_percentage).to eq 50
        end

        expect(page).to have_table_row(
          {
            "Name" => collaborator.affiliate_user.username,
            "Products" => "3 products",
            "Cut" => "50%",
            "Status" => "Đang chờ xử lý"
          }
        )
      end

      it "allows enabling different products with different cuts" do
        expect do
          visit new_collaborator_path

          fill_in "email", with: collaborating_user.email
          uncheck "Tất cả sản phẩm"
          within find(:table_row, { "Product" => product1.name }) do
            check product1.name
            fill_in "Percentage", with: 40
            uncheck "Hiển thị là người đồng sáng tạo", checked: true
          end
          within find(:table_row, { "Product" => product3.name }) do
            check product3.name
            fill_in "Percentage", with: 10
          end

          click_on "Thêm cộng tác viên"

          expect(page).to have_alert(text: "Changes saved!")
          expect(page).to have_current_path(collaborators_path)
        end.to change { seller.collaborators.count }.from(1).to(2)
           .and change { ProductAffiliate.count }.from(2).to(4)

        collaborator = seller.collaborators.last
        expect(collaborator.affiliate_user).to eq collaborating_user
        expect(collaborator.apply_to_all_products).to eq false
        expect(collaborator.affiliate_percentage).to eq 50
        expect(collaborator.dont_show_as_co_creator).to eq false

        pa = collaborator.product_affiliates.find_by(product: product1)
        expect(pa.affiliate_percentage).to eq 40
        expect(pa.dont_show_as_co_creator).to eq true

        pa = collaborator.product_affiliates.find_by(product: product3)
        expect(pa.affiliate_percentage).to eq 10
        expect(pa.dont_show_as_co_creator).to eq false

        expect(collaborator.product_affiliates.exists?(product: product2)).to eq false
      end

      it "does not allow creating a collaborator with invalid parameters" do
        visit new_collaborator_path

        # invalid email
        fill_in "email", with: "foo"
        click_on "Thêm cộng tác viên"
        expect(page).to have_alert(text: "Vui lòng nhập một email hợp lệ")

        # no user with that email
        fill_in "email", with: "foo@example.com"
        click_on "Thêm cộng tác viên"
        expect(page).to have_alert(text: "The email address isn't associated with a Gumroad account.")

        # no products selected
        fill_in "email", with: collaborating_user.email
        [product1, product2, product3].each do |product|
          within find(:table_row, { "Product" => product.name }) do
            uncheck product.name
          end
        end
        click_on "Thêm cộng tác viên"
        expect(page).to have_alert(text: "Phải chọn ít nhất một sản phẩm")

        # invalid default percent commission
        within find(:table_row, { "Product" => product1.name }) do
          check product1.name
        end
        within find(:table_row, { "Product" => "Tất cả sản phẩm" }) do
          fill_in "Percentage", with: 75
        end
        click_on "Thêm cộng tác viên"
        within find(:table_row, { "Product" => "Tất cả sản phẩm" }) do
          expect(find("fieldset.danger")).to have_field("Percentage")
        end
        expect(page).to have_alert(text: "Hoa hồng cộng tác viên phải từ 50% trở xuống")

        # invalid product percent commission
        uncheck "Tất cả sản phẩm"
        within find(:table_row, { "Product" => product1.name }) do
          check product1.name
          fill_in "Percentage", with: 75
        end
        click_on "Thêm cộng tác viên"
        within find(:table_row, { "Product" => product1.name }) do
          expect(find("fieldset.danger")).to have_field("Percentage")
        end
        expect(page).to have_alert(text: "Hoa hồng cộng tác viên phải từ 50% trở xuống")
        within find(:table_row, { "Product" => product1.name }) do
          fill_in "Percentage", with: 40
          expect(page).not_to have_selector("fieldset.danger")
          fill_in "Percentage", with: 0
        end
        click_on "Thêm cộng tác viên"
        within find(:table_row, { "Product" => product1.name }) do
          expect(find("fieldset.danger")).to have_field("Percentage")
        end
        expect(page).to have_alert(text: "Hoa hồng cộng tác viên phải từ 50% trở xuống")

        # missing default percent commission
        check "Tất cả sản phẩm"
        within find(:table_row, { "Product" => "Tất cả sản phẩm" }) do
          fill_in "Percentage", with: ""
        end
        click_on "Thêm cộng tác viên"
        within find(:table_row, { "Product" => "Tất cả sản phẩm" }) do
          expect(find("fieldset.danger")).to have_field("Percentage")
        end
        expect(page).to have_alert(text: "Hoa hồng cộng tác viên phải từ 50% trở xuống")

        # missing product percent commission
        uncheck "Tất cả sản phẩm"
        within find(:table_row, { "Product" => product1.name }) do
          check product1.name
          fill_in "Percentage", with: ""
          expect(page).to have_field("Percentage", placeholder: "50") # shows the default value as a placeholder
        end
        click_on "Thêm cộng tác viên"
        within find(:table_row, { "Product" => product1.name }) do
          expect(page).to have_field("Percentage", placeholder: "50") # shows the default value as a placeholder
          expect(find("fieldset.danger")).to have_field("Percentage")
        end
        expect(page).to have_alert(text: "Hoa hồng cộng tác viên phải từ 50% trở xuống")
      end

      it "does not allow adding a collaborator for ineligible products but does for unpublished products" do
        invisible_product = create(:product, user: seller, name: "Deleted product", deleted_at: 1.day.ago)

        visit new_collaborator_path
        expect(page).not_to have_content invisible_product.name
        expect(page).not_to have_content product4.name
        expect(page).not_to have_content product5.name

        check "Hiển thị sản phẩm chưa xuất bản và không đủ điều kiện"
        expect(page).to have_content product4.name
        expect(page).to have_content product5.name

        within find(:table_row, { "Product" => product4.name }) do
          expect(page).to have_unchecked_field(product4.name, disabled: true)
        end
        within find(:table_row, { "Product" => product5.name }) do
          expect(page).to have_checked_field(product5.name)
        end

        fill_in "email", with: collaborating_user.email
        uncheck "Tất cả sản phẩm"

        within find(:table_row, { "Product" => product2.name }) do
          check product2.name
        end
        within find(:table_row, { "Product" => product3.name }) do
          check product3.name
        end
        within find(:table_row, { "Product" => product4.name }) do
          expect(page).to have_unchecked_field(product4.name, disabled: true)
          expect(page).to have_content "Đã có cộng tác viên"
        end
        within find(:table_row, { "Product" => product5.name }) do
          check product5.name
        end

        expect do
          click_on "Thêm cộng tác viên"

          expect(page).to have_alert(text: "Changes saved!")
          expect(page).to have_current_path(collaborators_path)
        end.to change { seller.collaborators.count }.from(1).to(2)
           .and change { ProductAffiliate.count }.from(2).to(5)

        collaborator = seller.collaborators.last
        expect(collaborator.products).to match_array [product2, product3, product5]

        visit collaborators_path
        within :table_row, { "Name" => collaborator.affiliate_user.display_name } do
          click_on "Chỉnh sửa"
        end

        expect(page).to have_checked_field("Hiển thị sản phẩm chưa xuất bản và không đủ điều kiện")
        within find(:table_row, { "Product" => product5.name }) do
          expect(page).to have_checked_field(product5.name)
        end
      end

      it "disables affiliates when adding a collaborator to a product with affiliates" do
        affiliate = create(:direct_affiliate, seller:)
        affiliated_products = (1..12).map { |i| create(:product, user: seller, name: "Number #{i} affiliate product") }
        affiliate.products = affiliated_products

        visit new_collaborator_path
        expect do
          fill_in "email", with: collaborating_user.email

          affiliated_products.each do |product|
            within find(:table_row, { "Product" => product.name }) do
              expect(page).to have_content "Chọn sản phẩm này sẽ xóa tất cả các đơn vị liên kết của nó."
            end
          end

          click_on "Thêm cộng tác viên"

          expect(page).to have_modal("Xóa đơn vị liên kết?")
          within_modal("Xóa đơn vị liên kết?") do
            expect(page).to have_text("Các đơn vị liên kết sẽ bị xóa khỏi các sản phẩm sau:")
            affiliated_products.first(10).each do |product|
              expect(page).to have_text(product.name)
            end
            affiliated_products.last(2).each do |product|
              expect(page).not_to have_text(product.name)
            end
            expect(page).to have_text("và 2 người khác.")
            click_on "Không, hủy"
          end
          expect(page).not_to have_modal("Xóa đơn vị liên kết?")

          click_on "Thêm cộng tác viên"
          expect(page).to have_modal("Xóa đơn vị liên kết?")
          within_modal("Xóa đơn vị liên kết?") do
            click_on "Có, tiếp tục"
          end

          expect(page).to have_alert(text: "Changes saved!")
          expect(page).to have_current_path(collaborators_path)

          collaborator = seller.collaborators.last
          expect(collaborator.products).to match_array([product1, product2, product3] + affiliated_products)
        end.to change { seller.collaborators.count }.from(1).to(2)
           .and change { affiliate.reload.products.count }.from(12).to(0)
      end

      it "does not allow adding a collaborator if creator is using a Brazilian Stripe Connect account" do
        brazilian_stripe_account = create(:merchant_account_stripe_connect, user: seller, country: "BR")
        seller.update!(check_merchant_account_is_linked: true)
        expect(seller.merchant_account(StripeChargeProcessor.charge_processor_id)).to eq brazilian_stripe_account

        visit collaborators_path

        link = find_link("Add collaborator", inert: true)
        link.hover
        expect(link).to have_tooltip(text: "Collaborators with Brazilian Stripe accounts are not supported.")

        visit new_collaborator_path

        button = find_button("Add collaborator", disabled: true)
        button.hover
        expect(button).to have_tooltip(text: "Collaborators with Brazilian Stripe accounts are not supported.")
      end
    end

    it "allows deleting a collaborator" do
      collaborators = create_list(:collaborator, 2, seller:)
      product = create(:product, user: seller, is_collab: true)
      create(:product_affiliate, affiliate: collaborators.first, product:)

      visit collaborators_path
      within find(:table_row, { "Name" => collaborators.first.affiliate_user.username }) do
        click_on "Xóa"
      end
      expect(page).to have_alert(text: "The collaborator was removed successfully.")
      expect(collaborators.first.reload.deleted_at).to be_present
      expect(product.reload.is_collab).to eq false
      expect(page).to_not have_table_row({ "Name" => collaborators.first.affiliate_user.username })

      find(:table_row, { "Name" => collaborators.second.affiliate_user.username }).click
      within_modal collaborators.second.affiliate_user.username do
        click_on "Xóa"
      end
      wait_for_ajax
      expect(page).to have_alert(text: "The collaborator was removed successfully.")
      expect(page).to_not have_table_row({ "Name" => collaborators.second.affiliate_user.username })
      expect(collaborators.second.reload.deleted_at).to be_present
    end

    context "editing a collaborator" do
      let!(:product1) { create(:product, user: seller, name: "First product") }
      let!(:product2) { create(:product, user: seller, name: "Second product") }
      let!(:product3) { create(:product, user: seller, name: "Third product") }
      let!(:product4) { create(:product, user: seller, name: "Fourth product").tap { |product| create(:direct_affiliate, products: [product]) } }
      let!(:ineligible_product) { create(:product, user: seller, name: "Ineligible product").tap { |product| create(:collaborator, products: [product]) } }
      let!(:collaborator) { create(:collaborator, seller:, apply_to_all_products: true, affiliate_basis_points: 40_00, products: [product1, product2], dont_show_as_co_creator: true) }

      before do
        collaborator.product_affiliates.first.update!(dont_show_as_co_creator: true)
      end

      it "allows editing a collaborator" do
        expect do
          visit collaborators_path
          within :table_row, { "Name" => collaborator.affiliate_user.display_name } do
            click_on "Chỉnh sửa"
          end

          expect(page).to have_title("Cộng tác viên")
          expect(page).to have_selector("h1", text: collaborator.affiliate_user.display_name)
          expect(page).to_not have_tab_button("Cộng tác viên")
          expect(page).to_not have_tab_button("Cộng tác")

          # edit default commission
          within find(:table_row, { "Product" => "Tất cả sản phẩm" }) do
            expect(page).to have_checked_field("Tất cả sản phẩm")
            fill_in "Percentage", with: 30
          end

          # disable product 1
          within find(:table_row, { "Product" => product1.name }) do
            uncheck product1.name
          end

          # enable individual cuts
          uncheck "Tất cả sản phẩm"

          # show as co-creator & edit commission for product 2
          within find(:table_row, { "Product" => product2.name }) do
            check product2.name
            check "Hiển thị là người đồng sáng tạo", checked: false
            fill_in "Percentage", with: 25
          end

          # enable products 3 + 4
          within find(:table_row, { "Product" => product3.name }) do
            check product3.name
          end
          within find(:table_row, { "Product" => product4.name }) do
            expect(page).to have_content "Chọn sản phẩm này sẽ xóa tất cả các đơn vị liên kết của nó."
            check product4.name
            fill_in "Percentage", with: 45
          end

          check "Hiển thị sản phẩm chưa xuất bản và không đủ điều kiện"
          # cannot select ineligible product
          within find(:table_row, { "Product" => ineligible_product.name }) do
            have_unchecked_field(ineligible_product.name, disabled: true)
            expect(page).to have_content "Đã có cộng tác viên"
          end

          click_on "Lưu thay đổi"

          expect(page).to have_modal("Xóa đơn vị liên kết?")
          within_modal("Xóa đơn vị liên kết?") do
            expect(page).to have_text("Các đơn vị liên kết sẽ bị xóa khỏi các sản phẩm sau:")
            expect(page).to have_text(product4.name)
            click_on "Close"
          end
          expect(page).not_to have_modal("Xóa đơn vị liên kết?")

          click_on "Lưu thay đổi"
          expect(page).to have_modal("Xóa đơn vị liên kết?")
          within_modal("Xóa đơn vị liên kết?") do
            click_on "Có, tiếp tục"
          end

          expect(page).to have_alert(text: "Changes saved!")
          expect(page).to have_current_path(collaborators_path)
        end.to change { collaborator.products.count }.from(2).to(3)
           .and change { product1.reload.is_collab }.from(true).to(false)
           .and change { product4.direct_affiliates.count }.from(1).to(0)

        collaborator.reload
        expect(collaborator.affiliate_basis_points).to eq 30_00
        expect(collaborator.products).to match_array [product2, product3, product4]
        expect(collaborator.apply_to_all_products).to eq false
        product_2_collab = collaborator.product_affiliates.find_by(product: product2)
        expect(product_2_collab.dont_show_as_co_creator).to eq false
        expect(product_2_collab.affiliate_basis_points).to eq 25_00
        expect(collaborator.product_affiliates.find_by(product: product3).affiliate_basis_points).to eq 30_00
        expect(collaborator.product_affiliates.find_by(product: product4).affiliate_basis_points).to eq 45_00
      end
    end
  end
end
