import React from 'react';
import '@testing-library/jest-dom';
import { render, screen, fireEvent } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';

// Mock react-router-dom hooks that require a data router
jest.mock('react-router-dom', () => {
  const actual = jest.requireActual('react-router-dom');
  return {
    ...actual,
    useMatches: jest.fn(() => [{ handle: 'product' }]),
    useNavigate: jest.fn(() => jest.fn()),
  };
});
import { Layout } from './Layout';
import { ProductEditContext } from './state';

// Mock data modules to avoid importing ts-safe-cast and heavy deps
jest.mock('$app/data/product_edit', () => ({ saveProduct: jest.fn() }));
jest.mock('$app/data/publish_product', () => ({ setProductPublished: jest.fn() }));

// Lightweight mocks for deps used by Layout/useProductUrl
jest.mock('$app/components/RichTextEditor', () => ({
  useImageUploadSettings: jest.fn(() => ({ isUploading: false })),
}));
jest.mock('$app/components/CurrentSeller', () => ({
  useCurrentSeller: jest.fn(() => ({ subdomain: 'seller' })),
}));
jest.mock('$app/components/DomainSettings', () => ({
  useDomains: jest.fn(() => ({ appDomain: 'gumroad.dev' })),
}));
// Stub out clipboard-dependent component to avoid JSDOM runtime errors
jest.mock('$app/components/CopyToClipboard', () => ({
  CopyToClipboard: () => null,
}));
jest.mock('$app/components/server-components/Alert', () => ({
  showAlert: jest.fn(),
}));
// Avoid importing heavy server components (Email form, etc.)
jest.mock('$app/components/server-components/EmailsPage', () => ({
  newEmailPath: '/emails/new',
}));

// Provide global Rails Routes helper used by useProductUrl
// eslint-disable-next-line @typescript-eslint/no-explicit-any
;(global as any).Routes = {
  short_link_url: (_permalink: string | null, _params: Record<string, unknown>) => 'https://gumroad.dev/p/example',
  custom_domain_coffee_url: (_params: Record<string, unknown>) => 'https://seller.gumroad.dev/p/coffee',
};

function renderWithContext(ui: React.ReactNode, opts?: { saving?: boolean; isPublished?: boolean }) {
  const saveMock = jest.fn();
  const value: any = {
    id: 'pid',
    uniquePermalink: 'unique-123',
    product: {
      name: 'Product',
      description: '',
      custom_permalink: null,
      price_cents: 1000,
      suggested_price_cents: null,
      customizable_price: false,
      eligible_for_installment_plans: false,
      allow_installment_plan: false,
      installment_plan: null,
      custom_button_text_option: null,
      custom_summary: null,
      custom_attributes: [],
      file_attributes: [],
      max_purchase_count: null,
      quantity_enabled: false,
      can_enable_quantity: false,
      should_show_sales_count: false,
      hide_sold_out_variants: false,
      is_epublication: false,
      product_refund_policy_enabled: false,
      refund_policy: { title: '', fine_print: '' },
      is_published: opts?.isPublished ?? true,
      free_trial_enabled: false,
      free_trial_duration_amount: null,
      free_trial_duration_unit: null,
      should_include_last_post: false,
      should_show_all_posts: false,
      block_access_after_membership_cancellation: false,
      duration_in_months: null,
      subscription_duration: null,
      integrations: {
        discord: { enabled: false },
        circle: { enabled: false },
        google_calendar: { enabled: false },
      },
      covers: [],
      availabilities: [],
      section_ids: [],
      taxonomy_id: null,
      tags: [],
      display_product_reviews: false,
      is_adult: false,
      discover_fee_per_thousand: 0,
      shipping_destinations: [],
      custom_domain: '',
      collaborating_user: null,
      rich_content: [],
      files: [],
      has_same_rich_content_for_all_variants: true,
      is_multiseat_license: false,
      call_limitation_info: null,
      require_shipping: false,
      cancellation_discount: null,
      public_files: [],
      audio_previews_enabled: false,
      community_chat_enabled: null,
      native_type: 'ebook',
      variants: [],
    },
    updateProduct: jest.fn(),
    thumbnail: null,
    refundPolicies: [],
    currencyType: 'USD',
    setCurrencyType: jest.fn(),
    isListedOnDiscover: false,
    isPhysical: false,
    profileSections: [],
    taxonomies: [],
    earliestMembershipPriceChangeDate: new Date(),
    customDomainVerificationStatus: null,
    salesCountForInventory: 0,
    successfulSalesCount: 0,
    ratings: { average_rating: 0, ratings_count: 0, ratings_with_percentages: {} as any },
    seller: { id: 'seller-id', name: 'Seller' },
    existingFiles: [],
    setExistingFiles: jest.fn(),
    awsKey: 'key',
    s3Url: 'https://s3',
    availableCountries: [],
    saving: opts?.saving ?? false,
    save: saveMock,
    googleClientId: '',
    googleCalendarEnabled: false,
    seller_refund_policy_enabled: false,
    seller_refund_policy: { title: '', fine_print: '' },
    cancellationDiscountsEnabled: false,
    contentUpdates: null,
    setContentUpdates: jest.fn(),
  };

  const view = render(
    <MemoryRouter>
      <ProductEditContext.Provider value={value}>{ui}</ProductEditContext.Provider>
    </MemoryRouter>
  );

  return { ...view, saveMock };
}

describe('ProductEdit Layout Keyboard Shortcuts', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    document.body.innerHTML = '';
    delete (process.env as any).PRODUCT_EDITOR_SAVE_SHORTCUT;
  });

  describe('Cmd/Ctrl+S keyboard shortcut', () => {
    describe('when feature flag is enabled', () => {
      beforeEach(() => {
        (process.env as any).PRODUCT_EDITOR_SAVE_SHORTCUT = 'true';
      });

      it('triggers save on Meta+S (Mac)', () => {
        const { saveMock } = renderWithContext(
          <Layout>
            <div>Content</div>
          </Layout>
        );
        fireEvent.keyDown(window, { key: 's', code: 'KeyS', metaKey: true, ctrlKey: false, preventDefault: jest.fn() });
        expect(saveMock).toHaveBeenCalledTimes(1);
      });

      it('triggers save on Ctrl+S (Windows/Linux)', () => {
        const { saveMock } = renderWithContext(
          <Layout>
            <div>Content</div>
          </Layout>
        );
        fireEvent.keyDown(window, { key: 's', code: 'KeyS', metaKey: false, ctrlKey: true, preventDefault: jest.fn() });
        expect(saveMock).toHaveBeenCalledTimes(1);
      });

      it('does not save while focused in input', () => {
        const { saveMock } = renderWithContext(
          <Layout>
            <div>
              <input type="text" />
            </div>
          </Layout>
        );
        const input = screen.getByRole('textbox');
        input.focus();
        fireEvent.keyDown(window, { key: 's', code: 'KeyS', ctrlKey: true, preventDefault: jest.fn() });
        expect(saveMock).not.toHaveBeenCalled();
      });

      it('does not save while focused in textarea', () => {
        const { container, saveMock } = renderWithContext(
          <Layout>
            <div>
              <textarea />
            </div>
          </Layout>
        );
        const textarea = container.querySelector('textarea') as HTMLTextAreaElement | null;
        textarea?.focus();
        fireEvent.keyDown(window, { key: 's', code: 'KeyS', metaKey: true, preventDefault: jest.fn() });
        expect(saveMock).not.toHaveBeenCalled();
      });

      it('does not save while focused in contenteditable', async () => {
        const { container, saveMock } = renderWithContext(
          <Layout>
            <div>
              <div contentEditable={true} role="textbox" tabIndex={0}>Editable</div>
            </div>
          </Layout>
        );
        const editable = container.querySelector('[contenteditable]') as HTMLElement | null;
        expect(editable).toBeTruthy();
        await userEvent.click(editable!);
        await userEvent.keyboard('{Control>}s{/Control}');
        expect(saveMock).not.toHaveBeenCalled();
      });

      it('always preventDefault on shortcut', () => {
        const addSpy = jest.spyOn(window, 'addEventListener');
        renderWithContext(
          <Layout>
            <div>Content</div>
          </Layout>
        );
        const handler = addSpy.mock.calls.find((c) => c[0] === 'keydown')?.[1] as (e: KeyboardEvent) => void;
        addSpy.mockRestore();
        const preventDefault = jest.fn();
        handler?.({ key: 's', code: 'KeyS', ctrlKey: true, preventDefault } as any);
        expect(preventDefault).toHaveBeenCalled();
      });

      it('handles both Meta+Ctrl+S once', () => {
        const { saveMock } = renderWithContext(
          <Layout>
            <div>Content</div>
          </Layout>
        );
        fireEvent.keyDown(window, { key: 's', code: 'KeyS', metaKey: true, ctrlKey: true, preventDefault: jest.fn() });
        expect(saveMock).toHaveBeenCalledTimes(1);
      });

      it('ignores other modifiers', () => {
        const { saveMock } = renderWithContext(
          <Layout>
            <div>Content</div>
          </Layout>
        );
        fireEvent.keyDown(window, { key: 's', code: 'KeyS', altKey: true, preventDefault: jest.fn() });
        fireEvent.keyDown(window, { key: 'S', code: 'KeyS', shiftKey: true, preventDefault: jest.fn() });
        expect(saveMock).not.toHaveBeenCalled();
      });

      it('ignores different keys', () => {
        const { saveMock } = renderWithContext(
          <Layout>
            <div>Content</div>
          </Layout>
        );
        fireEvent.keyDown(window, { key: 'a', code: 'KeyA', ctrlKey: true, preventDefault: jest.fn() });
        fireEvent.keyDown(window, { key: 'p', code: 'KeyP', metaKey: true, preventDefault: jest.fn() });
        expect(saveMock).not.toHaveBeenCalled();
      });

      it('cleans up event listener on unmount', () => {
        const spy = jest.spyOn(window, 'removeEventListener');
        const { unmount } = renderWithContext(
          <Layout>
            <div>Content</div>
          </Layout>
        );
        unmount();
        expect(spy).toHaveBeenCalledWith('keydown', expect.any(Function));
        spy.mockRestore();
      });
    });

    describe('when feature flag is disabled', () => {
      beforeEach(() => {
        (process.env as any).PRODUCT_EDITOR_SAVE_SHORTCUT = 'false';
      });

      it('does not trigger save on Cmd+S or Ctrl+S', () => {
        const { saveMock } = renderWithContext(
          <Layout>
            <div>Content</div>
          </Layout>
        );
        fireEvent.keyDown(window, { key: 's', code: 'KeyS', metaKey: true, preventDefault: jest.fn() });
        fireEvent.keyDown(window, { key: 's', code: 'KeyS', ctrlKey: true, preventDefault: jest.fn() });
        expect(saveMock).not.toHaveBeenCalled();
      });

      it('does not add keydown listener', () => {
        const spy = jest.spyOn(window, 'addEventListener');
        renderWithContext(
          <Layout>
            <div>Content</div>
          </Layout>
        );
        const keydowns = spy.mock.calls.filter((c) => c[0] === 'keydown');
        expect(keydowns).toHaveLength(0);
        spy.mockRestore();
      });
    });
  });

  describe('aria-keyshortcuts attribute', () => {
    it('is present and includes Control+S and Meta+S when enabled', () => {
      (process.env as any).PRODUCT_EDITOR_SAVE_SHORTCUT = 'true';
      renderWithContext(
        <Layout>
          <div>Content</div>
        </Layout>
      );
      const btn = screen.getByText('Save changes');
      expect(btn).toHaveAttribute('aria-keyshortcuts');
      const val = btn.getAttribute('aria-keyshortcuts') || '';
      expect(val).toContain('Control+S');
      expect(val).toContain('Meta+S');
    });

    it('is omitted when disabled', () => {
      (process.env as any).PRODUCT_EDITOR_SAVE_SHORTCUT = 'false';
      renderWithContext(
        <Layout>
          <div>Content</div>
        </Layout>
      );
      const btn = screen.getByText('Save changes');
      expect(btn).not.toHaveAttribute('aria-keyshortcuts');
    });
  });

  describe('Save button interaction', () => {
    it('clicking Save calls save()', async () => {
      (process.env as any).PRODUCT_EDITOR_SAVE_SHORTCUT = 'true';
      const { saveMock } = renderWithContext(
        <Layout>
          <div>Content</div>
        </Layout>
      );
      await userEvent.click(screen.getByText('Save changes'));
      expect(saveMock).toHaveBeenCalledTimes(1);
    });

    it('disables Save and shows saving text while saving', () => {
      (process.env as any).PRODUCT_EDITOR_SAVE_SHORTCUT = 'true';
      renderWithContext(
        <Layout>
          <div>Content</div>
        </Layout>,
        { saving: true }
      );
      const btn = screen.getByRole('button', { name: 'Saving changes...' });
      expect(btn).toBeDisabled();
      expect(screen.getByText('Saving changes...')).toBeInTheDocument();
    });
  });

  describe('Focus behavior', () => {
    it('does not save when input focused; saves when other element focused', () => {
      (process.env as any).PRODUCT_EDITOR_SAVE_SHORTCUT = 'true';
      const { saveMock } = renderWithContext(
        <Layout>
          <div>
            <input type="text" />
            <button>Click me</button>
          </div>
        </Layout>
      );
      const input = screen.getByRole('textbox');
      const button = screen.getByText('Click me');

      input.focus();
      fireEvent.keyDown(window, { key: 's', code: 'KeyS', ctrlKey: true, preventDefault: jest.fn() });
      expect(saveMock).not.toHaveBeenCalled();

      button.focus();
      fireEvent.keyDown(window, { key: 's', code: 'KeyS', ctrlKey: true, preventDefault: jest.fn() });
      expect(saveMock).toHaveBeenCalledTimes(1);
    });
  });
});
