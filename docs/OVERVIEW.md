This codebase represents a Ruby on Rails application, likely an e-commerce platform like Gumroad, with a React frontend and potentially some server-rendered components. Here's an overview for new developers:

**Key Technologies:**

- **Ruby on Rails:** Backend framework.
- **React:** Frontend library.
- **React on Rails:** Integrates React with Rails.
- **TypeScript:** Used for type safety in the frontend.
- **Webpack/Shakapacker:** Bundles frontend assets.
- **PostCSS/Tailwind CSS:** Styling.
- **Stripe, Braintree, PayPal:** Payment processing.
- **TaxJar, Vatstack, Tax ID Pro:** Sales tax calculation and validation.
- **Elasticsearch:** Search and analytics.
- **Mongoid:** MongoDB ODM for certain data.
- **Redis:** Caching and background job processing.
- **Sidekiq:** Background job processing.
- **Bugsnag:** Error tracking.

**Workflow for Shipping Features and Fixing Bugs:**

1. **Understand the Code Structure:** Familiarize yourself with the directory structure. The `app` directory is the core of the Rails app, containing models, controllers, views, mailers, etc. The `web` directory likely houses the React frontend. The `business` directory seems to contain core business logic, which is a good place to start understanding the application's functionality. The `lib` directory contains utility classes and other shared code. The single consolidated file presented here will require parsing to recreate the original file/folder structure if you intend to work with this representation directly. It's highly recommended to use the actual git repository instead.
2. **Set up Your Development Environment:** This likely involves setting up Ruby, Rails, Node.js, Yarn/npm, Redis, MongoDB, Elasticsearch, and the payment gateway SDKs. The provided Docker files (`Dockerfile`, `Dockerfile.test`) suggest a Dockerized environment is recommended for both development and testing, including setup steps to enable running this code.
3. **Branching Strategy:** Create a new branch for your feature or bug fix.
4. **Testing:** Write tests (RSpec for backend, Jest/other for frontend) to cover your changes. The CI workflow in `.github/workflows` emphasizes testing with different stages for backend and frontend tests.
5. **Backend Changes:** If your feature involves backend changes, work in the `app` directory, following Rails conventions. Pay special attention to the business logic within the `business` directory to ensure correct implementation of payment processing, sales tax, and other core features.
6. **Frontend Changes:** For frontend changes, work in the `web` directory. Follow React and TypeScript best practices.
7. **Build Process:** Use Webpack/Shakapacker to build your frontend assets (`bin/shakapacker`, `bin/shakapacker-dev-server`, `config/webpack`). The `autofix.yml` file gives some insight into the code linting and formatting style and tooling for the codebase, that will be useful in following existing conventions.
8. **Deployment:** Follow the deployment process outlined in the CI workflows (`.github/workflows`). These use Docker and likely a container orchestration tool like Kubernetes/Nomad. The `build_web.yml`, `deploy_branch_app.yml` and `deploy_production.yml` files suggest an approach using automated builds and deployments based on git pushes, including several stages to build, test and deploy images, and orchestrate deployments to various environments (production, staging, branch apps).

**Additional Notes:**

- **Types:** The codebase uses Sorbet for type checking in Ruby and TypeScript in the frontend. Ensure your code is correctly typed. The `.gitattributes`, `.githooks`, `.github`, `.npmrc`, `.prettierignore`, `.prettierrc`, and similar files may contain information on the tools or guidelines used to ensure code style and quality that would be useful in following established conventions.
- **Linters and Formatters:** The project uses linters (e.g., ESLint, Rubocop) and formatters (e.g., Prettier) to enforce code style. Familiarize yourself with these tools and the project's configuration for them (`.eslintrc.json`, `.prettierrc`, `.rubocop.yml`, `eslint.config.js`).
- **API Documentation:** The `public/api` directory suggests API documentation is provided. Consult this documentation for details on how to interact with the backend.
- **Feature Flags:** The codebase uses feature flags (`config/initializers/feature_toggle.rb`). Be mindful of these when developing new features.
- **Error Tracking:** Bugsnag is used for error tracking.

This overview should give you a good starting point for understanding the codebase. As you dive deeper, consult the code itself, the API documentation, and any other available documentation for more specific details.
