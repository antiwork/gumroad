# Help Center Integration

This PR moves the static Help Center pages from `/public/help/` into the main Rails application, allowing for proper integration with the main navigation sidebar.

## Changes Made

1. Created a `HelpController` with actions for:

   - `index` - The main Help Center landing page
   - `category` - Category pages showing lists of articles
   - `article` - Individual help articles

2. Added routes in `routes.rb`:

   ```ruby
   get "/help", to: "help#index", as: :help
   get "/help/category/:id", to: "help#category", as: :help_category
   get "/help/article/:id", to: "help#article", as: :help_article

   # Redirect old help center paths to new paths
   get "/help/category/:id.html", to: redirect("/help/category/%{id}")
   get "/help/article/:id.html", to: redirect("/help/article/%{id}")
   ```

3. Created view templates:

   - `app/views/layouts/help.html.erb` - A dedicated layout for the Help Center
   - `app/views/help/index.html.erb` - The main Help Center page
   - `app/views/help/category.html.erb` - Template for category pages
   - `app/views/help/article.html.erb` - Template for article pages

4. Integrated with Navigation:
   - For logged-in users, the main Gumroad navigation sidebar is shown
   - For non-logged-in users, the original Help Center header is maintained

## Implementation Details

The implementation takes a hybrid approach:

- The existing static HTML files remain in place but are now parsed by the new HelpController
- The main content from these files is extracted and displayed within the Rails layout
- Nokogiri is used to parse the HTML and extract the necessary content
- Links are updated to use the Rails routes instead of direct HTML files

This approach maintains all existing functionality while adding proper navigation integration.

## Benefits

1. **Navigation Integration**: Logged-in users now see the main navigation sidebar when browsing Help Center pages
2. **Consistent Experience**: The Help Center is now consistent with the rest of the Gumroad application
3. **SEO Preservation**: Redirect rules ensure that existing links to help pages continue to work
4. **Future Expansion**: Being part of the main Rails app makes it easier to add dynamic features to the Help Center

## Future Improvements

In the future, we can further enhance the Help Center by:

1. Migrating content to the database for easier management
2. Adding a search feature that integrates with the main app search
3. Creating an admin interface for editing help content
4. Adding user-specific help recommendations based on their account and usage
