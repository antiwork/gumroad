### Why?

Docker may lead to hogging of memory and resources, especially on older Macs. Direct installation of the required services helps to prevent that.

### Required services

The below instructions will set up all services with the latest versions of the brew formulae. While this should usually work, you may run into issues due to a specific version not matching the docker version. In that case, you will have to manually install the respective version of that service.

For the versions required to match the docker setup, checkout `docker/docker-compose-local.yml`.

- MySQL
- Redis
- MongoDB
- Elasticsearch

#### MySQL

```
brew install mysql percona-toolkit
brew link --force mysql

# to use Homebrew's `openssl`:
brew install openssl
bundle config --global build.mysql2 --with-opt-dir="$(brew --prefix openssl)"

# to set root password (use password="password"):
$(brew —-prefix mysql)/bin/mysqladmin -u root password <NEWPASSWORD>
```

#### Redis

1. Install with Homebrew

   ```
   brew install redis
   ```

2. To have launchd start redis now and restart at login:
   ```
   brew services start redis
   ```
3. Test if Redis server is running.

   ```
   redis-cli ping
   ```

   If it replies “PONG”, then it’s good to go!

#### MongoDB

Search for the available versions using `brew search mongo` and install the appropriate one.

For example, to install version 3.6

```
brew install mongodb/brew/mongodb-community@3.6
```

#### Elasticsearch

1.  ```sh
    brew tap elastic/tap
    brew install elastic/tap/elasticsearch-full
    ```
2.  Add the following to your `.bashrc`/`.zshrc` file

    ```
    export ES_JAVA_OPTS=-Xms512m -Xmx512m
    export discovery.type=single-node
    ```

Now follow the rest of the [README.md](https://github.com/antiwork/gumroad/blob/main/README.md) for the installation process. Once done open http://localhost:3000 after running the `foreman` command and it should point to your Gumroad server. Seller subdomains and the asset/api hosts use `*.localhost` (e.g. `http://seller.localhost:3000`, `http://api.localhost:3000`) — modern browsers auto-resolve these to 127.0.0.1, so no `/etc/hosts` edits are needed.
