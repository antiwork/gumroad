FROM ruby:3.3

# Install system dependencies
RUN apt-get update -qq && \
    apt-get install -y \
    build-essential \
    libpq-dev \
    nodejs \
    npm \
    libvips \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Install Node.js dependencies
COPY package*.json ./
RUN npm install || true

# Copy Gemfile
COPY Gemfile Gemfile.lock ./

# Install Ruby dependencies
RUN bundle install

# Copy application code
COPY . .

# Make entrypoint script executable
RUN chmod +x docker/app/entrypoint.sh

# Expose port
EXPOSE 3000

# Use entrypoint script
ENTRYPOINT ["docker/app/entrypoint.sh"]
