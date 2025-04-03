# UTM Link Tracking Feature Implementation

This document outlines the changes made to implement the UTM link tracking feature.

## Seller Interface for UTM Links

The seller interface for managing UTM links resides under the "Analytics" tab in the seller dashboard.

**Completed Tasks:**

- **Initial Layout & Listing Page:** Added initial layout with a placeholder for the listing page, then implemented the actual listing page. This includes displaying the "Clicks" statistic for each link. (2 PRs)
- **Pagination & Sorting:** Implemented pagination and column sorting support for the listing page. (2 PRs)
- **Delete Link:** Added functionality to delete links from the listing page. (1 PR)
- **Link Details Modal:** Added a modal view to display detailed information for each UTM link. (1 PR)
- **Search & Filtering:** Implemented search and filtering capabilities on the listing page. (1 PR)
- **Create & Edit Pages:** Built the frontend and backend for creating and editing UTM links, including a "Create link" page and an "Edit link" page. (2 PRs)
- **Permalink Regeneration:** Added the ability to regenerate a new permalink for the short URL on the create page. (1 PR)
- **Validation & Saving:** Implemented validation and saving logic for the "Create link" page. (1 PR)
- **Duplicate Link:** Added the ability to duplicate an existing link. (1 PR)
- **UTM Parameter Uniqueness Validation:** Added validation to prevent saving (creating/duplicating/updating) a link with UTM parameters that already exist for a given destination for that seller. (1 PR)

## Database Migrations and Models

The following changes were made to the database:

**Completed Tasks:**

- **Database Tables & Indexes (3 PRs):**
  - Created the `utm_links` table with the following fields and indices:
    - `seller_id` (bigint, required, indexed)
    - `title` (string, required)
    - `target_resource_type` (string, required, indexed)
    - `target_resource_id` (bigint, optional, indexed)
    - `permalink` (string, required, unique index)
    - `utm_source` (string, required, indexed as part of a composite unique index with other UTM fields and the target resource)
    - `utm_medium` (string, required, indexed as part of a composite unique index with other UTM fields and the target resource)
    - `utm_campaign` (string, required, indexed as part of a composite unique index with other UTM fields and the target resource and individually)
    - `utm_term` (string, optional, indexed as part of a composite unique index with other UTM fields and the target resource)
    - `utm_content` (string, optional, indexed as part of a composite unique index with other UTM fields and the target resource)
    - `first_click_at` (datetime)
    - `last_click_at` (datetime)
    - `total_clicks` (integer, default: 0)
    - `unique_clicks` (integer, default: 0)
    - `ip_address` (string)
    - `browser_guid` (string)
  - Created the `utm_link_visits` table with the following fields and indices:
    - `utm_link_id` (bigint, required, indexed)
    - `user_id` (bigint, optional, indexed)
    - `referrer` (string)
    - `ip_address` (string, required, indexed)
    - `user_agent` (string)
    - `browser_guid` (string, required, indexed)
    - `country_code` (string, required)
    - `created_at` (datetime, indexed)
  - Created the `utm_link_driven_sales` table with the following fields and indices:
    - `utm_link_id` (bigint, required, indexed)
    - `utm_link_visit_id` (bigint, required, indexed, and part of a unique composite index with `purchase_id`)
    - `purchase_id` (bigint, required, indexed, and part of a unique composite index with `utm_link_visit_id`)
- **Models, Relationships & Validations (1 PR):**
  - Created corresponding models (`UtmLink`, `UtmLinkVisit`, `UtmLinkDrivenSale`) with appropriate relationships (belongs_to, has_many) and validations (presence, uniqueness, format, etc.).

## UTM Link Click/Visit Tracking

Implemented UTM link click/visit tracking.

**Completed Tasks:**

- **Tracking Route:** Created the route `GET "/u/:permalink"` routing to `UtmLinkTrackingController#show`. This route handles UTM link clicks and redirects.
- **Visit Tracking:** Implemented visit tracking using the `cookies[:_gumroad_guid]` along with referrer, IP address, user agent, and country code, storing data in the `UtmLinkVisit` model.
- **UTM Link Stats Update:** Implemented logic to update link statistics (`total_clicks`, `unique_clicks`) in the `UtmLink` model.
- **Redirect to Destination:** Implemented redirection to the destination URL specified in the UTM link after tracking the visit.

## UTM Link Sale Conversion/Attribution

Implemented UTM link sale conversion/attribution.

**Completed Tasks:**

- **Attribution Logic:** Implemented attribution logic, considering only visits within a 7-day window prior to purchase and attributing only the latest visit for each UTM link, preventing multiple links getting credit for the same sale.
- **Attribution Filtering:** Limited attribution to purchases that match the UTM link's specified criteria (product, variants, etc.).
- **Visit Lookup:** Implemented visit lookup using the purchase's `_gumroad_guid` cookie.
- **Single Visit Attribution:** Ensured that only one visit is attributed per purchase, even if multiple applicable links exist.

## Additional Features and Improvements

- **Auto-creation of UTM Links:** Implemented auto-creation of UTM links in the Gumroad dashboard when a non-existing UTM URL is accessed. The "Destination" and "Title" are automatically set based on the URL. Added validation to prevent duplicate UTM parameter combinations. Stored IP address and browser GUID during UTM link creation to prevent spam. (1 PR)
- **Enhanced UTM Link Listing:** Added "Conversions (%)", "Number of sales", and "Sales volume ($)" to the UTM link listing page. (1 PR)
- **"Copy" Button for UTM URL:** Added a "Copy" button for the generated UTM URL on the create/edit page. (1 PR)
- **Destination in Link Details:** Added the destination to the link details drawer. (1 PR)
- **Destination Column on Listing Page:** Replaced the "Date" column with "Destination" on the listing page, as destination is more relevant. (1 PR)
- **Unique UTM Parameters per Destination:** Modified validation to allow creating a link with the same UTM parameters but with a different destination. (1 PR)

## Miscellaneous

- Addressed various bugs and performed optimizations, such as truncating text fields appropriately for display and using more efficient database queries where applicable.
- Implemented frontend components to support the new functionality.
- Updated documentation and help center content with information on the new UTM link tracking feature.
