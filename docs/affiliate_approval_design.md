# Affiliate Approval/Denial System Design

## Overview
Add the ability for users to approve/deny affiliate invitations and remove themselves from existing affiliations in the Affiliated Products Dashboard.

## Current System
- When someone adds an affiliate, a `DirectAffiliate` record is created immediately
- An invitation email is sent automatically
- The affiliate appears in the affiliated products dashboard immediately
- No approval mechanism exists for the affiliate recipient

## Proposed Changes

### 1. Database Schema Changes
Add a `status` field to the `affiliates` table:
- `pending` - Initial state when affiliate is added
- `approved` - Affiliate has approved the invitation  
- `denied` - Affiliate has denied the invitation

### 2. Model Changes
- Update `DirectAffiliate` model to include status field
- Add state machine for status transitions
- Modify callbacks to only send invitation emails for pending affiliates
- Update scopes to filter by status

### 3. Controller Changes
- Add new actions for approve/deny/revoke in affiliated products controller
- Update affiliated products presenter to include pending invitations
- Add API endpoints for status changes

### 4. UI Changes
- Update affiliated products dashboard to show:
  - Pending invitations with approve/deny buttons
  - Active affiliations with remove/revoke buttons
- Add appropriate messaging and confirmations

### 5. Email Changes
- Modify invitation email to explain approval requirement
- Add new emails for approval/denial confirmations
- Update seller notification emails

## Implementation Plan

### Phase 1: Backend Infrastructure
1. Create migration to add status field
2. Update DirectAffiliate model with state machine
3. Update existing affiliate creation to use pending status

### Phase 2: Dashboard Updates  
1. Update AffiliatedProductsPresenter to include pending invitations
2. Add new controller actions for approve/deny/revoke
3. Update UI components to show approval controls

### Phase 3: Email Updates
1. Modify existing invitation emails
2. Add new approval/denial notification emails
3. Update seller notification flow

### Phase 4: Testing & Polish
1. Add comprehensive tests
2. Update documentation
3. Handle edge cases and error scenarios
