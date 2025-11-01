import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { router } from '@inertiajs/react';
import Show from '@/pages/Admin/Users/Show';

// Mock Inertia router
vi.mock('@inertiajs/react', async () => {
  const actual = await vi.importActual('@inertiajs/react');
  return {
    ...actual,
    router: {
      visit: vi.fn(),
    },
    usePage: vi.fn(() => ({
      props: {},
    })),
  };
});

describe('Admin Users Show', () => {
  const mockUser = {
    id: 1,
    external_id: 'ext123',
    name: 'Test User',
    username: 'testuser',
    email: 'test@example.com',
    form_email: 'test@example.com',
    support_email: null,
    avatar_url: 'https://example.com/avatar.jpg',
    bio: 'This is my bio',
    created_at: '2023-01-01T00:00:00Z',
    updated_at: '2023-01-15T00:00:00Z',
    deleted_at: null,
    verified: true,
    user_risk_state: 'compliant',
    all_adult_products: false,
    custom_fee_per_thousand: 50,
    unpaid_balance_cents: 10000,
    disable_paypal_sales: false,
    subdomain_with_protocol: 'https://testuser.gumroad.com',
    tos_violation_reason: null,
    can_impersonate: true,
    has_payments: true,
    payment_address: 'paypal@example.com',
    payouts_paused_by_source: null,
    payouts_paused_for_reason: null,
  };

  const mockProducts = [
    {
      id: 1,
      unique_permalink: 'test-product',
      name: 'Test Product',
      price_formatted: '$10.00',
      preview_url: 'https://example.com/preview.jpg',
      long_url: 'https://gumroad.com/l/test-product',
      created_at: '2023-01-01T00:00:00Z',
      alive: true,
      deleted_at: null,
      user_id: 1,
    },
  ];

  const mockPagy = {
    page: 1,
    pages: 1,
    count: 1,
    prev: null,
    next: null,
  };

  const defaultProps = {
    user: mockUser,
    products: mockProducts,
    pagy: mockPagy,
    is_affiliate_user: false,
    user_memberships: [],
    active_bank_account: null,
    merchant_accounts: [],
    compliance_info: null,
    last_posts: [],
    comments: [],
    email_versions: [],
    stripe_account_exists: false,
    manual_payout_eligible: false,
    stripe_payable_data: null,
    paypal_payable_data: null,
    manual_payout_period_end_date: null,
    currency: null,
  };

  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe('rendering', () => {
    it('renders user name', () => {
      render(<Show {...defaultProps} />);

      expect(screen.getByText('Test User')).toBeInTheDocument();
    });

    it('renders user email', () => {
      render(<Show {...defaultProps} />);

      expect(screen.getByText('test@example.com')).toBeInTheDocument();
    });

    it('renders user avatar', () => {
      render(<Show {...defaultProps} />);

      const avatar = screen.getAllByRole('img')[0];
      expect(avatar).toHaveAttribute('src', 'https://example.com/avatar.jpg');
      expect(avatar).toHaveAttribute('alt', 'Test User');
    });

    it('renders user bio', () => {
      render(<Show {...defaultProps} />);

      // Click on Bio section to expand it
      const bioButton = screen.getByText('Bio');
      fireEvent.click(bioButton);

      expect(screen.getByText('This is my bio')).toBeInTheDocument();
    });

    it('renders risk state badge', () => {
      render(<Show {...defaultProps} />);

      expect(screen.getAllByText('Compliant')).toHaveLength(2); // Header and risk section
    });

    it('renders verified badge when verified', () => {
      render(<Show {...defaultProps} />);

      expect(mockUser.verified).toBe(true);
    });

    it('displays custom fee when present', () => {
      render(<Show {...defaultProps} />);

      expect(screen.getByText(/Custom fee: 5\.0%/)).toBeInTheDocument();
    });

    it('renders username with link to profile', () => {
      render(<Show {...defaultProps} />);

      const usernameLink = screen.getByRole('link', { name: 'testuser' });
      expect(usernameLink).toHaveAttribute('href', 'https://testuser.gumroad.com');
    });

    it('renders back link to admin dashboard', () => {
      render(<Show {...defaultProps} />);

      const backLink = screen.getByRole('link', { href: '/admin' });
      expect(backLink).toBeInTheDocument();
    });

    it('displays all action buttons', () => {
      render(<Show {...defaultProps} />);

      expect(screen.getByRole('button', { name: /Become/i })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /Unverify/i })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /Reset password/i })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /Confirm email/i })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /Sign out from all active sessions/i })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /Mark as adult/i })).toBeInTheDocument();
    });

    it('renders profile and products tabs', () => {
      render(<Show {...defaultProps} />);

      expect(screen.getByRole('button', { name: 'Profile' })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: 'Products' })).toBeInTheDocument();
    });

    it('renders copy to clipboard button for email', () => {
      render(<Show {...defaultProps} />);

      const emailSection = screen.getByText('test@example.com').closest('div');
      const copyButton = within(emailSection!).getByRole('button');
      expect(copyButton).toBeInTheDocument();
    });
  });

  describe('user status displays', () => {
    it('shows compliant status with green badge', () => {
      render(<Show {...defaultProps} />);

      const badges = screen.getAllByText('Compliant');
      expect(badges[0]).toHaveClass('bg-green-100', 'text-green-800');
    });

    it('shows suspended for fraud status with red badge', () => {
      const suspendedUser = {
        ...mockUser,
        user_risk_state: 'suspended_for_fraud' as const,
      };

      render(<Show {...defaultProps} user={suspendedUser} />);

      const badges = screen.getAllByText('Suspended For Fraud');
      expect(badges[0]).toHaveClass('bg-red-100', 'text-red-800');
    });

    it('shows flagged status with yellow badge', () => {
      const flaggedUser = {
        ...mockUser,
        user_risk_state: 'flagged_for_fraud' as const,
      };

      render(<Show {...defaultProps} user={flaggedUser} />);

      const badges = screen.getAllByText('Flagged For Fraud');
      expect(badges[0]).toHaveClass('bg-yellow-100', 'text-yellow-800');
    });

    it('shows on probation status with orange badge', () => {
      const probationUser = {
        ...mockUser,
        user_risk_state: 'on_probation' as const,
      };

      render(<Show {...defaultProps} user={probationUser} />);

      const badges = screen.getAllByText('On Probation');
      expect(badges[0]).toHaveClass('bg-orange-100', 'text-orange-800');
    });

    it('displays deleted alert when user is deleted', () => {
      const deletedUser = {
        ...mockUser,
        deleted_at: '2023-01-20T00:00:00Z',
      };

      render(<Show {...defaultProps} user={deletedUser} />);

      expect(screen.getByText('Account Deleted')).toBeInTheDocument();
      expect(screen.getByText(/This user account was deleted on/)).toBeInTheDocument();
    });

    it('shows deleted badge in header when user deleted', () => {
      const deletedUser = {
        ...mockUser,
        deleted_at: '2023-01-20T00:00:00Z',
      };

      render(<Show {...defaultProps} user={deletedUser} />);

      expect(screen.getByText('Deleted')).toBeInTheDocument();
    });

    it('shows unverified user correctly', () => {
      const unverifiedUser = {
        ...mockUser,
        verified: false,
      };

      render(<Show {...defaultProps} user={unverifiedUser} />);

      expect(screen.getByRole('button', { name: /Verify/i })).toBeInTheDocument();
    });
  });

  describe('interactions', () => {
    it('navigates back to admin dashboard when back button clicked', () => {
      render(<Show {...defaultProps} />);

      const backLink = screen.getByRole('link', { href: '/admin' });
      fireEvent.click(backLink);

      // Link would trigger navigation naturally
      expect(backLink).toHaveAttribute('href', '/admin');
    });

    it('switches to products tab when clicked', () => {
      render(<Show {...defaultProps} />);

      const productsTab = screen.getByRole('button', { name: 'Products' });
      fireEvent.click(productsTab);

      expect(productsTab).toHaveClass('border-blue-500', 'text-blue-600');
    });

    it('switches back to profile tab when clicked', () => {
      render(<Show {...defaultProps} />);

      const productsTab = screen.getByRole('button', { name: 'Products' });
      const profileTab = screen.getByRole('button', { name: 'Profile' });

      fireEvent.click(productsTab);
      fireEvent.click(profileTab);

      expect(profileTab).toHaveClass('border-blue-500', 'text-blue-600');
    });

    it('confirms before executing verify action', () => {
      const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(true);

      render(<Show {...defaultProps} />);

      const verifyButton = screen.getByRole('button', { name: /Unverify/i });
      fireEvent.click(verifyButton);

      expect(confirmSpy).toHaveBeenCalledWith(
        expect.stringContaining('Are you sure you want to unverify')
      );
    });

    it('does not execute action when confirmation cancelled', () => {
      const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(false);

      render(<Show {...defaultProps} />);

      const verifyButton = screen.getByRole('button', { name: /Unverify/i });
      fireEvent.click(verifyButton);

      expect(router.visit).not.toHaveBeenCalled();
    });

    it('executes verify action when confirmed', async () => {
      const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(true);

      render(<Show {...defaultProps} />);

      const verifyButton = screen.getByRole('button', { name: /Unverify/i });
      fireEvent.click(verifyButton);

      await waitFor(() => {
        expect(router.visit).toHaveBeenCalledWith(
          '/admin/users/1/verify',
          expect.objectContaining({ method: 'post' })
        );
      });
    });

    it('disables Become button when cannot impersonate', () => {
      const nonImpersonatableUser = {
        ...mockUser,
        can_impersonate: false,
      };

      render(<Show {...defaultProps} user={nonImpersonatableUser} />);

      const becomeButton = screen.getByRole('button', { name: /Become/i });
      expect(becomeButton).toBeDisabled();
    });

    it('shows Undelete button for deleted users', () => {
      const deletedUser = {
        ...mockUser,
        deleted_at: '2023-01-20T00:00:00Z',
      };

      render(<Show {...defaultProps} user={deletedUser} />);

      expect(screen.getByRole('button', { name: /Undelete/i })).toBeInTheDocument();
    });

    it('copies email to clipboard when copy button clicked', async () => {
      const writeTextMock = vi.fn().mockResolvedValue(undefined);
      Object.assign(navigator, {
        clipboard: {
          writeText: writeTextMock,
        },
      });

      render(<Show {...defaultProps} />);

      const emailSection = screen.getByText('test@example.com').closest('div');
      const copyButton = within(emailSection!).getByRole('button');

      fireEvent.click(copyButton);

      await waitFor(() => {
        expect(writeTextMock).toHaveBeenCalledWith('test@example.com');
      });
    });

    it('expands collapsible sections when clicked', () => {
      render(<Show {...defaultProps} />);

      const bioButton = screen.getByText('Bio');
      expect(screen.queryByText('This is my bio')).not.toBeInTheDocument();

      fireEvent.click(bioButton);

      expect(screen.getByText('This is my bio')).toBeInTheDocument();
    });
  });

  describe('products tab', () => {
    it('displays products when tab is active', () => {
      render(<Show {...defaultProps} />);

      const productsTab = screen.getByRole('button', { name: 'Products' });
      fireEvent.click(productsTab);

      expect(screen.getByText('Test Product')).toBeInTheDocument();
      expect(screen.getByText('$10.00,')).toBeInTheDocument();
    });

    it('shows empty state when no products', () => {
      render(<Show {...defaultProps} products={[]} />);

      const productsTab = screen.getByRole('button', { name: 'Products' });
      fireEvent.click(productsTab);

      expect(screen.getByText('No products created.')).toBeInTheDocument();
    });

    it('shows affiliate empty state for affiliate users', () => {
      render(<Show {...defaultProps} products={[]} is_affiliate_user={true} />);

      const productsTab = screen.getByRole('button', { name: 'Products' });
      fireEvent.click(productsTab);

      expect(screen.getByText('No affiliated products.')).toBeInTheDocument();
    });

    it('displays pagination when multiple pages', () => {
      const multiPagePagy = {
        page: 1,
        pages: 3,
        count: 25,
        prev: null,
        next: 2,
      };

      render(<Show {...defaultProps} pagy={multiPagePagy} />);

      const productsTab = screen.getByRole('button', { name: 'Products' });
      fireEvent.click(productsTab);

      expect(screen.getByText('‹ Previous')).toBeInTheDocument();
      expect(screen.getByText('Next ›')).toBeInTheDocument();
      expect(screen.getByText('1')).toBeInTheDocument();
      expect(screen.getByText('2')).toBeInTheDocument();
      expect(screen.getByText('3')).toBeInTheDocument();
    });

    it('disables previous button on first page', () => {
      const firstPagePagy = {
        page: 1,
        pages: 3,
        count: 25,
        prev: null,
        next: 2,
      };

      render(<Show {...defaultProps} pagy={firstPagePagy} />);

      const productsTab = screen.getByRole('button', { name: 'Products' });
      fireEvent.click(productsTab);

      const prevLink = screen.getByText('‹ Previous');
      expect(prevLink).toHaveClass('cursor-not-allowed');
    });

    it('shows unpublished badge for unpublished products', () => {
      const unpublishedProduct = {
        ...mockProducts[0],
        alive: false,
      };

      render(<Show {...defaultProps} products={[unpublishedProduct]} />);

      const productsTab = screen.getByRole('button', { name: 'Products' });
      fireEvent.click(productsTab);

      expect(screen.getByText('Unpublished')).toBeInTheDocument();
    });

    it('shows deleted badge for deleted products', () => {
      const deletedProduct = {
        ...mockProducts[0],
        deleted_at: '2023-01-20T00:00:00Z',
      };

      render(<Show {...defaultProps} products={[deletedProduct]} />);

      const productsTab = screen.getByRole('button', { name: 'Products' });
      fireEvent.click(productsTab);

      expect(screen.getByText('Deleted')).toBeInTheDocument();
    });
  });

  describe('user memberships', () => {
    it('displays user memberships when present', () => {
      const memberships = [
        {
          id: 1,
          seller_id: 2,
          seller_name: 'Team Owner',
          seller_avatar_url: 'https://example.com/owner.jpg',
          role: 'admin',
          last_accessed_at: '2023-01-15T00:00:00Z',
          created_at: '2023-01-01T00:00:00Z',
        },
      ];

      render(<Show {...defaultProps} user_memberships={memberships} />);

      const membershipButton = screen.getByText('User memberships');
      fireEvent.click(membershipButton);

      expect(screen.getByText('Team Owner')).toBeInTheDocument();
      expect(screen.getByText('admin')).toBeInTheDocument();
    });

    it('hides user memberships section when empty', () => {
      render(<Show {...defaultProps} user_memberships={[]} />);

      expect(screen.queryByText('User memberships')).not.toBeInTheDocument();
    });
  });

  describe('compliance information', () => {
    it('displays compliance info when present', () => {
      const complianceInfo = {
        is_business: false,
        first_name: 'John',
        last_name: 'Doe',
        street_address: '123 Main St',
        city: 'New York',
        state: 'New York',
        state_code: 'NY',
        zip_code: '10001',
        country: 'United States',
        country_code: 'US',
        individual_tax_id_provided: true,
        business_name: null,
        business_street_address: null,
        business_city: null,
        business_state: null,
        business_zip_code: null,
        business_country: null,
        business_type: null,
        business_tax_id_provided: false,
      };

      render(<Show {...defaultProps} compliance_info={complianceInfo} />);

      expect(screen.getByText('Personal Info')).toBeInTheDocument();
    });

    it('displays business info for business users', () => {
      const businessComplianceInfo = {
        is_business: true,
        first_name: 'John',
        last_name: 'Doe',
        street_address: '123 Main St',
        city: 'New York',
        state: 'New York',
        state_code: 'NY',
        zip_code: '10001',
        country: 'United States',
        country_code: 'US',
        individual_tax_id_provided: true,
        business_name: 'Acme Corp',
        business_street_address: '456 Business Ave',
        business_city: 'New York',
        business_state: 'NY',
        business_zip_code: '10002',
        business_country: 'US',
        business_type: 'LLC',
        business_tax_id_provided: true,
      };

      render(<Show {...defaultProps} compliance_info={businessComplianceInfo} />);

      expect(screen.getByText('Business Info')).toBeInTheDocument();
      expect(screen.getByText('Acme Corp')).toBeInTheDocument();
    });

    it('hides compliance info section when not present', () => {
      render(<Show {...defaultProps} compliance_info={null} />);

      expect(screen.queryByText('Personal Info')).not.toBeInTheDocument();
    });
  });

  describe('comments', () => {
    it('displays comments when present', () => {
      const comments = [
        {
          id: 1,
          content: 'Test comment',
          author_name: 'Admin User',
          comment_type: 'general',
          created_at: '2023-01-15T00:00:00Z',
        },
      ];

      render(<Show {...defaultProps} comments={comments} />);

      expect(screen.getByText('1 comment')).toBeInTheDocument();

      const commentButton = screen.getByText('1 comment');
      fireEvent.click(commentButton);

      expect(screen.getByText('Test comment')).toBeInTheDocument();
      expect(screen.getByText('Admin User')).toBeInTheDocument();
    });

    it('shows plural comments text', () => {
      const comments = [
        {
          id: 1,
          content: 'Comment 1',
          author_name: 'Admin',
          comment_type: 'general',
          created_at: '2023-01-15T00:00:00Z',
        },
        {
          id: 2,
          content: 'Comment 2',
          author_name: 'Admin',
          comment_type: 'general',
          created_at: '2023-01-16T00:00:00Z',
        },
      ];

      render(<Show {...defaultProps} comments={comments} />);

      expect(screen.getByText('2 comments')).toBeInTheDocument();
    });

    it('shows no comments message when empty', () => {
      render(<Show {...defaultProps} comments={[]} />);

      expect(screen.getByText('No comments created.')).toBeInTheDocument();
    });
  });

  describe('loading and processing states', () => {
    it('disables button during processing', async () => {
      const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(true);

      render(<Show {...defaultProps} />);

      const verifyButton = screen.getByRole('button', { name: /Unverify/i });
      fireEvent.click(verifyButton);

      await waitFor(() => {
        expect(verifyButton).toHaveTextContent('Processing...');
      });
    });
  });

  describe('responsive design', () => {
    it('renders correctly on mobile (375px)', () => {
      global.innerWidth = 375;
      global.dispatchEvent(new Event('resize'));

      render(<Show {...defaultProps} />);

      expect(screen.getByText('Test User')).toBeInTheDocument();
      expect(screen.getByRole('button', { name: 'Profile' })).toBeInTheDocument();
    });

    it('renders correctly on tablet (768px)', () => {
      global.innerWidth = 768;
      global.dispatchEvent(new Event('resize'));

      render(<Show {...defaultProps} />);

      expect(screen.getByText('Test User')).toBeInTheDocument();
      expect(screen.getByRole('button', { name: 'Profile' })).toBeInTheDocument();
    });

    it('renders correctly on desktop (1920px)', () => {
      global.innerWidth = 1920;
      global.dispatchEvent(new Event('resize'));

      render(<Show {...defaultProps} />);

      expect(screen.getByText('Test User')).toBeInTheDocument();
      expect(screen.getByRole('button', { name: 'Profile' })).toBeInTheDocument();
    });
  });

  describe('timestamps', () => {
    it('displays created at timestamp', () => {
      render(<Show {...defaultProps} />);

      expect(screen.getByText('Created')).toBeInTheDocument();
    });

    it('displays updated at timestamp', () => {
      render(<Show {...defaultProps} />);

      expect(screen.getByText('Updated')).toBeInTheDocument();
    });

    it('displays deleted at for deleted users', () => {
      const deletedUser = {
        ...mockUser,
        deleted_at: '2023-01-20T00:00:00Z',
      };

      render(<Show {...defaultProps} user={deletedUser} />);

      expect(screen.getByText('Deleted')).toBeInTheDocument();
    });
  });

  describe('edge cases', () => {
    it('handles user with no name', () => {
      const noNameUser = {
        ...mockUser,
        name: null,
      };

      render(<Show {...defaultProps} user={noNameUser} />);

      expect(screen.getByText('User 1')).toBeInTheDocument();
    });

    it('handles user with no bio', () => {
      const noBioUser = {
        ...mockUser,
        bio: null,
      };

      render(<Show {...defaultProps} user={noBioUser} />);

      const bioButton = screen.getByText('Bio');
      fireEvent.click(bioButton);

      expect(screen.getByText('No bio provided.')).toBeInTheDocument();
    });

    it('handles user with no custom fee', () => {
      const noFeeUser = {
        ...mockUser,
        custom_fee_per_thousand: null,
      };

      render(<Show {...defaultProps} user={noFeeUser} />);

      expect(screen.queryByText(/Custom fee:/)).not.toBeInTheDocument();
    });

    it('handles user with no support email', () => {
      const noSupportEmailUser = {
        ...mockUser,
        support_email: null,
      };

      render(<Show {...defaultProps} user={noSupportEmailUser} />);

      expect(screen.queryByText('Support email:')).not.toBeInTheDocument();
    });

    it('handles empty last posts', () => {
      render(<Show {...defaultProps} last_posts={[]} />);

      const postsButton = screen.getByText('Last posts');
      fireEvent.click(postsButton);

      expect(screen.getByText('No posts created.')).toBeInTheDocument();
    });

    it('handles empty email versions', () => {
      render(<Show {...defaultProps} email_versions={[]} />);

      const versionsButton = screen.getByText('Email changes');
      fireEvent.click(versionsButton);

      expect(screen.getByText('No email changes recorded.')).toBeInTheDocument();
    });
  });
});

