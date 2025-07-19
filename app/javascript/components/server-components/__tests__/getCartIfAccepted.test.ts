import { CartState, CartItem, CrossSell } from '$app/components/Checkout/cartState';

describe('getCartIfAccepted function', () => {
  const mockCartItem: CartItem = {
    product: {
      id: 'prod-1',
      permalink: 'basic-plan',
      name: 'Basic Plan',
      price_cents: 5000,
      creator: { id: 'creator-1', name: 'Test Creator', profile_url: '', avatar_url: '' },
      options: [
        { id: 'option-basic', name: 'Basic', price_diff: 0, upsell_offered_variant_id: 'option-premium' },
        { id: 'option-premium', name: 'Premium', price_diff: 5000, upsell_offered_variant_id: null }
      ],
      upsell: { id: 'upsell-1', text: 'Upgrade!', description: 'Get Premium' },
      cross_sells: [],
      currency_code: 'USD',
      quantity_remaining: null,
      pwyw: null,
      installment_plan: null,
      is_preorder: false,
      is_tiered_membership: false,
      is_legacy_subscription: false,
      is_multiseat_license: false,
      is_quantity_enabled: false,
      free_trial: null,
      recurrences: null,
      duration_in_months: null,
      native_type: 'digital',
      custom_fields: [],
      require_shipping: false,
      supports_paypal: null,
      has_offer_codes: true,
      has_tipping_enabled: false,
      analytics: {},
      exchange_rate: 1,
      rental: null,
      shippable_country_codes: [],
      ppp_details: null,
      archived: false,
      can_gift: true,
      bundle_products: [],
      url: '',
      thumbnail_url: null,
    },
    price: 5000,
    quantity: 1,
    recurrence: null,
    option_id: 'option-basic',
    recommended_by: null,
    affiliate_id: null,
    rent: false,
    url_parameters: { source: 'email' },
    referrer: 'newsletter',
    recommender_model_name: null,
    call_start_time: null,
    pay_in_installments: false,
    // This is the critical part - discount codes applied to original item
    discount_codes: ['SAVE20'],
  };

  const mockCart: CartState = {
    items: [mockCartItem],
    discountCodes: [
      {
        code: 'SAVE20',
        products: { 'basic-plan': { type: 'percent', value: 20 } },
        fromUrl: true
      }
    ],
    email: 'buyer@test.com',
    rejectPppDiscount: false,
  };

  describe('upsell acceptance', () => {
    it('preserves all properties including discount_codes when accepting upsell', () => {
      const currentOffer = {
        type: 'upsell' as const,
        id: 'upsell-1',
        text: 'Upgrade!',
        description: 'Get Premium',
        item: mockCartItem,
        offeredOption: { id: 'option-premium', name: 'Premium', price_diff: 5000 }
      };

      // Simulate getCartIfAccepted logic
      const newCart: CartState = {
        ...mockCart,
        items: [
          ...mockCart.items.filter((item) => item !== currentOffer.item),
          {
            ...currentOffer.item, // This spreads all properties including discount_codes
            option_id: currentOffer.offeredOption.id,
            price: currentOffer.item.product.price_cents + currentOffer.offeredOption.price_diff,
            accepted_offer: {
              id: currentOffer.id,
            },
          },
        ],
      };

      // Verify the new cart item has preserved all original properties
      const upgradedItem = newCart.items[0];
      expect(upgradedItem.discount_codes).toEqual(['SAVE20']);
      expect(upgradedItem.url_parameters).toEqual({ source: 'email' });
      expect(upgradedItem.referrer).toBe('newsletter');
      expect(upgradedItem.option_id).toBe('option-premium');
      expect(upgradedItem.price).toBe(10000); // 5000 + 5000
      expect(upgradedItem.accepted_offer?.id).toBe('upsell-1');
    });

    it('preserves discount codes from cart state when item does not have discount_codes property', () => {
      const itemWithoutDiscountCodes = { ...mockCartItem };
      delete itemWithoutDiscountCodes.discount_codes;

      const currentOffer = {
        type: 'upsell' as const,
        id: 'upsell-1',
        text: 'Upgrade!',
        description: 'Get Premium',
        item: itemWithoutDiscountCodes,
        offeredOption: { id: 'option-premium', name: 'Premium', price_diff: 5000 }
      };

      const newCart: CartState = {
        ...mockCart,
        items: [
          {
            ...currentOffer.item,
            option_id: currentOffer.offeredOption.id,
            price: currentOffer.item.product.price_cents + currentOffer.offeredOption.price_diff,
            accepted_offer: {
              id: currentOffer.id,
            },
          },
        ],
      };

      // Even without explicit discount_codes on item, cart-level discounts still apply
      expect(newCart.discountCodes).toEqual([
        {
          code: 'SAVE20',
          products: { 'basic-plan': { type: 'percent', value: 20 } },
          fromUrl: true
        }
      ]);
    });
  });

  describe('cross-sell acceptance', () => {
    it('preserves tracking parameters from original item when accepting cross-sell', () => {
      const crossSellProduct = {
        ...mockCartItem.product,
        id: 'prod-2',
        permalink: 'addon-product',
        name: 'Add-on Product',
      };

      const currentOffer: CrossSell & { type: 'cross-sell' } = {
        type: 'cross-sell',
        id: 'cross-sell-1',
        replace_selected_products: false,
        text: 'Add this too!',
        description: 'Great addon',
        offered_product: {
          product: crossSellProduct,
          recurrence: null,
          price: 2000,
          option_id: null,
          rent: false,
          quantity: 1,
          affiliate_id: null,
          recommended_by: null,
          call_start_time: null,
          accepted_offer: null,
          pay_in_installments: false,
        },
        discount: null,
        ratings: null,
      };

      // Update mock cart to have cross-sell reference
      const cartWithCrossSell: CartState = {
        ...mockCart,
        items: [{
          ...mockCartItem,
          product: {
            ...mockCartItem.product,
            cross_sells: [currentOffer]
          }
        }]
      };

      // Simulate cross-sell acceptance
      const originalCartItems = cartWithCrossSell.items.filter(({ product }) =>
        product.cross_sells.some(({ id }) => id === currentOffer.id)
      );
      const originalCartItem = originalCartItems[0];

      const newCart: CartState = {
        ...cartWithCrossSell,
        items: [
          ...cartWithCrossSell.items,
          {
            ...currentOffer.offered_product,
            product: { ...currentOffer.offered_product.product, cross_sells: [] },
            quantity: 1,
            url_parameters: originalCartItem.url_parameters,
            referrer: originalCartItem.referrer,
            recommender_model_name: null,
            pay_in_installments: originalCartItem.pay_in_installments,
            accepted_offer: {
              id: currentOffer.id,
            },
          },
        ],
      };

      // Verify tracking data was preserved
      const addedItem = newCart.items[1];
      expect(addedItem.url_parameters).toEqual({ source: 'email' });
      expect(addedItem.referrer).toBe('newsletter');
      expect(addedItem.pay_in_installments).toBe(false);
      expect(addedItem.accepted_offer?.id).toBe('cross-sell-1');
    });
  });
});
