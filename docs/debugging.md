## Debugging

Read debugging tips and tricks in [Notion](https://www.notion.so/gumroad/Getting-set-up-debugging-tips-and-tricks-6696f3be5e3e46698c689239b1418c1e) if you face problems when setting up the development environment locally.

### Visual Studio Code / Cursor Debugging

1. Install the [Ruby](https://marketplace.visualstudio.com/items?itemName=Shopify.ruby-lsp) extension.
2. Install the [vscode-rdbg](https://marketplace.visualstudio.com/items?itemName=KoichiSasada.vscode-rdbg) extension.
3. Start the supporting services by running `make local` in a terminal.
4. Run the non-rails services by running `foreman start -f Procfile.debug` in a terminal.
5. Debug the Rails server by running the "Run Rails server" launch configuration in VS Code from the "Run -> Start Debugging" menu item.

Now you should be able to set breakpoints in the code and debug the application.
