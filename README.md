![MacMailClauder Icon](https://raw.githubusercontent.com/FyrbyAdditive/MacMailClauder/refs/heads/main/MacMailClauderApp/Assets.xcassets/AppIcon.appiconset/AppIconOriginal-128.png)
# MacMailClauder

A macOS Mail.app integration for Claude Desktop via MCP (Model Context Protocol).

# New In 1.0.2

In version 1.0.2 there is a new feature which allows you to select accounts you would like to allow Claude to access.

This feature is opt-in, hence you will need to flick switches when you upgrade to make it work again.

Also note you will need to give MacMailClauder full disk access due to this feature when you upgrade.

## Features

- **Search Emails** - Search by sender, subject, date range, or body content
- **Read Email Content** - Get full email content including body text
- **Search Attachments** - Search text content within PDFs, documents, etc.
- **Extract Attachments** - Get attachment content with text extraction
- **Open Emails** - Claude will open emails in Mail.app for you!
- **Configuration UI** - Menu bar app to control permissions and scope

## Some Things Explained

Please note this is in its early stages, however it works for me. I tried to build an integration another way, and at the point I realised I had almost basically built a whole email client and it was a bit overbearing I thought I should do it another way.

This integration is only for Apple Mail, and integrates with it via read-only usage of the SQLite databases and other files.

I discovered there are limitations on what you can easily/quickly get into Claude Desktop. This is particularly relevant for attachments and things. However, attachment data is passed to Claude Desktop as text to get around this.

This application has two components:

- A menu bar application for initial configuration
- A command line MCP server that runs from Claude Desktop

The MCP server inherits its permissions from Claude, which is why Claude needs Full Disk Access permissions, else it cannot read the mail databases.

The menu bar configuration app also needs FDA, as it needs to query various databases to check the status of email accounts so you can control which accounts Claude has access to.

There are better ways to do this but this is how it is for now. Note that after initial configuration, you do not need to run the menu bar app unless you want to.

## Requirements

- macOS 26.0 (Tahoe)
- Claude Desktop
- Full Disk Access permission for Claude Desktop

## Installation

Please use one of the prepared signed package installers here from Github.

## Setup

### 1. Grant Full Disk Access

Claude Desktop and MacMailClauder need Full Disk Access so they can read relevant mail related databases:

1. Open **System Settings** → **Privacy & Security** → **Full Disk Access**
2. Claude and MacMailClauder are probably already in the list. If they are, enable the switches.
2. If they are not, click the **+** button
3. Navigate to your applications folder, drag them in, and enable them.

### 2. Configure Claude Desktop

Click the menu bar icon and click **"Fix"** next to "Claude Desktop" - this automatically adds the MCP server to Claude's config.

Or manually add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "macmail": {
      "command": "/Applications/MacMailClauder.app/Contents/MacOS/MacMailClauderMCP"
    }
  }
}
```

### 3. Restart Claude Desktop

Restart Claude Desktop to load the MCP server.

## Usage

Once configured, you can ask Claude things like:

- "Search my emails for messages from Amazon"
- "Find emails about the project meeting last week"
- "Show me the PDF attachments I received this month"
- "Find the invoice with number 12345 in my attachments"
- "Open that email in Mail.app"

## Privacy

This application does not collect any data and sends absolutely no data of any kind anywhere except to Claude Desktop (and therefore its cloud service) through the normal operation of the application in conjunction with Claude Desktop.

## License

This software is Copyright 2025 Timothy Ellis, Fyrby Additive Manufacturing & Engineering and is distributed under the MIT License.

