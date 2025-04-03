# Gumroad

All communication about this project in this repository is subject to our [Code of Conduct](./CODE_OF_CONDUCT.md).

All use of this project is subject to our [Gumroad Community License](./LICENSE.md).

## Requirements:

### Ruby

- https://www.ruby-lang.org/en/documentation/installation/
- Install the version listed in [the .ruby-version file](./.ruby-version)

### Python

- For MacOS: https://docs.brew.sh/Homebrew-and-Python
- For Linux: https://docs.python-guide.org/starting/install3/linux/

### Node.js

- https://nodejs.org/en/download

### Docker & Docker Compose

We use `docker` and `docker compose` to setup the services for development environment.

- For MacOS: Grab the docker mac installation from the [Docker website](https://www.docker.com/products/docker-desktop)
- For Linux:

```bash
sudo wget -qO- https://get.docker.com/ | sh
sudo usermod -aG docker $(whoami)
sudo apt-get install python-pip
sudo pip install docker-compose
```

### MySQL & Percona Toolkit

Install a local version of MySQL 8.0.x to match the version running in production.

The local version of MySQL is a dependency of the Ruby `mysql2` gem. You do not need to start an instance of the MySQL service locally. The app will connect to a MySQL instance running in the Docker container.

- For MacOS:

```bash
brew install mysql@8.0 percona-toolkit
brew link --force mysql@8.0

# to use Homebrew's `openssl`:
brew install openssl
bundle config --global build.mysql2 --with-opt-dir="$(brew --prefix openssl)"

# ensure MySQL is not running as a service
brew services stop mysql@8.0
```

- For Linux:
  - MySQL:
    - https://dev.mysql.com/doc/refman/8.0/en/linux-installation.html
    - `apt install libmysqlclient-dev`
  - Percona Toolkit: https://www.percona.com/doc/percona-toolkit/LATEST/installation.html

### ImageMagick

We use `imagemagick` for preview editing.

- For MacOS: `brew install imagemagick`
- For Linux: `sudo apt-get install imagemagick`

### libvips

For newer image formats we use `libvips` for image processing with ActiveStorage.

- For MacOS: `brew install libvips`
- For Linux: `sudo apt-get install libvips-dev`

### FFmpeg

We use `ffprobe` that comes with `FFmpeg` package to fetch metadata from video files.

- For MacOS: `brew install ffmpeg`
- For Linux: `sudo apt-get install ffmpeg`

### PDFtk

We use [pdftk](https://www.pdflabs.com/tools/pdftk-server/) to stamp PDF files with the Gumroad logo and the buyers' emails.

- For MacOS: Download from [here](https://www.pdflabs.com/tools/pdftk-the-pdf-toolkit/pdftk_server-2.02-mac_osx-10.11-setup.pkg)
- For Linux: `sudo apt-get install pdftk`

### Bundler and gems

We use Bundler to install Ruby gems.

`gem install bundler`

If you have a license for Sidekiq Pro, configure its credentials:

```shell
bundle config gems.contribsys.com <key>
```

If you don't have a license for Sidekiq Pro, set the environment variable `GUMROAD_SIDEKIQ_PRO_DISABLED` in your shell:

```shell
echo "export GUMROAD_SIDEKIQ_PRO_DISABLED=true" >> ~/.bashrc
```

Run `bundle install` to install the necessary dependencies.

Also make sure to install `dotenv` as it is required for some console commands:

```shell
gem install dotenv
```

### npm and Node.js dependencies

Make sure the correct version of `npm` is enabled:

```shell
corepack enable
```

Install dependencies:

```shell
npm install
```

## Running things locally

### Start Docker services

First, make sure the required Docker services are running:

If you installed Docker Desktop (on a Mac or Windows machine), you can run:

`make local`

If you are on Linux, or installed Docker via a package manager on a mac, you may have to manually give docker superuser access to open ports 80 and 443. To do that, use `sudo make local` instead.

This command will not terminate. You run this in one tab and start the application in another tab.
If you want to run Docker services in the background, use `LOCAL_DETACHED=true make local` instead.

### Setup Custom credentials

App can be booted without any custom credentials. But if you would like to use services that require custom credentials (e.g. S3, Stripe, Resend, etc.), you can copy the `.env.example` file to `.env` and fill in the values.

### Setup the database

`bin/rails db:prepare`

For Linux (Debian / Ubuntu) you might need the following:

- `apt install libxslt-dev libxml2-dev`

### Local SSL Certificates

1. Install mkcert on macOS:

```shell
brew install mkcert
```

For other operating systems, see [mkcert installation instructions](https://github.com/FiloSottile/mkcert?tab=readme-ov-file#installation).

2. Generate certificates by running:

```shell
bin/generate_ssl_certificates
```

### Debugging

Read debugging tips and tricks in [Notion](https://www.notion.so/gumroad/Getting-set-up-debugging-tips-and-tricks-6696f3be5e3e46698c689239b1418c1e) if you face problems when setting up the development environment locally.

### Linting

We use ESLint for JS, and Rubocop for Ruby. Your editor should support displaying and fixing issues reported by these inline, and CI will automatically check and fix (if possible) these.

If you'd like, you can run `git config --local core.hooksPath .githooks` to check for these locally when committing.

### Start the application

`bin/dev`

This starts the rails server, the javascript build system, and a Sidekiq worker.

If you know what foreman does and you don't want to use it you can inspect the contents of the `Procfile.dev` file and run the required components individually.

You can now access the application @ https://gumroad.dev.

### Logging in

You can log in with the username `seller@gumroad.com` and the password `password`. The two-factor authentication code is `000000`.

Read more about logging in as a user with a different team role at [Users & authentication](docs/users.md).

### Resetting Elasticsearch indices

You will need to explicitly reindex Elasticsearch to populate the indices after setup, otherwise you will see `index_not_found_exception` errors when you visit the dev application. You can reset them using:

```ruby
# Run this in a rails console:
DevTools.delete_all_indices_and_reindex_all
```

[Check here for more details about Elasticsearch](https://www.notion.so/gumroad/ElasticSearch-f61b48074e714e5f93d9f526cb9a58cf).

#### To send push notifications:

`INITIALIZE_RPUSH_APPS=true bundle exec rpush start -e development -f`

### Rails console:

`bin/rails c`

### Rake tasks:

`bin/rake task_name`

### Running Apple Pay locally:

Apple Pay is already enabled for these domains and sub-domains -

1. gumroad.dev
2. discover.gumroad.dev
3. creator.gumroad.dev

To see the apple pay button on custom domains, add the domain name to [Stripe Dashboard](https://dashboard.stripe.com/settings/payments/apple_pay) (or via Rails console: `Stripe::ApplePayDomain.create(domain_name: domain)`) and visit product checkout page from a [browser that supports Apple Pay](https://stripe.com/docs/stripe-js/elements/payment-request-button#html-js-testing).

### Helper widget

We’ve embedded a Helper widget to assist Gumroad creators with platform-related questions. To run the widget locally, you’ll also need to run the Helper app locally. By default, the development environment expects the Helper Next.js server to run on `localhost:3010`. Currently, the Helper host is set to port 3000. You can update the port by modifying `bin/dev` and `apps/nextjs/webpack.sdk.cjs` inside the Helper project to use a different port, such as 3010.

You can update the `HELPER_WIDGET_HOST` in your `.env.development` file to point to a different host if needed.
The widget performs HMAC validation on the email to confirm it's coming from Gumroad. If necessary, you can update the `helper_widget_secret` in the credentials to match the one used by Helper.

## Debugging

### Visual Studio Code / Cursor Debugging

1. Install the [Ruby](https://marketplace.visualstudio.com/items?itemName=Shopify.ruby-lsp) extension.
2. Install the [vscode-rdbg](https://marketplace.visualstudio.com/items?itemName=KoichiSasada.vscode-rdbg) extension.
3. Start the supporting services by running `make local` in a terminal.
4. Run the non-rails services by running `foreman start -f Procfile.debug` in a terminal.
5. Debug the Rails server by running the "Run Rails server" launch configuration in VS Code from the "Run -> Start Debugging" menu item.

Now you should be able to set breakpoints in the code and debug the application.
